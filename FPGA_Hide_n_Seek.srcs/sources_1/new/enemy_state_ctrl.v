`timescale 1ns / 1ps

// For controlling the crowd control state I imbue onto the enemy
module enemy_state_ctrl
#(
    parameter integer CLK_HZ = 6_250_000
)
(
    input        clk,
    input        reset,
    input        game_paused,        // freezes the state timer, like the real FSM
 
    input        aim_hit,            // renderer crosshair_hit: enemy sprite under the crosshair
    input        can_fire,           // in_game && can_move: a shot only counts while I can act
    input        shoot,              // 1-cycle press (player_controls / board_controls)
    input  [1:0] weapon_sel,         // [0]: 0 = gun, 1 = item
    input        is_hider,           // my role
 
    output       hit_valid,          // 1-cycle: a crowd-control shot landed
    output [1:0] hit_state,          // state it puts the enemy in (1, 2 or 3); valid with hit_valid
    output [1:0] enemy_playerstate   // 0 normal, 1 stunned, 2 blinded, 3 damaged
);
    localparam [1:0] S_NORMAL   = 2'd0;
    localparam [1:0] S_STUNNED  = 2'd1;
    localparam [1:0] S_BLINDED  = 2'd2;
    localparam [1:0] S_DAMAGED  = 2'd3;
 
    wire fire      = shoot && can_fire;
    wire fire_gun  = fire && (weapon_sel[0] == 1'b0);
    wire fire_item = fire && (weapon_sel[0] == 1'b1);
 
    wire seeker_pistol = fire_gun  && !is_hider;   // damages
    wire hider_freeze  = fire_gun  &&  is_hider;   // stuns
    wire hider_flash   = fire_item &&  is_hider;   // blinds
 
    assign hit_valid = aim_hit && (seeker_pistol || hider_freeze || hider_flash);
    assign hit_state = seeker_pistol ? S_DAMAGED :
                       hider_freeze  ? S_STUNNED :
                       hider_flash   ? S_BLINDED : S_NORMAL;
 
    // Reuse the player's own state machine for the enemy: it holds the state, counts it down and returns to NORMAL
    // Its can_act / screen_* outputs describe effects on the enemy's screen, so they are not used here
    player_state_FSM #(.CLK_HZ(CLK_HZ)) enemy_state_fsm (
        .clk          (clk),
        .reset        (reset),
        .game_paused  (game_paused),
        .set_valid    (hit_valid),
        .set_state    (hit_state),
        .state        (enemy_playerstate),
        .can_act      (),
        .screen_white (),
        .screen_red   ()
    );
endmodule 