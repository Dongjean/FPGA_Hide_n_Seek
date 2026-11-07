`timescale 1ns / 1ps

//Seven-segment display
//Shows a 16-bit value as 4 hex digits, lighting one digit at a time.
module seven_segment_display
#(
    parameter integer CLK_HZ = 100_000_000
)
(
    input clk,
    input [15:0]value,
    output reg [6:0]seg = 7'h7F,
    output dp,
    output reg [3:0]an = 4'hF
);

    //Timing and registers
    localparam integer REFRESH_CLKS = CLK_HZ / 4000;

    reg [31:0]refresh_count = 32'd0;
    reg [1:0]digit = 2'd0;
    reg [3:0]nibble;

    assign dp = 1'b1;

    //Digit select
    //Picks the 4 bits of value for the digit being lit.
    always @(*) begin
        case (digit)
            2'd0: nibble = value[3:0];
            2'd1: nibble = value[7:4];
            2'd2: nibble = value[11:8];
            default: nibble = value[15:12];
        endcase
    end

    //Digit refresh and segment patterns
    always @(posedge clk) begin
        if (refresh_count == REFRESH_CLKS - 1) begin
            refresh_count <= 32'd0;
            digit <= digit + 2'd1;
        end else begin
            refresh_count <= refresh_count + 32'd1;
        end

        an <= ~(4'b0001 << digit);
        case (nibble)
            4'h0: seg <= 7'b1000000;
            4'h1: seg <= 7'b1111001;
            4'h2: seg <= 7'b0100100;
            4'h3: seg <= 7'b0110000;
            4'h4: seg <= 7'b0011001;
            4'h5: seg <= 7'b0010010;
            4'h6: seg <= 7'b0000010;
            4'h7: seg <= 7'b1111000;
            4'h8: seg <= 7'b0000000;
            4'h9: seg <= 7'b0010000;
            4'hA: seg <= 7'b0001000;
            4'hB: seg <= 7'b0000011;
            4'hC: seg <= 7'b1000110;
            4'hD: seg <= 7'b0100001;
            4'hE: seg <= 7'b0000110;
            default: seg <= 7'b0001110;
        endcase
    end
endmodule
