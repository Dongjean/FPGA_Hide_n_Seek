`timescale 1ns / 1ps

//UART transmitter
//Sends one byte as 8N1: start bit, 8 data bits (LSB first), stop bit.
module uart_transmitter
#(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
)
(
    input clk,
    input reset,
    input start,
    input [7:0]data_in,

    output reg tx = 1'b1,
    output busy
);

    //Timing and registers
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;

    reg [15:0]clk_count = 16'd0;
    reg [3:0]bit_index = 4'd0;
    reg [9:0]frame;
    reg sending = 1'b0;

    assign busy = sending;

    //Send FSM
    //Idle until start, then shifts out the 10-bit frame, one bit every CLKS_PER_BIT clocks.
    always @(posedge clk) begin
        if (reset) begin
            sending   <= 1'b0;
            tx        <= 1'b1;
            clk_count <= 16'd0;
            bit_index <= 4'd0;
        end else if (!sending) begin
            tx <= 1'b1;
            if (start) begin
                frame     <= {1'b1, data_in, 1'b0};
                sending   <= 1'b1;
                clk_count <= 16'd0;
                bit_index <= 4'd0;
                tx        <= 1'b0;
            end
        end else begin
            if (clk_count == CLKS_PER_BIT - 1) begin
                clk_count <= 16'd0;
                if (bit_index == 4'd9) begin
                    sending <= 1'b0;
                    tx      <= 1'b1;
                end else begin
                    bit_index <= bit_index + 4'd1;
                    tx        <= frame[bit_index + 4'd1];
                end
            end else begin
                clk_count <= clk_count + 16'd1;
            end
        end
    end
endmodule
