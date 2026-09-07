`timescale 1ns/1ps
// ddrbench.v - FPGA-side F2SDRAM (ram1, 64-bit) latency/bandwidth benchmark.
// Drives the same DDRAM_* signals a core uses and continuously cycles through
// three phases, writing a result mailbox back to SDRAM so the HPS app can read
// it over /dev/mem with NO FPGA<->HPS handshake:
//
//   mailbox @ MBOX+0x00 (64-bit): {phase[7:0], iter[15:0], magic 32'h534E4150}
//   mailbox @ MBOX+0x08 (64-bit): min  first-word read latency (cycles @ clk)
//   mailbox @ MBOX+0x10 (64-bit): avg  first-word read latency
//   mailbox @ MBOX+0x18 (64-bit): max  first-word read latency
//   mailbox @ MBOX+0x20 (64-bit): {data_xor[31:0], burst[7:0], stride[15:0], rsv}
//   mailbox @ MBOX+0x28 (64-bit): avg total access cycles (burst length)
//
// Phases:
//   0  single-word read latency   (DDRAM_BURSTCNT=1, 1024 iters)
//   1  burst read latency         (DDRAM_BURSTCNT=8 -> 64 B per access)
//   2  write+readback round trip  (write 1 word, read it back; cycles from the
//                                  write issue to the read's DOUT_READY)
//
// The bench is PACED (PACE clocks between phase batches, ~64 ms @ 100 MHz) so
// it is a well-behaved DDR citizen and does not starve the HPS.
//
// Integration: replace the core's DDRAM wiring in sys_top.v (~line 1823) with
// this module (it is the only driver of ram1 in a bench-only build). No other
// core logic needs to exist. The app reads the mailbox with the uncached
// /dev/mem tooling in hps_ddr_bench.c (base 0x10000000).
//
// ADDRESSES ARE BYTES: MBOX/CORE_BASE/RANGE_MASK/STRIDE are all byte values.
// The ram1 port is 64-bit and its Avalon ADDRESS is a WORD address (physical
// byte = word << 3, FINDINGS 21a), so every address is shifted >>3 at the
// DDRAM_ADDR assignment. The bench region lives at 0x10000000 (base of the
// 256 MiB no-map reservation) -- free under the menu and every non-ao486 RBF,
// and clear of the ascal vbuf (0x1E800000-0x20000000).
//
// Interface contract (same as ddram.sv / ddr_svc.sv):
//   - assert DDRAM_RD (or DDRAM_WE) while DDRAM_BUSY is low, holding
//     DDRAM_ADDR/DDRAM_BURSTCNT/DDRAM_DIN stable;
//   - one DDRAM_DOUT_READY pulse per returned word; deassert the request line
//     for at least one cycle between requests (see S_RDGAP).

module ddrbench #(
	parameter [28:0] MBOX       = 29'h10000000,  // mailbox base (BYTE address, reserved top half)
	parameter [28:0] CORE_BASE  = 29'h10000040,  // bench region base (BYTE address, above the mailbox)
	parameter [23:0] RANGE_MASK = 24'h3FFFFF,    // bench region span (4 MiB, bytes)
	parameter [23:0] COUNT      = 24'd1024,      // accesses per phase
	parameter [15:0] STRIDE     = 16'd64,        // byte stride between accesses
	parameter [31:0] PACE       = 32'd6400000    // ~64 ms between phase batches @ 100 MHz
)(
	input         clk,
	input         reset,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE
);

assign DDRAM_CLK = clk;
assign DDRAM_BURSTCNT = ddr_bc;
assign DDRAM_ADDR     = ddr_addr;
assign DDRAM_DIN      = ddr_din;
assign DDRAM_BE       = 8'hFF;
assign DDRAM_RD       = ddr_rd;
assign DDRAM_WE       = ddr_we;

localparam S_IDLE   = 4'd0;
localparam S_RD     = 4'd1;   // issue a read
localparam S_RDWAIT = 4'd2;   // wait for DOUT_READY pulses
localparam S_RDGAP  = 4'd3;   // guarantee >=1 cycle with the request line low
localparam S_WISSUE = 4'd4;   // issue a write (phase 2)
localparam S_WHELD  = 4'd5;   // write captured, hold one cycle
localparam S_WLOW   = 4'd6;   // wait for write to drain, then read back
localparam S_MB     = 4'd7;   // mailbox: issue one 64-bit write
localparam S_MBHLD  = 4'd8;
localparam S_MBLOW  = 4'd9;
localparam S_PACE   = 4'd10;  // pacing delay between phases

reg [3:0]  state;
reg [1:0]  phase;
reg [23:0] iter;
reg        rdback;
reg        first;
reg  [7:0] got;
reg  [7:0] burst;
reg [15:0] cyc;
reg [15:0] lat;
reg [31:0] acc_min, acc_max, acc_sum;
reg [31:0] acc_tmin, acc_tmax, acc_tsum;
reg [31:0] data_xor;
reg [31:0] pace;
reg  [7:0] mbw;

reg        ddr_rd, ddr_we;
reg  [28:0] ddr_addr;
reg  [7:0]  ddr_bc;
reg  [63:0] ddr_din;

wire [28:0] access_byte = CORE_BASE + ({5'b0, (iter * STRIDE)} & {5'b0, RANGE_MASK});
wire [28:0] access_addr = access_byte >> 3;   // ram1 64-bit port: word address = byte >> 3

reg [63:0] mbval;
always @(*) begin
	case (mbw)
		5'd0: mbval = {phase, COUNT[15:0], 32'h534E4150};
		5'd1: mbval = acc_min;
		5'd2: mbval = acc_sum / COUNT;
		5'd3: mbval = acc_max;
		5'd4: mbval = {data_xor, burst, STRIDE, 8'h0};
		default: mbval = acc_tsum / COUNT;
	endcase
end

wire [15:0] curlat = first ? cyc : lat;   // first-word latency, valid the same cycle it is captured

always @(posedge clk) begin
	if (reset) begin
		state   <= S_IDLE;
		phase   <= 2'd0;
		iter    <= 24'd0;
		rdback  <= 1'b0;
		first   <= 1'b1;
		got     <= 8'd0;
		burst   <= 8'd1;
		cyc     <= 16'd0;
		lat     <= 16'd0;
		acc_min <= 32'hFFFFFFFF;
		acc_max <= 32'd0;
		acc_sum <= 32'd0;
		acc_tmin <= 32'hFFFFFFFF;
		acc_tmax <= 32'd0;
		acc_tsum <= 32'd0;
		data_xor <= 32'd0;
		pace    <= 32'd0;
		mbw     <= 8'd0;
		ddr_rd  <= 1'b0;
		ddr_we  <= 1'b0;
		ddr_addr<= 29'd0;
		ddr_bc  <= 8'd1;
		ddr_din <= 64'd0;
	end else begin
		ddr_rd <= 1'b0;   // deassert request lines every cycle; re-assert below
		ddr_we <= 1'b0;
		cyc    <= cyc + 16'd1;

		case (state)
		S_IDLE: begin
			acc_min  <= 32'hFFFFFFFF;
			acc_max  <= 32'd0;
			acc_sum  <= 32'd0;
			acc_tmin <= 32'hFFFFFFFF;
			acc_tmax <= 32'd0;
			acc_tsum <= 32'd0;
			data_xor <= 32'd0;
			iter     <= 24'd0;
			mbw      <= 8'd0;
			burst    <= (phase == 2'd0) ? 8'd1 : (phase == 2'd1) ? 8'd8 : 8'd1;
			state    <= S_RD;
		end

		// ----- reads (phases 0/1) and the read-back half of phase 2 -----
		S_RD: begin
			if (!DDRAM_BUSY) begin
				ddr_addr <= access_addr;
				ddr_bc   <= burst;
				ddr_rd   <= 1'b1;
				got      <= 8'd0;
				first    <= 1'b1;
				if (rdback) cyc <= cyc;        // keep the phase-2 round-trip timer
				else        cyc <= 16'd0;      // fresh access: restart the timer
				state <= S_RDWAIT;
			end
		end

		S_RDWAIT: begin
			if (DDRAM_DOUT_READY) begin
				data_xor <= data_xor ^ DDRAM_DOUT[63:32] ^ DDRAM_DOUT[31:0];
				if (first) begin
					first <= 1'b0;
					lat   <= cyc;              // latency to first returned word
				end
				got <= got + 8'd1;
				if ((got + 8'd1) == burst) begin
					acc_min  <= (curlat < acc_min)  ? curlat : acc_min;
					acc_max  <= (curlat > acc_max)  ? curlat : acc_max;
					acc_sum  <= acc_sum + curlat;
					acc_tmin <= (cyc < acc_tmin) ? cyc : acc_tmin;
					acc_tmax <= (cyc > acc_tmax) ? cyc : acc_tmax;
					acc_tsum <= acc_tsum + cyc;
					iter     <= iter + 24'd1;
					rdback   <= 1'b0;
					if (iter + 24'd1 >= COUNT) state <= S_MB;
					else                       state <= S_RDGAP;
				end
			end
		end

		S_RDGAP: begin                            // >=1 cycle with ddr_rd low
			if (!DDRAM_BUSY) state <= S_RD;
		end

		// ----- writes (phase 2 first half) -----
		S_WISSUE: begin
			if (!DDRAM_BUSY) begin
				ddr_addr <= access_addr;
				ddr_bc   <= 8'd1;
				ddr_din  <= {4{access_addr[15:0]}};
				ddr_we   <= 1'b1;
				cyc      <= 16'd0;
				state    <= S_WHELD;
			end
		end

		S_WHELD: begin
			state <= S_WLOW;
		end

		S_WLOW: begin
			if (!DDRAM_BUSY) begin
				rdback <= 1'b1;                  // read back the same address
				state  <= S_RDGAP;
			end
		end

		// ----- mailbox: write 6 x 64-bit words back to SDRAM -----
		S_MB: begin
			if (!DDRAM_BUSY) begin
				ddr_addr <= (MBOX >> 3) + {5'b0, mbw[4:0]};   // word = (byte base >> 3) + index
				ddr_bc   <= 8'd1;
				ddr_din  <= mbval;
				ddr_we   <= 1'b1;
				state    <= S_MBHLD;
			end
		end

		S_MBHLD: begin
			state <= S_MBLOW;
		end

		S_MBLOW: begin
			if (!DDRAM_BUSY) begin
				if (mbw == 8'd5) begin
					phase <= phase + 2'd1;
					state <= S_PACE;
				end else begin
					mbw   <= mbw + 8'd1;
					state <= S_MB;
				end
			end
		end

		S_PACE: begin
			if (pace >= PACE) begin
				pace  <= 32'd0;
				state <= S_IDLE;
			end else begin
				pace <= pace + 32'd1;
			end
		end

		default: state <= S_IDLE;   // recover from any illegal state
		endcase
	end
end

endmodule
