`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// match_timer - 5-minute match countdown (PLACEHOLDER until Isaac's timer)
//
// Same ports as the original spec for Isaac's timer, so his module can replace
// this one without touching hud_render or capsule_ctrl:
//   time_penalty in (1-cycle: -10 s), game_seconds_left[8:0] out.
//
// Starts at MATCH_SEC on start, counts down one per second while the match runs
// (in_game and not paused), never goes below 0, pulses time_up once at 0.
// Both boards get start_game / game_paused / capsule events over the link, so
// both timers stay the same.
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
//////////////////////////////////////////////////////////////////////////////////
module match_timer
#(
    parameter integer SEC_CYCLES  = 6_250_000,   // clocks per second
    parameter integer MATCH_SEC   = 300,         // 5:00
    parameter integer PENALTY_SEC = 10     // rev 10: a capsule takes 10 s off
)
(
    input            clk,
    input            reset,
    input            start,                // 1-cycle: new match (start_game)
    input            in_game,
    input            game_paused,
    input            time_penalty,         // 1-cycle: take PENALTY_SEC off (capsule hit)
    output reg [8:0] game_seconds_left,    // 0..300
    output reg       time_up               // 1-cycle when it reaches 0
);
    reg [22:0] sub_cnt;                    // clocks within the current second
    wire running  = in_game && !game_paused && (game_seconds_left != 9'd0);
    wire sec_tick = running && (sub_cnt == SEC_CYCLES - 1);

    // value after this cycle's tick and penalty (both can happen together)
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
            // pulse once on the cycle it reaches 0 (only while a match runs)
            time_up <= in_game && (game_seconds_left != 9'd0) && (after_pen == 9'd0);
        end
    end
endmodule