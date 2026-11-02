`timescale 1ns / 1ps
// Debounces one pushbutton or switch.
// The raw input is first synchronised (2 flip-flops), then the output only changes
// after the input has stayed at the new value for DEBOUNCE_MS without bouncing.

module button_debouncer
#(
    parameter integer CLK_HZ      = 6_250_000,
    parameter integer DEBOUNCE_MS = 10
)
(
    input clk,
    input raw,
    output reg clean = 1'b0
);
    localparam integer STABLE_CLKS = CLK_HZ / 1000 * DEBOUNCE_MS;
    localparam integer COUNT_W     = $clog2(STABLE_CLKS + 1);

    (* ASYNC_REG = "TRUE" *) reg raw_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg raw_sync = 1'b0;
    reg [COUNT_W-1:0]stable_count = 0;

    always @(posedge clk) begin
        raw_meta <= raw;
        raw_sync <= raw_meta;

        if (raw_sync == clean) begin
            stable_count <= 0;              // nothing to change
        end else if (stable_count == STABLE_CLKS - 1) begin
            clean        <= raw_sync;       // held long enough: accept it
            stable_count <= 0;
        end else begin
            stable_count <= stable_count + 1'b1;
        end
    end
endmodule
