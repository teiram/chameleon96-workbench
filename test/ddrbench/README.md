# ddrbench - on-board DDR3 / F2SDRAM benchmark (Chameleon96)

Goal: **prove or disprove** the claim that the HPS DDR3 (via the FPGA F2SDRAM
ports) cannot act as a core SRAM replacement on this board (FINDINGS.md §16).

Two tools, run in order:

1. `hps_ddr_bench.c` - **HPS-side proxy** (run now, needs only the board + rootfs).
   Uncached `/dev/mem` access into the reserved FPGA window (`0x10000000`).
   Because the fabric has no cache, the controller-access part of the F2SDRAM
   round-trip (row activate, column, refresh, HPS-vs-FPGA arbitration) is the
   SAME controller these numbers exercise → these are a **lower bound** on the
   true F2SDRAM single-word latency (the port FIFOs + bridge add on top).

2. `ddrbench.v` - **FPGA-side RTL benchmark** (needs Quartus + board). Drives
   ram1 directly (the 64-bit F2SDRAM port) and writes its measurements back to a
   mailbox at `0x10000000` that the app reads over `/dev/mem`. This is the exact
   number a core would see. Smoke-tested with iverilog (`tb_ddrbench.v`).

   Both tools use byte addresses. The ram1 port is 64-bit and its Avalon
   `ADDRESS` is a **word** address (physical byte = word << 3, FINDINGS §21a),
   so `ddrbench.v` shifts everything >>3 internally; the app-side addresses are
   plain byte addresses, matching `/dev/mem`.

   The default region `0x10000000` (4 MiB) sits at the base of the 256 MiB
   no-map reservation, free under the menu and every non-ao486 RBF and clear of
   the ascal vbuf (`0x1E800000`-`0x20000000`).

Expected numbers (FINDINGS §16b/c): single-word read ~150-250 ns typical with a
tail from refresh/HPS traffic; bursts amortize to ~5-10 ns/word; writes posted.

---

## Phase 1 - HPS-side proxy

### Build

Use the **same armhf toolchain as Main_MiSTer** (Linaro GCC 10.2), not the
`arm-ch96-linux-gnueabi` SDK — the SDK produces a soft-float PIE against a newer
glibc that the board rootfs cannot load:

    export PATH=$HOME/src/chameleon96/cleanup/mister/toolchains/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:$PATH
    make ddrbench            # dynamic, /lib/ld-linux-armhf.so.3 (like bin/MiSTer)
    # or:
    make ddrbench-static     # fully static, runs on any armhf board

Verify with `file ddrbench` — it must show `ELF 32-bit LSB executable, ARM,
EABI5 ... interpreter /lib/ld-linux-armhf.so.3 ... for GNU/Linux 3.2.0, stripped`.

### Run

    ./ddrbench [base] [size_mib] [lat|rnd|bw|wr|rw]

Defaults: base `0x10000000`, 4 MiB, all tests. The region **must stay inside the
256 MiB no-map window** (`0x10000000`-`0x20000000`); anything else overlaps Linux
memory and will corrupt the system. The binary warns if the region is outside it.

### Contention scenarios (run the same binary in all three)

| Context | What it measures |
|---|---|
| Menu up, video live | worst case: 128-bit port 0 (ascal/LFB) hammering the controller |
| A core running, video live | realistic gameplay load |
| Video idle / no display | baseline, no FPGA traffic |

