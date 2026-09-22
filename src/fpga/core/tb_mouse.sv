`timescale 1ns/1ps
// Standalone Icarus Verilog testbench for mouse.v's accumulate-and-
// saturate Kempston Mouse logic, driven directly with HID-shaped inputs
// exactly as core_top.sv wires it (no PS/2 packet format anywhere).
//
// mouse.v itself needs no Icarus-only patching (unlike the old PS/2
// keyboard bridge) - the only reason THIS testbench can't just
// `iverilog tb_mouse.sv mouse.v` as-is is that mouse.v's dout/sel
// `assign` statements are declared before the `data`/`port_sel` regs
// they reference (matching upstream's original file layout, which
// Quartus accepts but Icarus doesn't - see usbkbd/README.md for the
// general pattern). Make an Icarus-only copy with those two reg
// declarations moved above the assigns, then:
//
//   iverilog -g2012 -o tb.vvp tb_mouse.sv mouse.v
//   vvp tb.vvp

module tb_mouse;

    reg clk_sys = 0;
    always #4.464 clk_sys = ~clk_sys;

    reg reset = 1;
    reg [15:0] hid_counter = 0;
    reg signed [15:0] hid_dx = 0;
    reg signed [15:0] hid_dy = 0;
    reg [2:0] hid_buttons = 0;
    reg btn_swap = 0;
    reg [2:0] addr = 0;
    wire sel;
    wire [7:0] dout;

    mouse u (
        .clk_sys(clk_sys), .reset(reset),
        .hid_counter(hid_counter), .hid_dx(hid_dx), .hid_dy(hid_dy),
        .hid_buttons(hid_buttons), .btn_swap(btn_swap),
        .addr(addr), .sel(sel), .dout(dout)
    );

    integer errors = 0;
    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin $display("FAIL: %0s", msg); errors = errors + 1; end
        end
    endtask

    task read_x(output [7:0] v);
        begin addr = 3'b011; #1; v = dout; end
    endtask
    task read_y(output [7:0] v);
        begin addr = 3'b111; #1; v = dout; end
    endtask
    task read_btn(output [7:0] v);
        begin addr = 3'b010; #1; v = dout; end
    endtask

    task send_report(input signed [15:0] dx, input signed [15:0] dy, input [2:0] btns);
        begin
            hid_dx = dx; hid_dy = dy; hid_buttons = btns;
            hid_counter = hid_counter + 1;
            repeat (5) @(posedge clk_sys);
        end
    endtask

    reg [7:0] v;
    initial begin
        repeat (10) @(posedge clk_sys);
        reset = 0;
        repeat (10) @(posedge clk_sys);

        // reset defaults: dx=128, dy=0 (dx != dy is deliberate - see
        // mouse.v - some software uses this asymmetry to detect a
        // genuine Kempston mouse is present)
        read_x(v); check(v === 8'd128, "reset: dx == 128");
        read_y(v); check(v === 8'd0, "reset: dy == 0");
        read_btn(v); check(v === 8'hFF, "reset: no buttons pressed (active-low, all released)");

        // --- basic positive movement ---
        send_report(16'sd10, 16'sd5, 3'b000);
        read_x(v); check(v === 8'd138, "move +10,+5: dx == 138");
        read_y(v); check(v === 8'd5, "move +10,+5: dy == 5");

        // --- negative movement ---
        send_report(-16'sd20, -16'sd3, 3'b000);
        read_x(v); check(v === 8'd118, "move -20,-3: dx == 118 (138-20)");
        read_y(v); check(v === 8'd2, "move -20,-3: dy == 2 (5-3)");

        // --- left button ---
        send_report(16'sd0, 16'sd0, 3'b001);
        read_btn(v); check(v === 8'hFE, "left button: bit0 low, rest high");

        // --- right button ---
        send_report(16'sd0, 16'sd0, 3'b010);
        read_btn(v); check(v === 8'hFD, "right button: bit1 low, rest high");

        // --- middle button ---
        send_report(16'sd0, 16'sd0, 3'b100);
        read_btn(v); check(v === 8'hFB, "middle button: bit2 low, rest high");

        // --- button swap ---
        btn_swap = 1;
        send_report(16'sd0, 16'sd0, 3'b001); // left physically pressed
        read_btn(v); check(v === 8'hFD, "swap on: physical left now reads as bit1 (right)");
        btn_swap = 0;

        // --- report counter must NOT retrigger without a change ---
        read_x(v); // no send_report call, no counter bump
        repeat (5) @(posedge clk_sys);
        read_x(v); check(v === 8'd118, "no new report: dx unchanged");

        // --- large positive delta saturates dx to 0xFF (upper byte clamp) ---
        reset = 1; repeat(4) @(posedge clk_sys); reset = 0; repeat(4) @(posedge clk_sys);
        send_report(16'sd20000, 16'sd0, 3'b000);
        read_x(v); check(v === 8'hFF, "huge positive delta: dx saturates to 0xFF");

        // --- large negative delta saturates dx to 0x00 ---
        reset = 1; repeat(4) @(posedge clk_sys); reset = 0; repeat(4) @(posedge clk_sys);
        send_report(-16'sd20000, 16'sd0, 3'b000);
        read_x(v); check(v === 8'h00, "huge negative delta: dx saturates to 0x00");

        // --- port_sel behaves correctly for non-mouse addresses ---
        addr = 3'b000; #1;
        check(sel === 1'b0, "unmatched addr: sel deasserted");

        if (errors == 0) $display("\n==== ALL MOUSE CHECKS PASSED ====");
        else $display("\n==== %0d MOUSE CHECK(S) FAILED ====", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
