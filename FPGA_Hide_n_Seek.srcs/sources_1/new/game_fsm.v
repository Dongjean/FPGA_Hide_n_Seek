`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02.11.2026 17:12:23
// Design Name: 
// Module Name: game_fsm
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module game_fsm
(
    input  clk,
    input  reset, // Forces MENU
    input  frame_begin,
    input  btn_confirm,
    output reg [1:0] state = 2'd0
);
    localparam [1:0] S_MENU    = 2'd0;
    localparam [1:0] S_PLAYING = 2'd1;
    localparam [1:0] S_END     = 2'd2;

    reg btn_prev = 1'b0;
    wire confirm_pulse = btn_confirm && !btn_prev;

    always @(posedge clk) begin
        if (reset) begin
            state    <= S_MENU;
            btn_prev <= 1'b0;
        end else if (frame_begin) begin
            btn_prev <= btn_confirm;
            case (state)
                S_MENU:    if (confirm_pulse) state <= S_PLAYING;
                S_PLAYING: if (confirm_pulse) state <= S_END;
                S_END:     if (confirm_pulse) state <= S_MENU;
                default:                      state <= S_MENU;
            endcase
        end
    end
endmodule
