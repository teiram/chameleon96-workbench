// tb_ddrbench.v - smoke test: model the ram1 F2SDRAM port, run ddrbench
// through phases 0/1/2, and print the mailbox writes it issues back to DDR.
`timescale 1ns/1ps

module tb;
	reg clk = 0;
	reg reset = 1;

	reg        DDRAM_BUSY = 0;
	wire [7:0] DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	reg  [63:0] DDRAM_DOUT = 0;
	reg         DDRAM_DOUT_READY = 0;
	wire        DDRAM_RD;
	wire [63:0] DDRAM_DIN;
	wire  [7:0] DDRAM_BE;
	wire        DDRAM_WE;

	localparam RD_LAT = 20;
	localparam WR_LAT = 8;

	reg rd_seen = 0, ret_left_is1 = 0;
	integer lat;
	reg [7:0] ret_left;

	// --- model of the F2SDRAM port ---
	always @(posedge clk) begin
		DDRAM_DOUT_READY <= 0;
		if (!DDRAM_BUSY) begin
			if (DDRAM_RD) begin
				DDRAM_BUSY <= 1; rd_seen <= 1; lat <= RD_LAT; ret_left <= DDRAM_BURSTCNT;
			end else if (DDRAM_WE) begin
				DDRAM_BUSY <= 1; rd_seen <= 0; lat <= WR_LAT;
			end
		end else begin
			if (lat > 0) lat <= lat - 1;
			else if (rd_seen) begin
				DDRAM_DOUT_READY <= 1;
				DDRAM_DOUT <= DDRAM_ADDR;
				ret_left <= ret_left - 1;
				if (ret_left == 1) begin DDRAM_BUSY <= 0; rd_seen <= 0; end
			end else begin
				DDRAM_BUSY <= 0;
			end
		end
	end

	// --- dump every write the bench issues back to SDRAM ---
	integer nw = 0;
	always @(posedge clk) if (DDRAM_WE) begin
		nw = nw + 1;
		$display("WE[%0d] addr=%h din=%h", nw, DDRAM_ADDR, DDRAM_DIN);
	end

	// --- debug: log mailbox entry with the accumulated stats ---
	always @(posedge clk)
		if (uut.state == tb.uut.S_MB)
			$display("MB  phase=%0d acc_min=%0d acc_max=%0d acc_sum=%0d acc_tsum=%0d",
			         uut.phase, uut.acc_min, uut.acc_max, uut.acc_sum, uut.acc_tsum);

	ddrbench #(
		.COUNT(24'd64),
		.PACE(32'd32)
	) uut (
		.clk(clk), .reset(reset),
		.DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
	);

	always #5 clk = ~clk;

	integer i;
	reg done = 0;
	initial begin
		$dumpfile("/tmp/ddrbench.vcd");
		$dumpvars(0, tb);
		repeat (3) @(posedge clk);
		reset = 0;
		// 3 phases * (64 iters * ~(RD_LAT+2 or WR_LAT+RD_LAT)) + mailboxes + paces
		for (i = 0; i < 30000 && !done; i++) begin
			@(posedge clk);
			if (nw == 18) done = 1;
		end
		$display("SIM END: mailbox writes = %0d (expect 18)", nw);
		$finish;
	end
endmodule
