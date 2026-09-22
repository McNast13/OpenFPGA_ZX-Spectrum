`timescale 1ns/1ps
// Standalone simulation testbench for the USB-HID -> ps2_key bridge and
// keyboard.sv integration exactly as wired in core_top.sv, used to verify
// press/hold/release behaviour without needing real Pocket hardware.
// Run with: iverilog -g2012 -o tb.vvp tb_keyboard.sv <deps...> && vvp tb.vvp

module tb_keyboard;

    reg clk_sys = 0;
    always #4.464 clk_sys = ~clk_sys; // ~8.928ns period, matches the real design's clk_sys timing report

    reg reset = 1;

    reg [31:0] cont3_key  = 0;
    reg [31:0] cont3_joy  = 0;
    reg [15:0] cont3_trig = 0;

    reg [15:0] addr = 16'hFFFF;

    integer errors = 0;

    // ---- exact glue logic from core_top.sv ----
    wire [10:0] ps2_key_usb;
    usb_keyboard usb_kbd (
        .clk        ( clk_sys     ),
        .clk_sync   ( clk_sys     ),
        .reset      ( reset       ),
        .cont3_key  ( cont3_key   ),
        .cont3_joy  ( cont3_joy   ),
        .cont3_trig ( cont3_trig  ),
        .ps2_key    ( ps2_key_usb )
    );

    reg  [9:0] ps2_key_usb_prev = 0; // raw source value, ALWAYS updates - never gated
    reg        ps2_toggle       = 0;
    reg  [9:0] ps2_key_latched  = 0;
    always @(posedge clk_sys) begin
        ps2_key_usb_prev <= ps2_key_usb[9:0];
        if (ps2_key_usb[10] && (ps2_key_usb[9:0] != ps2_key_usb_prev)) begin
            ps2_toggle      <= ~ps2_toggle;
            ps2_key_latched <= ps2_key_usb[9:0];
        end
    end
    wire [10:0] ps2_key = {ps2_toggle, ps2_key_latched};

    wire       recreated_zx = 1'b0;
    wire       ghosting     = 1'b0;
    wire [4:0] hw_key_data;
    wire [11:1] Fn_hw;
    wire  [2:0] mod_hw;

    keyboard kbd (
        .reset       ( reset        ),
        .clk_sys     ( clk_sys      ),
        .ps2_key     ( ps2_key      ),
        .recreated_zx( recreated_zx ),
        .ghosting    ( ghosting     ),
        .addr        ( addr         ),
        .key_data    ( hw_key_data  ),
        .Fn          ( Fn_hw        ),
        .mod         ( mod_hw       )
    );
    // ---- end glue logic ----

    // Helpers: set the HID report (type=4 "docked keyboard", one scancode slot)
    task set_key(input [7:0] sc);
        begin
            cont3_key  = {4'h4, 4'h0, 8'h00, 8'h00, 8'h00};
            cont3_joy  = {sc, 8'h00, 8'h00, 8'h00};
            cont3_trig = 16'h0000;
        end
    endtask

    task set_idle;
        begin
            cont3_key  = {4'h4, 28'h0};
            cont3_joy  = 32'h0;
            cont3_trig = 16'h0;
        end
    endtask

    // Select ULA row for reading (addr row-select bits are active-low)
    task select_row(input integer row);
        begin
            addr = 16'hFFFF;
            addr[8+row] = 1'b0;
            #1; // let the purely-combinational key_data settle before reading it
        end
    endtask

    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin
                $display("FAIL: %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    integer i;
    initial begin
        set_idle;
        select_row(1); // row1 holds 'a' (col0) and 's' (col1)

        repeat (20) @(posedge clk_sys);
        reset = 0;
        repeat (20) @(posedge clk_sys);

        // 1) Idle: 'a' bit should read released (1)
        check(hw_key_data[0] === 1'b1, "idle: 'a' bit released before any keypress");

        // 2) Press 'a' (USB 0x04 -> PS/2 0x1C -> row1 col0)
        set_key(8'h04);
        repeat (600) @(posedge clk_sys); // generous margin for FIFO+14-slot arbiter scan + latch
        check(hw_key_data[0] === 1'b0, "press 'a': row1 col0 goes low (pressed)");

        // 3) Long hold - previously this is exactly where the repeat-generator
        //    filled the FIFO. With it disabled, nothing should change while
        //    held, and no writes should be dropped later.
        for (i = 0; i < 40; i = i + 1) begin
            repeat (5000) @(posedge clk_sys);
            check(hw_key_data[0] === 1'b0, "hold 'a': still pressed mid-hold");
        end

        // 4) Release - this is the exact case that broke before the fix:
        //    release event landing while the FIFO was backlogged/full.
        set_idle;
        repeat (600) @(posedge clk_sys);
        check(hw_key_data[0] === 1'b1, "release 'a': row1 col0 goes back high (released) - THE BUG");

        // 5) Press a different key ('b', USB 0x05 -> PS/2 0x32 -> row7 col4) and
        //    confirm 'a' does NOT appear stuck/pressed from stale state.
        select_row(7);
        set_key(8'h05);
        repeat (600) @(posedge clk_sys);
        check(hw_key_data[4] === 1'b0, "press 'b': row7 col4 goes low (pressed)");
        select_row(1);
        repeat (10) @(posedge clk_sys);
        check(hw_key_data[0] === 1'b1, "'a' still reads released while 'b' is held");

        set_idle;
        repeat (600) @(posedge clk_sys);
        select_row(7);
        check(hw_key_data[4] === 1'b1, "release 'b': row7 col4 goes back high (released)");

        // 6) Rapid sequential taps of different keys (s, then a) with short holds
        select_row(1);
        set_key(8'h16); // 's' -> row1 col1
        repeat (600) @(posedge clk_sys);
        check(hw_key_data[1] === 1'b0, "rapid: 's' pressed");
        set_idle;
        repeat (600) @(posedge clk_sys);
        check(hw_key_data[1] === 1'b1, "rapid: 's' released");
        set_key(8'h04); // 'a' again
        repeat (600) @(posedge clk_sys);
        check(hw_key_data[0] === 1'b0, "rapid: 'a' pressed again");
        set_idle;
        repeat (600) @(posedge clk_sys);
        check(hw_key_data[0] === 1'b1, "rapid: 'a' released again");

        if (errors == 0) $display("\n==== ALL CHECKS PASSED ====");
        else $display("\n==== %0d CHECK(S) FAILED ====", errors);

        $finish;
    end

    initial begin
        #20000000; // 20ms safety timeout
        $display("FAIL: simulation timeout - something hung");
        $finish;
    end

endmodule
