////////////////////////////////////////////////////////////////////////////////
//
//  USB HID-to-Kempston Mouse
//  Originally "PS2-to-Kempston Mouse" (C) 2017 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
////////////////////////////////////////////////////////////////////////////////
//
// Rewritten 2026 to take a docked USB mouse's report directly (as
// core_top.sv extracts it from the Pocket's cont4_* controller-bus report,
// type 0x5 - see Analogue's openFPGA bus-communication docs) instead of a
// MiSTer-style PS/2 mouse packet. hid_counter/hid_dx/hid_dy/hid_buttons are
// already synchronized into clk_sys by the caller; this module never sees
// a PS/2 packet byte, sign/overflow bit, or serial protocol of any kind -
// hid_dx/hid_dy are plain signed values, no packet-format decoding needed.
// The Kempston Mouse I/O-port side (addr/sel/dout, the accumulate-and-
// saturate dx/dy logic) is unchanged from upstream - only the input side
// changed shape.
////////////////////////////////////////////////////////////////////////////////

module mouse
(
	input        clk_sys,
	input        reset,

	// hid_counter increments (from the host, arbitrary step size) each
	// time a new mouse report has arrived; comparing it for ANY change
	// - not just an edge on a single bit - is what "there's a new report
	// to consume" means here. The caller holds this at a fixed value
	// whenever cont4's current report isn't actually a mouse (type !=
	// 0x5), so a plugged-in gamepad's unrelated cont4 traffic can never
	// be misread as mouse movement.
	input [15:0] hid_counter,
	input signed [15:0] hid_dx,
	input signed [15:0] hid_dy,
	input  [2:0] hid_buttons, // bit0=left bit1=right bit2=middle
	input        btn_swap,

	input  [2:0] addr,
	output       sel,
	output [7:0] dout
);

assign dout = data;
assign sel  = port_sel;

reg  [2:0] buttons;
reg [19:0] dx; // 8 bits of Kempston-visible range + 12 bits of headroom -
reg [19:0] dy; // wide enough that even a full-range 16-bit HID delta can't
                // wrap the accumulator itself; only the explicit saturate
                // below decides byte-level clamping, same as upstream.

wire [19:0] newdx = dx + {{4{hid_dx[15]}}, hid_dx};
wire [19:0] newdy = dy + {{4{hid_dy[15]}}, hid_dy};

reg   [7:0] data;
reg         port_sel;
always @* begin
	port_sel = 1;
	casex(addr)
		 3'b011: data = dx[7:0];
		 3'b111: data = dy[7:0];
		 3'bX10: data = ~{5'b00000, buttons[2], buttons[~btn_swap], buttons[btn_swap]};
		default: {port_sel,data} = 8'hFF;
	endcase
end

reg [15:0] old_counter;
always @(posedge clk_sys) begin
	if (reset) begin
		dx          <= 20'd128; // dx != dy for better mouse detection
		dy          <= 20'd0;
		buttons     <= 3'b000;
		old_counter <= hid_counter;
	end else begin
		old_counter <= hid_counter;
		if (old_counter != hid_counter) begin
			buttons <= hid_buttons;
			// If this single report's delta would need more than the
			// low byte to represent (i.e. any of the headroom bits are
			// set), clamp to the extreme instead of letting the
			// accumulator wrap unpredictably - same behaviour as
			// upstream's PS/2 version, generalized from an 8-bit-range
			// delta to HID's wider one.
			dx <= |newdx[19:8] ? {12'h000, {8{~hid_dx[15]}}} : newdx;
			dy <= |newdy[19:8] ? {12'h000, {8{~hid_dy[15]}}} : newdy;
		end
	end
end

endmodule
