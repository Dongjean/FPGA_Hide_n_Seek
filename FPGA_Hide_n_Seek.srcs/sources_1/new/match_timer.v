`timescale 1ns / 1ps

//match_timer - 5 min match countdown on oled2

module match_timer
#(
    parameter integer SEC_CYCLES  = 6_250_000,   //clocks per sec
    parameter integer MATCH_SEC   = 300,         //5:00
    parameter integer PENALTY_SEC = 10           //, capsule takes 10s off
)
(
    input            clk,
    input            reset,
    input            start,               
    input            in_game,
    input            game_paused,
    input            time_penalty,         
    output reg [8:0] game_seconds_left,    
    output reg       time_up              
);
    reg [22:0] sub_cnt;  
    wire running  = in_game && !game_paused && (game_seconds_left != 9'd0);
    wire sec_tick = running && (sub_cnt == SEC_CYCLES - 1);

    //value after this cycle's tick and penalty (can both happen at once)
    wire [8:0] after_tick = (sec_tick && game_seconds_left != 9'd0) ? game_seconds_left - 9'd1
                                                                    : game_seconds_left;
    wire [8:0] after_pen  = !time_penalty               ? after_tick :
                            (after_tick > PENALTY_SEC)  ? after_tick - PENALTY_SEC : 9'd0;

    always @(posedge clk) begin
        if (reset) begin
            sub_cnt           <= 23'd0;
            game_seconds_left <= MATCH_SEC;
            time_up           <= 1'b0;
        end else if (start) begin
            sub_cnt           <= 23'd0;
            game_seconds_left <= MATCH_SEC;
            time_up           <= 1'b0;
        end else begin
            if (running) sub_cnt <= sec_tick ? 23'd0 : sub_cnt + 23'd1;
            game_seconds_left <= after_pen;
            //pulse once when it hits 0 (only during a match)
            time_up <= in_game && (game_seconds_left != 9'd0) && (after_pen == 9'd0);
        end
    end
endmodule