Compare the p50/p99/max of "single read (seq)" across the three. A jump in p99
between baseline and menu = the scaler steals bandwidth (FINDINGS §16e "direct
video" mitigation). A high baseline p99 = refresh/HPS-internal jitter.

### Timing

The benchmark prefers the Cortex-A9 PMU cycle counter (`PMCCNTR`); if the kernel
has not enabled user access (PMUSERENR=0) it falls back to the **ARM global
timer at `0xFFFEC200`** read over `/dev/mem` (always works — Linux uses only the
TWD timer as its clock, so the global timer is free; `CNTCR.EN` is set if needed).
Only if even that fails does it use `CLOCK_MONOTONIC` ns, and then it prints a
COARSE warning: per-access stats include ~1 us of `clock_gettime` overhead and
only the bulk bandwidth numbers are trustworthy. The active source's rate and
the `now()` loop overhead are calibrated at startup and subtracted.

### Region contents

On start the benchmark **overwrites the region** with `base[i] = 0xA5A5A5A5 ^ i`
and prints `verify: N errors / M words` to prove the read path returns what was
written (a nonzero `sum` in the latency lines confirms the same). This is the
bench area — nothing else should live there.

---

## Phase 2 - FPGA-side RTL benchmark

`ddrbench.v` cycles through three phases continuously, pacing ~64 ms between
batches so it does not starve the HPS:

| Phase | Access | Mailbox numbers (cycles @ core clock) |
|---|---|---|
| 0 | single-word read, `BURSTCNT=1` | first-word latency min/avg/max |
| 1 | burst read, `BURSTCNT=8` (64 B) | first-word latency + total burst time |
| 2 | write 1 word then read it back | write→readback round trip |

Mailbox (6 x 64-bit words at `0x10000000`), refreshed every batch:

    +0x00  { phase[7:0], count[15:0], magic 0x534E4150 ("PANS") }
    +0x08  min first-word latency (cycles @ ram_clk)
    +0x10  avg first-word latency
    +0x18  max first-word latency
    +0x20  { data_xor[31:0], burst[7:0], stride[15:0], reserved }
    +0x28  avg total access time (burst length; phase 1 = 8 words)

`magic != "PANS"` → the FPGA is not running ddrbench (or the core changed).
`data_xor` is a running XOR of every returned read word's 32-bit halves; it
validates that reads actually return DDR contents (compare against a checksum
the app computes over the same region).

### Integration (bench-only Quartus build)

1. In the bring-up project (`fpga/`), replace the core's `DDRAM_*` wiring in
   `sys_top.v` (~line 1823) with `ddrbench`; it becomes the only driver of ram1.
   The bench free-runs; no core logic is required.
2. Board constraints unchanged (ram1 is an internal HPS interface).
3. Read the mailbox from the HPS:

       ./ddrbench 0x10000000 4 rnd   # just verify the region is readable
       devmem 0x10000000              # or: busybox devmem for word 0 (magic)

### iverilog smoke test

    iverilog -g2012 -Wall -o /tmp/ddrbench_sim ddrbench.v tb_ddrbench.v && /tmp/ddrbench_sim

Models the port with a fixed 20-cycle read latency / 8-cycle writes. Expected:
phase 0 min/avg/max = 22, phase 1 first-word 22 / total 29 (8 words), phase 2 = 22,
18 mailbox writes total.

---

## Reading the results

- Single-word read latency (cycles @ `ram_clk`) × 10 ns (100 MHz) ≈ ns.
- Phase 1 total vs phase 0: if burst total ≈ first-word latency + 8, the port
  streams ~1 word/cycle after the first → the bandwidth-rich story holds.
- Phase 2 (write+readback) vs phase 0: writes should add little; a large gap
  means write-drain is the cost.

Conclusion mapping (FINDINGS §16g): if single-word latency stays >300 ns even at
video-idle, the raw random-access path is too slow for latency-critical cores and
the simulated-SRAM shim must rely on cache lines + bursts only. If it is ~200 ns
with clean burst amortization, the cache-line shim (16-bit port, 64-128-bit
line, prefetch) is worth building for streaming-tolerant cores (arcade/SNES-style).

Note: the cache-line shim already exists as `sdram_on_ddr.sv` (FINDINGS §22) and
is wired into TI-99 and Amstrad; the phase-3 goal is now to validate it on the
board against these numbers, optionally with SDRAMC pacing config.
