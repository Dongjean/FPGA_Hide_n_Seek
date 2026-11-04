`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// item_counters - gun ammo and item uses (Andrew)
//
// Rev 11 (4 Nov 2026): new game spec, per role, NO recharge.
//
//             gun                       item
//   Seeker    Seeking pistol  10        Radio Pinger  5
//   Hider     Freeze Gun       5        Flashbang     5
//
// Full again on reset, on start (new match), and whenever no match is running
// (so the menu / role pick already shows the right numbers for the role).
//
// It counts the same presses Jian Bin's multiplayer_core acts on:
//   gun  = shoot && in_game && can_move && weapon_sel[0] == 0
//   item = shoot && in_game && can_move && weapon_sel[0] == 1
// has_ammo / has_use say whether the next press is allowed.
// IMPORTANT for Jian Bin: multiplayer_core does not look at them yet, so at 0
// you can still shoot / ping / flashbang.  To block it, AND fire_gun with
// has_ammo and use_item with has_use in multiplayer_core (lines 181-182).
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
//////////////////////////////////////////////////////////////////////////////////
module item_counters
#(
    parameter integer SEEKER_AMMO = 10,   // Seeking pistol bullets
    parameter integer SEEKER_USES = 5,    // Radio Pinger uses
    parameter integer HIDER_AMMO  = 5,    // Freeze Gun bullets
    parameter integer HIDER_USES  = 5     // Flashbang uses
)
(
    input            clk,
    input            reset,
    input            start,           // 1-cycle: new match -> full
    input            in_game,         // 0 = menu / end screen: held full
    input            is_hider,        // role: picks the full amounts
    input            shoot,           // 1-cycle (player_controls)
    input      [1:0] weapon_sel,      // [0]: 0 = gun, 1 = item
    input            can_move,        // 0 = paused / frozen / link lost: presses ignored
    output reg [3:0] ammo,            // 0..10
    output reg [2:0] uses,            // 0..5
    output           has_ammo,        // ammo > 0
    output           has_use,         // uses > 0
    output           fired_gun,       // 1-cycle: a counted gun shot (ammo was > 0)
    output           used_item        // 1-cycle: a counted item use (uses was > 0)
);
    // Full amounts for this player's role
    wire [3:0] full_ammo = is_hider ? HIDER_AMMO : SEEKER_AMMO;
    wire [2:0] full_uses = is_hider ? HIDER_USES : SEEKER_USES;

    assign has_ammo = (ammo != 4'd0);
    assign has_use  = (uses != 3'd0);

    // A press only counts while the match runs and I can act, and only if
    // there is something left (so the counters never wrap below 0).
    wire act = shoot && in_game && can_move;
    assign fired_gun = act && (weapon_sel[0] == 1'b0) && has_ammo;
    assign used_item = act && (weapon_sel[0] == 1'b1) && has_use;

    always @(posedge clk) begin
        if (reset || start || !in_game) begin
            ammo <= full_ammo;
            uses <= full_uses;
        end else begin
            if (fired_gun) ammo <= ammo - 4'd1;
            if (used_item) uses <= uses - 3'd1;
        end
    end
endmodule