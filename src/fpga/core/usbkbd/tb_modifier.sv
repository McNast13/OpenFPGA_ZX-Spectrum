`timescale 1ns/1ps
// Modifier-key testbench (Shift+letter, Ctrl+letter) - untested code path
// (hid2ps2_mod.sv + keyboard.sv's shift/ctrl combo logic), plausible real
// use case (e.g. Shift+direction for run/walk toggle in games).

module tb_modifier;

    reg clk_sys = 0;
    always #4.464 clk_sys = ~clk_sys;

    reg reset = 1;
    reg [31:0] cont3_key  = 0;
    reg [31:0] cont3_joy  = 0;
    reg [15:0] cont3_trig = 0;

    wire [10:0] ps2_key_usb;
    usb_keyboard usb_kbd (
        .clk(clk_sys), .clk_sync(clk_sys), .reset(reset),
        .cont3_key(cont3_key), .cont3_joy(cont3_joy), .cont3_trig(cont3_trig),
        .ps2_key(ps2_key_usb)
    );

    reg        ps2_toggle      = 0;
    reg  [9:0] ps2_key_latched = 0;
    always @(posedge clk_sys) begin
        if (ps2_key_usb[10] && (ps2_key_usb[9:0] != ps2_key_latched)) begin
            ps2_toggle      <= ~ps2_toggle;
            ps2_key_latched <= ps2_key_usb[9:0];
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

    // mods: bit0=LCtrl bit1=LShift bit4=RCtrl bit5=RShift; sc1: scancode slot 1
    task set_mod_key(input [7:0] mods, input [7:0] sc1);
        begin
            cont3_key = {4'h4, 12'h0, mods, 8'h00}; // type[31:28], mods at [15:8]
            cont3_joy = {sc1, 8'h00, 8'h00, 8'h00};
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

    initial begin
        repeat (20) @(posedge clk_sys);
        reset = 0;
        repeat (20) @(posedge clk_sys);

        // CAPS SHIFT bit is keys[0][0], row0 col0
        select_row(0);
        check(hw_key_data[0] === 1'b1, "idle: CAPS SHIFT released");

        // Press left shift alone
        set_mod_key(8'h02, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(0);
        check(hw_key_data[0] === 1'b0, "shift alone: CAPS SHIFT pressed");

        // Hold shift, also press 'a' (row1 col0) - shift+a combo
        set_mod_key(8'h02, 8'h04);
        repeat (600) @(posedge clk_sys);
        select_row(0); check(hw_key_data[0] === 1'b0, "shift+a: CAPS SHIFT still pressed");
        select_row(1); check(hw_key_data[0] === 1'b0, "shift+a: 'a' pressed");

        // hold for a while
        repeat (20000) @(posedge clk_sys);
        select_row(0); check(hw_key_data[0] === 1'b0, "shift+a hold: CAPS SHIFT still pressed");
        select_row(1); check(hw_key_data[0] === 1'b0, "shift+a hold: 'a' still pressed");

        // Release 'a' only, keep shift held (like releasing a direction but holding run)
        set_mod_key(8'h02, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(1); check(hw_key_data[0] === 1'b1, "release a, keep shift: 'a' released");
        select_row(0); check(hw_key_data[0] === 1'b0, "release a, keep shift: CAPS SHIFT still pressed");

        // Now release shift too
        set_mod_key(8'h00, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(0); check(hw_key_data[0] === 1'b1, "release shift: CAPS SHIFT released");

        // Press 'a' then shift (reverse order), hold both, release shift first this time
        set_mod_key(8'h00, 8'h04);
        repeat (600) @(posedge clk_sys);
        select_row(1); check(hw_key_data[0] === 1'b0, "a then shift: 'a' pressed");
        set_mod_key(8'h02, 8'h04);
        repeat (600) @(posedge clk_sys);
        select_row(0); check(hw_key_data[0] === 1'b0, "a then shift: CAPS SHIFT pressed");
        select_row(1); check(hw_key_data[0] === 1'b0, "a then shift: 'a' still pressed");

        set_mod_key(8'h00, 8'h04); // release shift, keep a
        repeat (600) @(posedge clk_sys);
        select_row(0); check(hw_key_data[0] === 1'b1, "release shift keep a: CAPS SHIFT released");
        select_row(1); check(hw_key_data[0] === 1'b0, "release shift keep a: 'a' still pressed");

        set_mod_key(8'h00, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(1); check(hw_key_data[0] === 1'b1, "final release: 'a' released");

        if (errors == 0) $display("\n==== ALL MODIFIER CHECKS PASSED ====");
        else $display("\n==== %0d MODIFIER CHECK(S) FAILED ====", errors);
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
