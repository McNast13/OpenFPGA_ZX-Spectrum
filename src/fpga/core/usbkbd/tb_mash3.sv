`timescale 1ns/1ps
// Three-key stress test: hold two keys (e.g. move + jump) simultaneously,
// then mash a third (punch) repeatedly, checking all three track correctly
// - beat-em-ups routinely need move+jump+attack all at once.

module tb_mash3;

    reg clk_sys = 0;
    always #4.464 clk_sys = ~clk_sys; // 8.928ns period, matches clk_sys

    reg clk_74a = 0;
    always #6.734 clk_74a = ~clk_74a; // 13.468ns period, matches clk_74a

    reg reset = 1;
    reg [31:0] cont3_key  = 0;
    reg [31:0] cont3_joy  = 0;
    reg [15:0] cont3_trig = 0;

    wire [31:0] cont3_key_s;
    wire [31:0] cont3_joy_s;
    wire [15:0] cont3_trig_s;
    synch_3 #(.WIDTH(32)) cont3_key_sync  (cont3_key,  cont3_key_s,  clk_74a);
    synch_3 #(.WIDTH(32)) cont3_joy_sync  (cont3_joy,  cont3_joy_s,  clk_74a);
    synch_3 #(.WIDTH(16)) cont3_trig_sync (cont3_trig, cont3_trig_s, clk_74a);

    wire [10:0] ps2_key_usb;
    wire  [7:0] usb_kb_mod, usb_kb_sc1, usb_kb_sc2, usb_kb_sc3, usb_kb_sc4, usb_kb_sc5, usb_kb_sc6;
    wire [63:0] usb_kb_hid;
    usb_keyboard usb_kbd (
        .clk(clk_74a), .clk_sync(clk_74a), .reset(reset),
        .cont3_key(cont3_key_s), .cont3_joy(cont3_joy_s), .cont3_trig(cont3_trig_s),
        .usb_kb_hid(usb_kb_hid), .usb_kb_mod(usb_kb_mod),
        .usb_kb_sc1(usb_kb_sc1), .usb_kb_sc2(usb_kb_sc2), .usb_kb_sc3(usb_kb_sc3),
        .usb_kb_sc4(usb_kb_sc4), .usb_kb_sc5(usb_kb_sc5), .usb_kb_sc6(usb_kb_sc6),
        .ps2_key(ps2_key_usb)
    );

    logic [71:0] live_mods;
    logic  [8:0] live_sc1, live_sc2, live_sc3, live_sc4, live_sc5, live_sc6;
    hid2ps2_mod u_live_mod (.clk(clk_74a), .usb(usb_kb_mod), .ps2(live_mods));
    hid2ps2_key u_live_sc1 (.clk(clk_74a), .usb(usb_kb_sc1), .ps2(live_sc1));
    hid2ps2_key u_live_sc2 (.clk(clk_74a), .usb(usb_kb_sc2), .ps2(live_sc2));
    hid2ps2_key u_live_sc3 (.clk(clk_74a), .usb(usb_kb_sc3), .ps2(live_sc3));
    hid2ps2_key u_live_sc4 (.clk(clk_74a), .usb(usb_kb_sc4), .ps2(live_sc4));
    hid2ps2_key u_live_sc5 (.clk(clk_74a), .usb(usb_kb_sc5), .ps2(live_sc5));
    hid2ps2_key u_live_sc6 (.clk(clk_74a), .usb(usb_kb_sc6), .ps2(live_sc6));

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

    reg  [9:0] ps2_key_usb_prev_74a = 0;
    reg        ps2_toggle_74a       = 0;
    reg  [9:0] ps2_key_latched_74a  = 0;
    reg  [9:0] ps2_q0 = 0, ps2_q1 = 0;
    reg  [1:0] ps2_qcount   = 0;
    reg        ps2_draining = 0;

    wire ps2_ack_74a; // declared here for Icarus; driven further down by ps2_ack_cdc

    wire ps2_new_event = ps2_key_usb[10] && (ps2_key_usb[9:0] != ps2_key_usb_prev_74a) &&
                         (ps2_key_usb[9] || !code_is_live(ps2_key_usb[8:0]));
    wire ps2_ready      = (ps2_ack_74a == ps2_toggle_74a);
    wire ps2_do_dequeue = !ps2_draining && ps2_ready && (ps2_qcount != 0);

    always @(posedge clk_74a) begin
        ps2_key_usb_prev_74a <= ps2_key_usb[9:0];

        if (ps2_draining) begin
            ps2_toggle_74a <= ~ps2_toggle_74a;
            ps2_draining   <= 1'b0;
        end else if (ps2_do_dequeue) begin
            ps2_key_latched_74a <= ps2_q0;
            ps2_draining        <= 1'b1;
        end

        case ({ps2_do_dequeue, ps2_new_event})
            2'b01: begin
                if (ps2_qcount == 0) ps2_q0 <= ps2_key_usb[9:0];
                else                 ps2_q1 <= ps2_key_usb[9:0];
                ps2_qcount <= ps2_qcount + 2'd1;
            end
            2'b10: begin
                ps2_q0     <= ps2_q1;
                ps2_qcount <= ps2_qcount - 2'd1;
            end
            2'b11: begin
                if (ps2_qcount == 1) begin
                    ps2_q0 <= ps2_key_usb[9:0];
                end else begin
                    ps2_q0 <= ps2_q1;
                    ps2_q1 <= ps2_key_usb[9:0];
                end
            end
            default: ;
        endcase
    end

    wire ps2_toggle_sync, ps2_toggle_rise, ps2_toggle_fall;
    synch_3 #(.WIDTH(1)) ps2_toggle_cdc (ps2_toggle_74a, ps2_toggle_sync, clk_sys, ps2_toggle_rise, ps2_toggle_fall);

    synch_3 #(.WIDTH(1)) ps2_ack_cdc (ps2_toggle_sync, ps2_ack_74a, clk_74a);

    reg        ps2_toggle      = 0;
    reg  [9:0] ps2_key_latched = 0;
    always @(posedge clk_sys) begin
        if (ps2_toggle_rise || ps2_toggle_fall) begin
            ps2_toggle      <= ~ps2_toggle;
            ps2_key_latched <= ps2_key_latched_74a;
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

    // O=USB0x12/row5col1  Q=USB0x14/row2col0  SPACE=USB0x2C/row7col0
    integer i;
    initial begin
        repeat (20) @(posedge clk_sys);
        reset = 0;
        repeat (20) @(posedge clk_sys);

        // Hold O (move) then add Q (jump) - both held, like jumping while moving
        set4(8'h12, 8'h00, 8'h00, 8'h00);
        repeat (300) @(posedge clk_sys);
        set4(8'h12, 8'h14, 8'h00, 8'h00);
        repeat (300) @(posedge clk_sys);
        select_row(5); check(hw_key_data[1] === 1'b0, "O+Q: O pressed");
        select_row(2); check(hw_key_data[0] === 1'b0, "O+Q: Q pressed");

        // Now mash Space (punch) repeatedly while O+Q both stay held (3rd slot)
        for (i = 0; i < 15; i = i + 1) begin
            set4(8'h12, 8'h14, 8'h2C, 8'h00);
            repeat (250) @(posedge clk_sys);
            select_row(5); check(hw_key_data[1] === 1'b0, "O+Q+mash: O still pressed (down)");
            select_row(2); check(hw_key_data[0] === 1'b0, "O+Q+mash: Q still pressed (down)");
            select_row(7); check(hw_key_data[0] === 1'b0, "O+Q+mash: Space pressed");
            set4(8'h12, 8'h14, 8'h00, 8'h00);
            repeat (250) @(posedge clk_sys);
            select_row(5); check(hw_key_data[1] === 1'b0, "O+Q+mash: O still pressed (up)");
            select_row(2); check(hw_key_data[0] === 1'b0, "O+Q+mash: Q still pressed (up)");
            select_row(7); check(hw_key_data[0] === 1'b1, "O+Q+mash: Space released");
        end

        // Release Q only (stop jumping, keep moving + still able to punch)
        set4(8'h12, 8'h00, 8'h00, 8'h00);
        repeat (300) @(posedge clk_sys);
        select_row(2); check(hw_key_data[0] === 1'b1, "release Q: Q released");
        select_row(5); check(hw_key_data[1] === 1'b0, "release Q: O still pressed");

        // Punch again after releasing Q - must still work
        set4(8'h12, 8'h2C, 8'h00, 8'h00);
        repeat (300) @(posedge clk_sys);
        select_row(7); check(hw_key_data[0] === 1'b0, "post-release: Space pressed");
        select_row(5); check(hw_key_data[1] === 1'b0, "post-release: O still pressed");
        set4(8'h12, 8'h00, 8'h00, 8'h00);
        repeat (300) @(posedge clk_sys);
        select_row(7); check(hw_key_data[0] === 1'b1, "post-release: Space released cleanly");

        // Release everything
        set4(8'h00, 8'h00, 8'h00, 8'h00);
        repeat (300) @(posedge clk_sys);
        select_row(5); check(hw_key_data[1] === 1'b1, "final: O released");
        select_row(2); check(hw_key_data[0] === 1'b1, "final: Q released");
        select_row(7); check(hw_key_data[0] === 1'b1, "final: Space released");

        if (errors == 0) $display("\n==== ALL 3-KEY MASH CHECKS PASSED ====");
        else $display("\n==== %0d 3-KEY MASH CHECK(S) FAILED ====", errors);
        $finish;
    end

    initial begin
        #40000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
