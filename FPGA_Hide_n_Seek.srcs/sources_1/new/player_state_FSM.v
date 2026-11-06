`timescale 1ns / 1ps

// FSM for dealing with player states
// States:
// 0 == Normal, can do any action
// 1 == Stunned, cannot move or turn
// 2 == Flashbang, cannot see
// 3 == Attacked, reduce health and red screen filter
module player_state_FSM
#(
    parameter integer CLK_HZ    = 6_250_000,
    
    // The amount of time each state lasts
    parameter integer STUN_MS   = 3000,
    parameter integer FLASH_MS  = 2000,
    parameter integer ATTACK_MS = 500
)
(
    input             clk,
    input             reset,
    input             game_paused,   // freezes the timer

    input             set_valid,     // 1-cycle: enter set_state
    input      [1:0]  set_state,

    // Current state + effects
    output reg [1:0]  state,
    output            can_act,
    output            screen_white,
    output            screen_red
);
    localparam [1:0] S_NORMAL   = 2'd0;
    localparam [1:0] S_STUNNED  = 2'd1;
    localparam [1:0] S_FLASHED  = 2'd2;
    localparam [1:0] S_ATTACKED = 2'd3;

    // Clock counts (CLK_HZ/1000 first so the products stay inside 32 bits)
    localparam integer CLK_MS      = CLK_HZ / 1000;
    localparam [31:0]  STUN_CLKS   = STUN_MS   * CLK_MS;
    localparam [31:0]  FLASH_CLKS  = FLASH_MS  * CLK_MS;
    localparam [31:0]  ATTACK_CLKS = ATTACK_MS * CLK_MS;

    reg [31:0] clockticks_left = 32'd0;     // clocks left in the current non-NORMAL state

    // Duration of a state when it is entered
    function [31:0] duration (input [1:0] s);
        begin
            case (s)
                S_STUNNED:  duration = STUN_CLKS;
                S_FLASHED:  duration = FLASH_CLKS;
                S_ATTACKED: duration = ATTACK_CLKS;
                default:    duration = 32'd0;
            endcase
        end
    endfunction

    // Initially, you are in Normal State
    initial state = S_NORMAL;

    always @(posedge clk) begin
        if (reset) begin
            state <= S_NORMAL;
            clockticks_left  <= 32'd0;
            
        // If a new state is enforced
        end else if (set_valid) begin
            
            // The latest state occurs
            state <= set_state;
            clockticks_left  <= duration(set_state);
            
        // If we are tracking a non-Normal state during a game, check if the current non-Normal state is over
        end else if (state != S_NORMAL && !game_paused) begin
            // Timed exit back to NORMAL
            if (clockticks_left <= 32'd1) begin // Defensive!
                state <= S_NORMAL;
                clockticks_left  <= 32'd0;
            end else begin
                clockticks_left <= clockticks_left - 32'd1; // Decrement
            end
        end
    end

    // Set the player's effects based on the current state
    assign can_act      = (state != S_STUNNED);
    assign screen_white = (state == S_FLASHED);
    assign screen_red   = (state == S_ATTACKED);
endmodule