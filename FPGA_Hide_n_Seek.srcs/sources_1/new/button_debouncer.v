`timescale 1ns / 1ps

//Button debouncer
//Output only changes after the input has been steady for DEBOUNCE_MS.
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

    //Timing and registers
    localparam integer STABLE_CLKS = CLK_HZ / 1000 * DEBOUNCE_MS;
    localparam integer COUNT_W     = $clog2(STABLE_CLKS + 1);

    (* ASYNC_REG = "TRUE" *) reg raw_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg raw_sync = 1'b0;
    reg [COUNT_W-1:0]stable_count = 0;

    //Synchronise and debounce
    always @(posedge clk) begin
        raw_meta <= raw;
        raw_sync <= raw_meta;

        if (raw_sync == clean) begin
            stable_count <= 0;
        end else if (stable_count == STABLE_CLKS - 1) begin
            clean        <= raw_sync;
            stable_count <= 0;
        end else begin
            stable_count <= stable_count + 1'b1;
        end
    end
endmodule
