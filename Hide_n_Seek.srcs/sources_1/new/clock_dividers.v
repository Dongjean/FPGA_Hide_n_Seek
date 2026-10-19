`timescale 1ns / 1ps
// All of the custom clocks are defined here

// 6.25MHz clock for Oled Display
module clk_6p25m (input clk, output slow_clk);

    // 100 MHz / 16 = 6.25 MHz
    // Bit 3 of clock_divider has one full period every 16 increments
    reg [3:0]clock_divider;
    always @ (posedge clk) begin
        clock_divider <= clock_divider + 4'd1;
    end
    
    assign slow_clk = clock_divider[3];
endmodule
