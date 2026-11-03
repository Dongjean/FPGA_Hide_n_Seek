`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// item_counters - gun ammo and item uses (PLACEHOLDER until the team decides
// who owns these; the proposal has no owner for them yet)
//
//   Gun  (Seeking Gun / Freeze Gun): 5 bullets, +1 every 60 s of game time
//                                    while below 5.
//   Item (Radio Pinger / Stim Shot): 3 uses, no recharge.
//
// It counts the same presses multiplayer_core acts on:
//   gun  = shoot && in_game && can_move && weapon_sel[0] == 0
//   item = shoot && in_game && can_move && weapon_sel[0] == 1
// has_ammo / has_use say whether the next press is allowed.  IMPORTANT: Jian
// Bin's multiplayer_core does not look at them yet, so at 0 you can still
// fire there; only capsule shots are blocked (the top gates capsule_ctrl).
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
//////////////////////////////////////////////////////////////////////////////////
module item_counters
#(
    parameter integer SEC_CYCLES   = 6_250_000,
    parameter integer MAX_AMMO     = 5,
    parameter integer MAX_USES     = 3,
    parameter integer RECHARGE_SEC = 60
)
(
    input            clk,
    input            reset,
    input            start,           // 1-cycle: new match -> full
    input            in_game,
    input            game_paused,     // recharge time stops while paused
    input            shoot,           // 1-cycle (player_controls)
    input      [1:0] weapon_sel,      // [0]: 0 = gun, 1 = item
    input            can_move,
    output reg [2:0] ammo,            // 0..5
    output reg [1:0] uses,            // 0..3
    output           has_ammo,
    output           has_use,
    output           fired_gun,       // 1-cycle: a counted gun shot (ammo was > 0)
    output           used_item        // 1-cycle: a counted item use (uses was > 0)
);
    assign has_ammo = (ammo != 3'd0);
    assign has_use  = (uses != 2'd0);

    wire act = shoot && in_game && can_move;
    assign fired_gun = act && (weapon_sel[0] == 1'b0) && has_ammo;
    assign used_item = act && (weapon_sel[0] == 1'b1) && has_use;

    reg [22:0] sub_cnt;               // clocks within the second
    reg [5:0]  rc_sec;                // seconds towards the next bullet
    wire running  = in_game && !game_paused;
    wire sec_tick = running && (sub_cnt == SEC_CYCLES - 1);
    wire refill   = sec_tick && (rc_sec == RECHARGE_SEC - 1) && (ammo < MAX_AMMO);

    always @(posedge clk) begin
        if (reset || start) begin
            ammo    <= MAX_AMMO;
            uses    <= MAX_USES;
            sub_cnt <= 23'd0;
            rc_sec  <= 6'd0;
        end else begin
            if (running) sub_cnt <= sec_tick ? 23'd0 : sub_cnt + 23'd1;

            // Recharge clock only runs while a bullet is missing, so a refill
            // always comes a full 60 s after the magazine was last full.
            if (ammo == MAX_AMMO)  rc_sec <= 6'd0;
            else if (sec_tick)     rc_sec <= (rc_sec == RECHARGE_SEC - 1) ? 6'd0 : rc_sec + 6'd1;

            // shot and refill in the same cycle cancel out
            if (fired_gun && !refill)      ammo <= ammo - 3'd1;
            else if (refill && !fired_gun) ammo <= ammo + 3'd1;

            if (used_item) uses <= uses - 2'd1;
        end
    end
endmodule