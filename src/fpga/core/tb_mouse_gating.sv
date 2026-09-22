`timescale 1ns/1ps
// Validates the docked-mouse report-type gating logic exactly as wired in
// core_top.sv (mouse_en/is_mouse/mouse_counter/mouse_sel), including the
// cont4_key/cont4_joy -> narrowed-and-packed synchronizer layout (only
// the bits actually used are synchronized, packed as {type,counter} and
// {buttons,dx} - see core_top.sv's cont4_key_s/cont4_joy_s comment for
// why) - kept as a separate, self-contained copy of those wire
// expressions rather than pulling in the whole of core_top.sv, since it
// has no other dependencies of its own. If core_top.sv's gating logic
// changes, update this file's copy to match. mouse.v's own accumulator
// logic is covered separately by tb_mouse.sv.
//
//   iverilog -g2012 -o tb.vvp tb_mouse_gating.sv
//   vvp tb.vvp
module tb_mouse_gating;

    reg [31:0] cont4_key = 0; // raw, pre-synchronizer (synch_3 itself not modeled - just its packing)
    reg [31:0] cont4_joy = 0;
    reg [15:0] status35_34 = 0; // maps to status[35:34]
    reg [7:0]  addr = 0;
    wire       mouse_reg_sel_stub;

    // Mirrors core_top.sv's cont4_key_s/cont4_joy_s exactly: only the
    // bits actually read are carried through, packed narrower than the
    // raw 32-bit words to reduce synchronizer footprint (this replaced
    // a full-width version after CI timing showed it pushing unrelated
    // SDRAM paths into violation on an already 92%+ ALM-full device).
    wire [19:0] cont4_key_s = {cont4_key[31:28], cont4_key[15:0]};
    wire [18:0] cont4_joy_s = {cont4_joy[18:16], cont4_joy[15:0]};

    wire       mouse_en = |status35_34;
    wire       is_mouse = cont4_key_s[19:16] == 4'h5;
    wire [15:0] mouse_counter = is_mouse ? cont4_key_s[15:0] : 16'h0;
    wire [2:0] mouse_buttons = cont4_joy_s[18:16];
    assign mouse_reg_sel_stub = 1'b1; // pretend addr[10:8] always matches, isolating just the type/enable gating
    wire       mouse_sel = mouse_en & (addr[7:0] == 8'hDF) & mouse_reg_sel_stub;

    integer errors = 0;
    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin $display("FAIL: %0s", msg); errors = errors + 1; end
        end
    endtask

    initial begin
        // Not a mouse report (e.g. a regular gamepad in cont4) - counter
        // must be held at 0 regardless of what garbage cont4_key[15:0]
        // contains, and mouse_buttons is irrelevant since mouse.v will
        // never sample it (counter never changes).
        cont4_key = {4'h0, 12'hABC, 16'hBEEF}; #1; // type=0, garbage elsewhere
        check(is_mouse === 1'b0, "non-mouse type: is_mouse false");
        check(mouse_counter === 16'h0, "non-mouse type: counter held at 0 despite garbage cont4_key[15:0]");

        // Genuine mouse report
        cont4_key = {4'h5, 12'h000, 16'h1234}; #1;
        check(is_mouse === 1'b1, "mouse type (0x5): is_mouse true");
        check(mouse_counter === 16'h1234, "mouse type: counter passes through cont4_key[15:0]");

        // Mouse disabled in menu - mouse_sel must never assert even with
        // a genuine mouse report and matching address
        status35_34 = 0;
        addr = 8'hDF; #1;
        check(mouse_en === 1'b0, "menu disabled (00): mouse_en false");
        check(mouse_sel === 1'b0, "menu disabled: mouse_sel never asserts even at the right address");

        // Enabled, normal order
        status35_34 = 1; #1;
        check(mouse_en === 1'b1, "menu Kempston L/R (01): mouse_en true");
        check(mouse_sel === 1'b1, "menu enabled + correct address: mouse_sel asserts");

        // Enabled, swapped order
        status35_34 = 2; #1;
        check(mouse_en === 1'b1, "menu Kempston R/L (10): mouse_en true");

        // Wrong address - mouse_sel must not assert even when enabled
        addr = 8'h1F; #1; // the joystick port, not the mouse port
        check(mouse_sel === 1'b0, "enabled but wrong address (0x1F not 0xDF): mouse_sel deasserts");

        // Button bit extraction
        cont4_joy = {13'h0, 1'b1 /*middle*/, 1'b0 /*right*/, 1'b1 /*left*/, 16'h0}; #1;
        check(mouse_buttons === 3'b101, "button extraction: {middle,right,left} = 101");

        if (errors == 0) $display("\n==== ALL GATING CHECKS PASSED ====");
        else $display("\n==== %0d GATING CHECK(S) FAILED ====", errors);
        $finish;
    end
endmodule
