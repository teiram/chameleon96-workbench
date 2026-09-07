// hps_ddr_bench.c - HPS-side SDRAM latency/bandwidth benchmark for the
// Chameleon96 reserved FPGA window (default 0x10000000, 4 MiB).
//
// Models the FPGA F2SDRAM path from the HPS side: every access is UNCHACHED
// (uncached /dev/mem mapping via O_SYNC), because the fabric has no cache and
// every F2SDRAM word goes straight to the DDR controller. The controller-access
// latency (row activate, column, refresh, HPS-vs-FPGA arbitration) is the SAME
// controller the ram1/ram2/vbuf ports use, so these numbers are a LOWER BOUND
// on the true F2SDRAM single-word round-trip (the port FIFOs + bridge add on
// top). Pair with ddrbench.v (FPGA side) for the exact number.
//
// Run the same binary in three contexts to quantify contention:
//   a) menu up, video live (128-bit port 0 hammering)       -> worst case
//   b) a core running, video live
//   c) video idle / no display                              -> baseline
//
// Timing: Cortex-A9 PMU cycle counter (PMCCNTR) when user access is enabled,
// else the ARM global timer @0xFFFEC200 (via /dev/mem, always available), else
// CLOCK_MONOTONIC ns (coarse, per-access stats unreliable). Guarded via sigsetjmp.
//
// Build: make            (arm-none-linux-gnueabihf-gcc, see Makefile)
// Usage: ./ddrbench [base] [size_mib] [test...]
//   base     byte address, default 0x10000000 (must stay in the 256 MiB
//            no-map window 0x10000000-0x20000000)
//   size_mib region size, default 4 (min 1, max 16)
//   test     lat|rnd|bw|wr|rw  (default: all)

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <inttypes.h>
#include <errno.h>

#define BUCKET   4u          /* cycles per histogram bucket */
#define NBUCKETS 4096u       /* covers 0 .. 16384 cycles */

static int      use_pmu = 0;
static double   ghz     = 0.0;
static int      use_gt  = 0;   /* ARM global timer @0xFFFEC200 via /dev/mem */
static void    *gt_mem  = NULL;   /* SCU page 0xFFFEC000 (for munmap) */
static volatile uint32_t *gt_map = NULL;   /* points at CNTCR @ +0x200 */
static double   gt_ghz  = 0.0; /* global timer ticks/ns */
static uint64_t ovh     = 0;   /* measured now() loop overhead, in tsc units */

/* latency histogram (per-access cycle counts) */
static uint32_t hist[NBUCKETS];
static uint64_t hist_over;
static uint32_t hmin = 0xffffffffu;
static uint32_t hmax = 0;
static uint64_t hsum = 0;
static uint64_t hcount = 0;
static uint32_t checksum = 0;

/* mapped region */
static volatile uint32_t *base;
static uint32_t           words;   /* region length in 32-bit words */

/* --- Cortex-A9 PMU --- */
static inline uint32_t pmccntr(void) {
	uint32_t v;
	__asm__ volatile("mrc p15, 0, %0, c9, c13, 0" : "=r"(v));
	return v;
}

static sigjmp_buf pmu_jmp;
static void pmu_fault(int sig) { (void)sig; siglongjmp(pmu_jmp, 1); }

static void pmu_try_enable(void) {
	struct sigaction sa, old_ill, old_seg, old_bus;
	sa.sa_handler = pmu_fault;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESTART;
	sigaction(SIGILL, &sa, &old_ill);
	sigaction(SIGSEGV, &sa, &old_seg);
	sigaction(SIGBUS, &sa, &old_bus);

	if (sigsetjmp(pmu_jmp, 1) == 0) {
		/* PMCR: E | C (reset cyc) | P (reset ev) */
		__asm__ volatile("mcr p15, 0, %0, c9, c12, 0" :: "r"(0x31u));
		__asm__ volatile("mcr p15, 0, %0, c9, c14, 0" :: "r"(1u)); /* PMUSERENR */
		pmccntr();          /* read once to confirm no fault */
		use_pmu = 1;
	}
	sigaction(SIGILL, &old_ill, NULL);
	sigaction(SIGSEGV, &old_seg, NULL);
	sigaction(SIGBUS, &old_bus, NULL);
}

