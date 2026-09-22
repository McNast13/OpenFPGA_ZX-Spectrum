`timescale 1ns/1ps
// Validates the compaction-bug fix: a "live snapshot" of currently-held
// PS2 codes (independent re-translation of the raw HID report, bypassing
// the slot-tracking FIFO/arbiter/key_mgr chain) used to suppress a stale
// release for a code that's still actually present in the HID report.
module tb_compaction_fix;

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

    // ---- live snapshot: independent re-translation, no slot tracking ----
    logic [71:0] live_mods;
    logic  [8:0] live_sc1, live_sc2, live_sc3, live_sc4, live_sc5, live_sc6;
    hid2ps2_mod u_live_mod (.clk(clk_sys), .usb(usb_kb_mod), .ps2(live_mods));
    hid2ps2_key u_live_sc1 (.clk(clk_sys), .usb(usb_kb_sc1), .ps2(live_sc1));
    hid2ps2_key u_live_sc2 (.clk(clk_sys), .usb(usb_kb_sc2), .ps2(live_sc2));
    hid2ps2_key u_live_sc3 (.clk(clk_sys), .usb(usb_kb_sc3), .ps2(live_sc3));
    hid2ps2_key u_live_sc4 (.clk(clk_sys), .usb(usb_kb_sc4), .ps2(live_sc4));
    hid2ps2_key u_live_sc5 (.clk(clk_sys), .usb(usb_kb_sc5), .ps2(live_sc5));
    hid2ps2_key u_live_sc6 (.clk(clk_sys), .usb(usb_kb_sc6), .ps2(live_sc6));

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

    // ps2_key_usb_seen tracks the last distinct SOURCE content evaluated
    // (updates on every new event, forwarded or not); ps2_toggle/
    // ps2_key_latched are the OUTPUT and only change when an event passes
    // the suppression check. Comparing the "new event?" check against the
    // OUTPUT latch instead (an earlier version of this fix did) leaves it
    // holding stale content after a suppressed release - if a LATER
    // genuine event's content ever coincidentally matches that stale
    // value, it gets silently dropped too, regardless of its own code.
    reg [10:0] ps2_key_usb_r = 0; // matches core_top.sv's extra pipeline stage
    always @(posedge clk_sys) ps2_key_usb_r <= ps2_key_usb;

    reg  [9:0] ps2_key_usb_prev = 0; // raw source value, ALWAYS updates - never gated
    reg        ps2_toggle       = 0;
    reg  [9:0] ps2_key_latched  = 0;
    always @(posedge clk_sys) begin
        ps2_key_usb_prev <= ps2_key_usb_r[9:0];
        if (ps2_key_usb_r[10] && (ps2_key_usb_r[9:0] != ps2_key_usb_prev)) begin
            // Suppress a stale release: if this is a release (pressed=0)
            // and the code is still present somewhere in the live,
            // slot-independent snapshot, the key hasn't really gone away
            // - it just moved HID slots. Presses always pass through.
            if (ps2_key_usb_r[9] || !code_is_live(ps2_key_usb_r[8:0])) begin
                ps2_toggle      <= ~ps2_toggle;
                ps2_key_latched <= ps2_key_usb_r[9:0];
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

    task set_keys(input [7:0] sc1, input [7:0] sc2);
        begin
            cont3_key = {4'h4, 28'h0};
            cont3_joy = {sc1, sc2, 8'h00, 8'h00};
        end
    endtask

    task set_keys3(input [7:0] sc1, input [7:0] sc2, input [7:0] sc3);
        begin
            cont3_key = {4'h4, 28'h0};
            cont3_joy = {sc1, sc2, sc3, 8'h00};
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

        // THE bug scenario: hold O (left, slot1), press P (right, slot2)
        // while O still held (direction-change overlap), then release O
        // only - P should stay pressed.
        set_keys(8'h12, 8'h00); // O alone (left) - hold
        repeat (600) @(posedge clk_sys);
        select_row(5);
        check(hw_key_data[1] === 1'b0, "hold O: O pressed");

        set_keys(8'h12, 8'h13); // O still held, P (right) newly pressed
        repeat (600) @(posedge clk_sys);
        select_row(5);
        check(hw_key_data[1] === 1'b0, "O+P: O still pressed");
        check(hw_key_data[0] === 1'b0, "O+P: P pressed");

        repeat (20000) @(posedge clk_sys); // hold both for a while

        // Release O only (finishing the direction change) - P must stay held
        set_keys(8'h13, 8'h00); // compaction: P moves into slot1
        repeat (600) @(posedge clk_sys);
        select_row(5);
        check(hw_key_data[1] === 1'b1, "release O: O released");
        check(hw_key_data[0] === 1'b0, "release O: P STILL pressed (the bug)");

        repeat (20000) @(posedge clk_sys); // hold P alone for a while
        select_row(5);
        check(hw_key_data[0] === 1'b0, "hold P after compaction: still pressed");

        // finally release P too
        set_keys(8'h00, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(5);
        check(hw_key_data[0] === 1'b1, "release P: P released");
        check(hw_key_data[1] === 1'b1, "release P: O still released");

        // Sanity: genuine release (not a compaction artifact) must still work
        set_keys(8'h13, 8'h00); // P alone
        repeat (600) @(posedge clk_sys);
        select_row(5); check(hw_key_data[0] === 1'b0, "sanity: P pressed");
        set_keys(8'h00, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(5); check(hw_key_data[0] === 1'b1, "sanity: genuine release still works");

        // Regression check for the cascading-stuck bug: after a suppressed
        // (compaction) release, unrelated keys pressed afterward - and the
        // SAME key pressed again later - must not be silently dropped just
        // because their content happens to coincide with whatever was
        // last evaluated. Real hardware report this reproduces: "long
        // press right then a jump, long press left, then all key presses
        // are sticky".
        select_row(4); // row4: Up=col3, Down=col4 (used as stand-ins for jump/other actions)
        set_keys(8'h12, 8'h00); // hold O (left)
        repeat (600) @(posedge clk_sys);
        set_keys(8'h12, 8'h13); // O still held, P (right) newly pressed
        repeat (600) @(posedge clk_sys);
        set_keys(8'h13, 8'h00); // release O only -> compaction, suppresses O's stale-adjacent event
        repeat (600) @(posedge clk_sys);

        // "jump" (an unrelated key, e.g. M) pressed and released right after,
        // in a THIRD scancode slot - P must stay in its own slot throughout
        set_keys3(8'h13, 8'h00, 8'h10); // P still in sc1, M (jump) newly in sc3
        repeat (600) @(posedge clk_sys);
        select_row(7); check(hw_key_data[2] === 1'b0, "post-suppression: unrelated key (jump) pressed");
        set_keys(8'h13, 8'h00); // release jump only, P stays in sc1
        repeat (600) @(posedge clk_sys);
        select_row(7); check(hw_key_data[2] === 1'b1, "post-suppression: unrelated key (jump) released cleanly");

        // release P (right) - must still work, not stuck from the earlier suppression
        select_row(5); check(hw_key_data[0] === 1'b0, "post-suppression: P still correctly held");
        set_keys(8'h00, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(5); check(hw_key_data[0] === 1'b1, "post-suppression: P releases cleanly");

        // press O (left) again - must not be stuck from its earlier suppressed event
        set_keys(8'h12, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(5); check(hw_key_data[1] === 1'b0, "post-suppression: O presses again cleanly");
        set_keys(8'h00, 8'h00);
        repeat (600) @(posedge clk_sys);
        select_row(5); check(hw_key_data[1] === 1'b1, "post-suppression: O releases again cleanly");

        if (errors == 0) $display("\n==== ALL COMPACTION-FIX CHECKS PASSED ====");
        else $display("\n==== %0d COMPACTION-FIX CHECK(S) FAILED ====", errors);
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
