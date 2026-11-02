`timescale 1ns / 1ps
// UART transmitter, 8N1 (1 start bit, 8 data bits LSB first, no parity, 1 stop bit).
// The line idles high. Pulse start for one clock while busy is low to send data_in.

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
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;

    reg [15:0]clk_count = 16'd0;
    reg [3:0]bit_index = 4'd0;   // 0 = start bit, 1 to 8 = data bits, 9 = stop bit
    reg [9:0]frame;              // {stop, data[7:0], start}, sent from bit 0 upwards
    reg sending = 1'b0;

    assign busy = sending;

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
                tx        <= 1'b0;   // start bit
            end
        end else begin
            if (clk_count == CLKS_PER_BIT - 1) begin
                clk_count <= 16'd0;
                if (bit_index == 4'd9) begin
                    sending <= 1'b0;   // stop bit finished
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