/* --- Cortex-A9 global timer @0xFFFEC200 (SCU base +0x200) ---
 * 64-bit up-counter on the CPU ref clock. Linux does NOT use it as a
 * clocksource (socfpga.dtsi wires only the TWD timer @+0x600), so it is free
 * for user-space reads and safe to enable. CNTCR (+0x00) bit0=EN; CNTCVLO
 * (+0x08). */
static void gt_try_init(void) {
	struct sigaction sa, old_seg, old_bus;
	sa.sa_handler = pmu_fault;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESTART;
	sigaction(SIGSEGV, &sa, &old_seg);
	sigaction(SIGBUS, &sa, &old_bus);

	if (sigsetjmp(pmu_jmp, 1) == 0) {
		int fd = open("/dev/mem", O_RDWR | O_SYNC);
		if (fd < 0) { perror("open /dev/mem (global timer)"); goto out; }
		/* /dev/mem offsets must be page-aligned: map the MPCore SCU page
		 * (0xFFFEC000) and reach the global timer registers at +0x200. */
		gt_mem = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		              0xFFFEC000ull);
		close(fd);
		if (gt_mem == MAP_FAILED) { perror("mmap global timer"); gt_mem = NULL; goto out; }
		gt_map = (volatile uint32_t *)gt_mem + 0x80;   /* +0x200: CNTCR */

		uint32_t t0 = gt_map[2];   /* CNTCVLO @ +0x208 */
		uint32_t t1 = gt_map[2];
		if (t0 == t1) {            /* not counting: set CNTCR.EN */
			gt_map[0] = 0x01u;
			t1 = gt_map[2];
		}
		if (t0 == t1) {
			fprintf(stderr, "WARNING: global timer not advancing\n");
			munmap(gt_mem, 4096); gt_mem = NULL; gt_map = NULL; goto out;
		}
		use_gt = 1;
	}
out:
	sigaction(SIGSEGV, &old_seg, NULL);
	sigaction(SIGBUS, &old_bus, NULL);
}

