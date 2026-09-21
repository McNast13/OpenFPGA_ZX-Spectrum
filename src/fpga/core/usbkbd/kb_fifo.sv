//------------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2023, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Analogue Pocket USB HID Keyboard/Mouse and PS/2 Scan Code Translation
//
// Copyright (c) 2023, Marcus Andrade <marcus@opengateware.org>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
//------------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module kb_fifo
    (
        // Global
        input  logic         clk,   //! Clock
        input  logic         reset, //! Reset
        // Enqueue side
        input  logic [125:0] din,   //! Data Input
        // Dequeue side
        input  logic         rd_en, //! Read Enable
        output logic         empty, //! FIFO Empty State
        output logic [125:0] dout   //! Data Output
    );

    parameter INIT_REPEAT_DELAY = 4'hF; // Initial delay before repeating
    parameter REPEAT_RATE       = 4'h4; // Repeat rate

    //! ------------------------------------------------------------------------
    //! Internal Registers
    //! ------------------------------------------------------------------------
    logic [125:0] fifo[6:0];                   // FIFO buffer
    logic [125:0] prev_din;                    // Previous FIFO Data
    logic   [2:0] wr_ptr              = 3'h0;  // Write pointer
    logic   [2:0] rd_ptr              = 3'h0;  // Read pointer
    logic   [2:0] counter             = 3'h0;  // Count of elements in FIFO
    logic         wr_en               = 1'b0;  // Write Enable
    logic         full;                        // FIFO is Full
    logic   [3:0] delay_counter       = 4'h0;  // Delay before key starts to repeat
    logic   [3:0] repeat_counter      = 4'h0;  // Counter for key repeat rate
    logic         repeat_request      = 1'b0;  // Write Enable
    logic         prev_repeat_request = 1'b0;  // Previous state of repeat_request

    //! ------------------------------------------------------------------------
    //! FIFO State
    //! ------------------------------------------------------------------------
    assign empty = (counter == 0) ? 1'b1 : 1'b0;
    assign full  = (counter == 7) ? 1'b1 : 1'b0;

    //! ------------------------------------------------------------------------
    //! Key Repeat Controller
    //!
    //! MODIFIED from upstream: disabled. This module runs at the host
    //! core's full clk_sys (100MHz+ here), so INIT_REPEAT_DELAY/REPEAT_RATE
    //! (tens of cycles) fire far faster than the downstream 14-slot key
    //! scanner can drain each FIFO entry (~70 cycles). During any sustained
    //! key hold this filled the 7-deep FIFO and kept it full; the buffer
    //! controller below silently drops writes while full
    //! (`if (wr_en && !full)`), so a real key-release landing while full
    //! was lost entirely, leaving the key stuck until an unrelated future
    //! keypress happened to reveal the true state. Real press/release
    //! events don't depend on this block - they write on genuine din
    //! changes below - so disabling it only removes synthetic
    //! typematic-repeat writes, not correctness for hold/release.
    //! ------------------------------------------------------------------------
    always_ff @(posedge clk) begin : fifoKeyRepeat
        delay_counter  <= 4'h0;
        repeat_counter <= 4'h0;
        repeat_request <= 1'b0;
    end

    //! ------------------------------------------------------------------------
    //! FIFO Write Controller
    //! ------------------------------------------------------------------------
    always_ff @(posedge clk) begin : fifoWriteControl
        prev_din <= din;
        prev_repeat_request <= repeat_request;
        if ((din != prev_din) || (repeat_request && !prev_repeat_request)) begin
            wr_en <= 1'b1;
        end
        else begin
            wr_en <= 1'b0;
        end
    end

    //! ------------------------------------------------------------------------
    //! FIFO Buffer Controller
    //! ------------------------------------------------------------------------
    always_ff @(posedge clk) begin : fifoControl
        if (reset) begin
            wr_ptr  <= 0;
            rd_ptr  <= 0;
            counter <= 0;
        end
        else begin
            if (wr_en && !full) begin
                fifo[wr_ptr] <= din;
                wr_ptr       <= (wr_ptr + 1) % 7;
                counter      <= counter + 1;
            end

            if (rd_en && !empty) begin
                dout    <= fifo[rd_ptr];
                rd_ptr  <= (rd_ptr + 1) % 7;
                counter <= counter - 1;
            end
        end
    end

endmodule
