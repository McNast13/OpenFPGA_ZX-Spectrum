`timescale 1ns/1ps
// Stress test: QAOP+Space (Q=up/jump, A=down, O=left, P=right, Space=punch)
// - the classic Spectrum beat-em-up scheme. For every pair of these 5 keys,
// hold one while rapidly mashing the other many times, checking both track
// correctly throughout. User couldn't pin down the exact combo that broke
// in Renegade, just that it followed "mash one key while holding another".

module tb_mash;

    reg clk_sys = 0;
    always #4.464 clk_sys = ~clk_sys;

    reg reset = 1;
    reg [31:0] cont3_key  = 0;
    reg [31:0] cont3_joy  = 0;
    reg [15:0] cont3_trig = 0;

    wire [10:0] ps2_key_usb;
    wire  [7:0] usb_kb_mod, usb_kb_sc1, usb_kb_sc2, usb_kb_sc3, usb_kb_sc4, usb_kb_sc5, usb_kb_sc6;
    wire [63:0] usb_kb_hid;
    usb_keyboard usb_kbd (
        .clk(clk_sys), .clk_sync(clk_sys), .reset(reset),
        .cont3_key(cont3_key), .cont3_joy(cont3_joy), .cont3_trig(cont3_trig),
        .usb_kb_hid(usb_kb_hid), .usb_kb_mod(usb_kb_mod),
        .usb_kb_sc1(usb_kb_sc1), .usb_kb_sc2(usb_kb_sc2), .usb_kb_sc3(usb_kb_sc3),
        .usb_kb_sc4(usb_kb_sc4), .usb_kb_sc5(usb_kb_sc5), .usb_kb_sc6(usb_kb_sc6),
        .ps2_key(ps2_key_usb)
    );

    logic [71:0] live_mods;
    logic  [8:0] live_sc1, live_sc2, live_sc3, live_sc4, live_sc5, live_sc6;
    hid2ps2_mod u_live_mod (.clk(~clk_sys), .usb(usb_kb_mod), .ps2(live_mods));
    hid2ps2_key u_live_sc1 (.clk(~clk_sys), .usb(usb_kb_sc1), .ps2(live_sc1));
    hid2ps2_key u_live_sc2 (.clk(~clk_sys), .usb(usb_kb_sc2), .ps2(live_sc2));
    hid2ps2_key u_live_sc3 (.clk(~clk_sys), .usb(usb_kb_sc3), .ps2(live_sc3));
    hid2ps2_key u_live_sc4 (.clk(~clk_sys), .usb(usb_kb_sc4), .ps2(live_sc4));
    hid2ps2_key u_live_sc5 (.clk(~clk_sys), .usb(usb_kb_sc5), .ps2(live_sc5));
    hid2ps2_key u_live_sc6 (.clk(~clk_sys), .usb(usb_kb_sc6), .ps2(live_sc6));

    function automatic logic code_is_live(input [8:0] code);
        begin
            code_is_live =
                (code != 9'h0) && (
                (live_mods[71:63] == code) || (live_mods[62:54] == code) ||
                (live_mods[53:45] == code) || (live_mods[44:36] == code) ||
                (live_mods[35:27] == code) || (live_mods[26:18] == code) ||
                (live_mods[17:9]  == code) || (live_mods[8:0]   == code) ||
                (live_sc1 == code) || (live_sc2 == code) || (live_sc3 == code) ||
                (live_sc4 == code) || (live_sc5 == code) || (live_sc6 == code));
        end
    endfunction

    reg  [9:0] ps2_key_usb_prev = 0;
    reg        ps2_toggle       = 0;
    reg  [9:0] ps2_key_latched  = 0;
    always @(posedge clk_sys) begin
        ps2_key_usb_prev <= ps2_key_usb[9:0];
        if (ps2_key_usb[10] && (ps2_key_usb[9:0] != ps2_key_usb_prev)) begin
            if (ps2_key_usb[9] || !code_is_live(ps2_key_usb[8:0])) begin
                ps2_toggle      <= ~ps2_toggle;
                ps2_key_latched <= ps2_key_usb[9:0];
            end
        end
    end
    wire [10:0] ps2_key = {ps2_toggle, ps2_key_latched};

    reg [15:0] addr = 16'hFFFF;
    wire [4:0] hw_key_data;
    wire [11:1] Fn_hw;
    wire  [2:0] mod_hw;
    keyboard kbd (
        .reset(reset), .clk_sys(clk_sys), .ps2_key(ps2_key),
        .recreated_zx(1'b0), .ghosting(1'b0), .addr(addr),
        .key_data(hw_key_data), .Fn(Fn_hw), .mod(mod_hw)
    );

    integer errors = 0;

    // Q=USB0x14/row2col0  A=USB0x04/row1col0  O=USB0x12/row5col1
    // P=USB0x13/row5col0  SPACE=USB0x2C/row7col0
    // slots: sc1..sc4 in cont3_joy, sc5..sc6 in cont3_trig
    task set4(input [7:0] sc1, input [7:0] sc2, input [7:0] sc3, input [7:0] sc4);
        begin
            cont3_key  = {4'h4, 28'h0};
            cont3_joy  = {sc1, sc2, sc3, sc4};
        end
    endtask

    task select_row(input integer row);
        begin
            addr = 16'hFFFF;
            addr[8+row] = 1'b0;
            #1;
        end
    endtask

    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin $display("FAIL: %0s", msg); errors = errors + 1; end
        end
    endtask

    // Hold `held_sc` in slot1, mash `mash_sc` in slot2 N times, verify both
    // read correctly on every iteration, then release both and verify clean.
    task hold_and_mash(
        input [7:0] held_sc, input integer held_row, input integer held_col,
        input [7:0] mash_sc, input integer mash_row, input integer mash_col,
        input [255:0] label
    );
        integer i;
        begin
            set4(held_sc, 8'h00, 8'h00, 8'h00);
            repeat (300) @(posedge clk_sys);
            select_row(held_row);
            check(hw_key_data[held_col] === 1'b0, {label, ": held key pressed before mashing"});

            for (i = 0; i < 15; i = i + 1) begin
                set4(held_sc, mash_sc, 8'h00, 8'h00);
                repeat (250) @(posedge clk_sys);
                select_row(held_row); check(hw_key_data[held_col] === 1'b0, {label, ": held key still pressed during mash-down"});
                select_row(mash_row); check(hw_key_data[mash_col] === 1'b0, {label, ": mashed key pressed"});
                set4(held_sc, 8'h00, 8'h00, 8'h00);
                repeat (250) @(posedge clk_sys);
                select_row(held_row); check(hw_key_data[held_col] === 1'b0, {label, ": held key still pressed during mash-up"});
                select_row(mash_row); check(hw_key_data[mash_col] === 1'b1, {label, ": mashed key released"});
            end

            set4(8'h00, 8'h00, 8'h00, 8'h00);
            repeat (300) @(posedge clk_sys);
            select_row(held_row);
            check(hw_key_data[held_col] === 1'b1, {label, ": held key releases cleanly at the end"});
        end
    endtask

    initial begin
        repeat (20) @(posedge clk_sys);
        reset = 0;
        repeat (20) @(posedge clk_sys);

        // hold O, mash Space (punch while moving)
        hold_and_mash(8'h12, 5, 1,  8'h2C, 7, 0, "hold-O_mash-Space");
        // hold P, mash Space
        hold_and_mash(8'h13, 5, 0,  8'h2C, 7, 0, "hold-P_mash-Space");
        // hold O, mash Q (jump while moving left)
        hold_and_mash(8'h12, 5, 1,  8'h14, 2, 0, "hold-O_mash-Q");
        // hold P, mash Q (jump while moving right)
        hold_and_mash(8'h13, 5, 0,  8'h14, 2, 0, "hold-P_mash-Q");
        // hold Q, mash Space (jump-punch)
        hold_and_mash(8'h14, 2, 0,  8'h2C, 7, 0, "hold-Q_mash-Space");
        // hold Space, mash O (weird order, but why not)
        hold_and_mash(8'h2C, 7, 0,  8'h12, 5, 1, "hold-Space_mash-O");
        // hold O, mash P (opposite directions rapidly)
        hold_and_mash(8'h12, 5, 1,  8'h13, 5, 0, "hold-O_mash-P");
        // hold A, mash Space (duck-punch)
        hold_and_mash(8'h04, 1, 0,  8'h2C, 7, 0, "hold-A_mash-Space");

        if (errors == 0) $display("\n==== ALL MASH CHECKS PASSED ====");
        else $display("\n==== %0d MASH CHECK(S) FAILED ====", errors);
        $finish;
    end

    initial begin
        #40000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