/* --- generic monotonic tsc --- */
static inline uint64_t tsc_now(void) {
	if (use_pmu) return pmccntr();
	if (use_gt)  return gt_map[2];   /* +0x08: CNTCVLO */
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* wrap-safe delta for the 32-bit hardware counters */
static inline int64_t tsc_delta(uint64_t a, uint64_t b) {
	if (use_pmu || use_gt) return (int32_t)((uint32_t)b - (uint32_t)a);
	return (int64_t)(b - a);
}

static double tsc_to_ns(int64_t d) {
	if (use_pmu) return (double)d / ghz;      /* ghz = cycles/ns */
	if (use_gt)  return (double)d / gt_ghz;   /* gt_ghz = ticks/ns */
	return (double)d;
}

static void tsc_calibrate(void) {
	if (!use_pmu && !use_gt) { ghz = 1e9; return; }
	uint64_t a = tsc_now();
	struct timespec s, e;
	clock_gettime(CLOCK_MONOTONIC, &s);
	usleep(200000);
	uint64_t b = tsc_now();
	clock_gettime(CLOCK_MONOTONIC, &e);
	double sec = (e.tv_sec - s.tv_sec) + (e.tv_nsec - s.tv_nsec) / 1e9;
	if (use_pmu) {
		ghz = (double)(int32_t)((uint32_t)b - (uint32_t)a) / sec / 1e9;
		printf("# CPU clock: %.3f GHz\n", ghz);
	} else {
		gt_ghz = (double)(int32_t)((uint32_t)b - (uint32_t)a) / sec / 1e9;
		printf("# global timer: %.3f GHz\n", gt_ghz);
	}

	/* measure now() loop overhead */
	uint64_t n = 200000, t0 = tsc_now();
	for (uint64_t i = 0; i < n; i++) { (void)tsc_now(); }
	uint64_t t1 = tsc_now();
	ovh = (uint64_t)((int64_t)(int32_t)((uint32_t)t1 - (uint32_t)t0) / (int64_t)n);
	printf("# now() overhead: %" PRIu64 " %s/access\n", ovh,
	       use_gt ? "ticks" : "cycles");
}

/* --- histogram accounting --- */
static void hinit(void) {
	memset(hist, 0, sizeof(hist));
	hist_over = 0; hmin = 0xffffffffu; hmax = 0; hsum = 0; hcount = 0;
	checksum = 0;
}

static void hadd(int64_t d) {
	d -= (int64_t)ovh;
	if (d < 1) d = 1;
	uint64_t u = (uint64_t)d;
	hcount++;
	hsum += u;
	if (u < hmin) hmin = (uint32_t)u;
	if (u > hmax) hmax = (uint32_t)u;
	uint32_t b = (uint32_t)(u / BUCKET);
	if (b < NBUCKETS) hist[b]++; else hist_over++;
}

static void hreport(const char *label) {
	uint64_t p50 = 0, p90 = 0, p99 = 0, c = 0;
	for (uint32_t i = 0; i < NBUCKETS; i++) {
		c += hist[i];
		if (p50 == 0 && c * 100 >= hcount * 50) p50 = i * BUCKET;
		if (p90 == 0 && c * 100 >= hcount * 90) p90 = i * BUCKET;
		if (p99 == 0 && c * 100 >= hcount * 99) p99 = i * BUCKET;
	}
	if (c < hcount) { /* overflow beyond NBUCKETS */
		if (p50 == 0) p50 = NBUCKETS * BUCKET;
		if (p90 == 0) p90 = NBUCKETS * BUCKET;
		if (p99 == 0) p99 = NBUCKETS * BUCKET;
	}
	double avg = hcount ? (double)hsum / (double)hcount : 0;
	const char *unit = use_pmu ? "cyc" : (use_gt ? "ticks" : "ns");
	if (use_pmu || use_gt) {
		double per_ns = use_pmu ? ghz : gt_ghz;   /* source ticks per ns */
		double over_ns = (double)(NBUCKETS * BUCKET) / per_ns;
		printf("%-22s n=%7" PRIu64 "  min=%7.1f ns (%6" PRIu64 " %s)"
		       "  avg=%7.1f ns  p50=%7.1f  p90=%7.1f  p99=%7.1f"
		       "  max=%7.1f ns  >%.0fns=%" PRIu64 "  sum=%08x\n",
		       label, hcount,
		       tsc_to_ns(hmin), (uint64_t)(hmin * per_ns), unit,
		       tsc_to_ns((int64_t)avg),
		       tsc_to_ns(p50), tsc_to_ns(p90), tsc_to_ns(p99),
		       tsc_to_ns(hmax), over_ns, hist_over, checksum);
	} else {
		printf("%-22s n=%7" PRIu64 "  min=%7.1f ns"
		       "  avg=%7.1f ns  p50=%7.1f  p90=%7.1f  p99=%7.1f"
		       "  max=%7.1f ns  >%.0fns=%" PRIu64 "  sum=%08x\n",
		       label, hcount,
		       tsc_to_ns(hmin),
		       tsc_to_ns((int64_t)avg),
		       tsc_to_ns(p50), tsc_to_ns(p90), tsc_to_ns(p99),
		       tsc_to_ns(hmax), (double)(NBUCKETS * BUCKET),
		       hist_over, checksum);
	}
}

/* --- region seeding / verification --- */
static void seed_region(void) {
	for (uint32_t i = 0; i < words; i++) base[i] = 0xA5A5A5A5u ^ i;
	printf("# region seeded: base[i] = 0xA5A5A5A5 ^ i  (%u words)\n", words);
}

static void verify_region(void) {
	uint64_t errors = 0;
	for (uint32_t i = 0; i < words; i++) {
		uint32_t want = 0xA5A5A5A5u ^ i;
		if (base[i] != want) {
			if (errors < 4)
				printf("  MISMATCH @ +0x%08x: expected %08x found %08x\n",
				       i * 4, want, base[i]);
			errors++;
		}
	}
	printf("verify: %" PRIu64 " errors / %u words\n", errors, words);
}

/* --- tests --- */
#define N_SINGLE 200000
#define N_RAND   200000

static void test_latency(void) {
	hinit();
	uint32_t stride = 64;   /* 256 B: walks DRAM rows across the region */
	uint32_t mask = words - 1;
	for (uint32_t i = 0; i < N_SINGLE; i++) {
		volatile uint32_t *p = &base[(i * stride) & mask];
		uint64_t a = tsc_now();
		checksum ^= *p;
		uint64_t b = tsc_now();
		hadd(tsc_delta(a, b));
	}
	hreport("single read  (seq 256B stride)");
}

static void test_random(void) {
	hinit();
	uint32_t mask = words - 1;
	uint32_t x = 0xdeadbeefu;
	for (uint32_t i = 0; i < N_RAND; i++) {
		x ^= x << 13; x ^= x >> 17; x ^= x << 5;
		volatile uint32_t *p = &base[x & mask];
		uint64_t a = tsc_now();
		checksum ^= *p;
		uint64_t b = tsc_now();
		hadd(tsc_delta(a, b));
	}
	hreport("random read  (xorshift)");
}

static void test_bw_read(void) {
	uint64_t total = (uint64_t)words * 4u;   /* bytes */
	uint64_t t0 = tsc_now();
	for (uint32_t i = 0; i < words; i++) checksum ^= base[i];
	uint64_t t1 = tsc_now();
	int64_t d = tsc_delta(t0, t1);
	double ns = tsc_to_ns(d);
	printf("%-22s %7.2f MB/s  (%.1f ns/4B word, %" PRIu64 " MiB in %.1f ms)\n",
	       "seq read bw", total / ns * 1e3, ns / words, total >> 20, ns / 1e6);
}

static void test_bw_write(void) {
	uint64_t total = (uint64_t)words * 4u;
	uint64_t t0 = tsc_now();
	for (uint32_t i = 0; i < words; i++) base[i] = 0xA5A5A5A5u ^ i;
	uint64_t t1 = tsc_now();
	int64_t d = tsc_delta(t0, t1);
	double ns = tsc_to_ns(d);
	printf("%-22s %7.2f MB/s  (%.1f ns/4B word, %" PRIu64 " MiB in %.1f ms)\n",
	       "seq write bw (posted)", total / ns * 1e3, ns / words, total >> 20, ns / 1e6);

	/* drain: the write FIFO/queues must flush; read a sample back */
	uint64_t t2 = tsc_now();
	uint32_t csum = 0;
	for (uint32_t i = 0; i < words; i++) csum ^= base[i];
	uint64_t t3 = tsc_now();
	int64_t d2 = tsc_delta(t2, t3);
	double ns2 = tsc_to_ns(d2);
	printf("%-22s %7.2f MB/s  (write+readback, %.1f ns/word)\n",
	       "write+readback", total / ns2 * 1e3, ns2 / words);
	checksum ^= csum;
}

static void test_wr_rd_latency(void) {
	hinit();
	uint32_t stride = 64;
	uint32_t mask = words - 1;
	uint32_t v = 0;
	for (uint32_t i = 0; i < N_SINGLE; i++) {
		volatile uint32_t *p = &base[(i * stride) & mask];
		uint64_t a = tsc_now();
		*p = v ^= 0x01020304u;   /* posted store ... */
		checksum ^= *p;          /* ... forced to complete by this read */
		uint64_t b = tsc_now();
		hadd(tsc_delta(a, b));
	}
	hreport("write+readback (round trip)");
}

static void test_rmw(void) {
	hinit();
	uint32_t stride = 64;
	uint32_t mask = words - 1;
	for (uint32_t i = 0; i < N_SINGLE; i++) {
		volatile uint32_t *p = &base[(i * stride) & mask];
		uint64_t a = tsc_now();
		checksum ^= (*p ^ 0xdeadbeefu);
		*p = *p ^ 0xdeadbeefu;
		uint64_t b = tsc_now();
		hadd(tsc_delta(a, b));
	}
	hreport("read-modify-write");
}

int main(int argc, char **argv) {
	uint64_t addr = 0x10000000ull;
	uint32_t size_mib = 4;
	char test_all = 1, t_lat = 0, t_rnd = 0, t_bw = 0, t_wr = 0, t_rmw = 0;

	for (int i = 1; i < argc; i++) {
		if (argv[i][0] >= '0' && argv[i][0] <= '9') {
			addr = strtoull(argv[i], NULL, 0);
			if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9')
				size_mib = (uint32_t)strtoul(argv[++i], NULL, 0);
		} else if (!strcmp(argv[i], "lat")) { test_all = 0; t_lat = 1; }
		else if (!strcmp(argv[i], "rnd")) { test_all = 0; t_rnd = 1; }
		else if (!strcmp(argv[i], "bw")) { test_all = 0; t_bw = 1; }
		else if (!strcmp(argv[i], "wr")) { test_all = 0; t_wr = 1; }
		else if (!strcmp(argv[i], "rw")) { test_all = 0; t_rmw = 1; }
		else {
			fprintf(stderr, "Usage: %s [base] [size_mib] [lat|rnd|bw|wr|rw]\n", argv[0]);
			return 1;
		}
	}
	if (size_mib < 1 || size_mib > 16) size_mib = 4;

	/* safety: stay inside the no-map FPGA window */
	if (addr < 0x10000000ull || addr + (uint64_t)size_mib * 0x100000ull > 0x20000000ull) {
		fprintf(stderr, "WARNING: region 0x%016" PRIx64 " size %u MiB is NOT inside the "
			"reserved 256 MiB window (0x10000000-0x20000000). If it overlaps Linux "
			"memory this benchmark will corrupt the system.\n", addr, size_mib);
	}

	words = size_mib << 18;   /* words = MiB * 1024 * 1024 / 4 */

	pmu_try_enable();
	if (!use_pmu) gt_try_init();
	tsc_calibrate();

	printf("# region: base 0x%" PRIx64 " size %u MiB (%u words)  "
	       "timing: %s\n",
	       addr, size_mib, words,
	       use_pmu ? "PMCCNTR (cycles)" :
	       use_gt  ? "ARM global timer @0xFFFEC200 (ticks)" :
	                 "CLOCK_MONOTONIC ns (COARSE fallback)");
	if (!use_pmu && !use_gt)
		printf("# WARNING: no hardware counter - per-access stats include ~1us\n"
		       "#          clock_gettime overhead; only bulk bw numbers are\n"
		       "#          trustworthy in this mode.\n");
	printf("\n");

	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("open /dev/mem"); return 1; }
	void *m = mmap(NULL, (size_t)words * 4u, PROT_READ | PROT_WRITE,
	               MAP_SHARED, fd, (off_t)addr);
	if (m == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
	base = (volatile uint32_t *)m;

	seed_region();
	verify_region();

	if (test_all || t_lat) test_latency();
	if (test_all || t_rnd) test_random();
	if (test_all || t_bw)  test_bw_read();
	if (test_all || t_bw)  test_bw_write();
	if (test_all || t_wr)  test_wr_rd_latency();
	if (test_all || t_rmw) test_rmw();

	munmap(m, (size_t)words * 4u);
	close(fd);
	return 0;
}
