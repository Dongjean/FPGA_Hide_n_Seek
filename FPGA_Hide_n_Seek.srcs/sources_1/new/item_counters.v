`timescale 1ns / 1ps

//item_counters - gun ammo and item uses

module item_counters
#(
    parameter integer CLK_HZ      = 6_250_000,   // oled_clk
    parameter integer SEEKER_AMMO = 10,   // Seeking pistol bullets
    parameter integer SEEKER_USES = 5,    // Radio Pinger uses
    parameter integer HIDER_AMMO  = 5,    // Freeze Gun bullets
    parameter integer HIDER_USES  = 5,     // Flashbang uses
    parameter integer RECHARGE_S  = 10    // Seeker: seconds per recharged bullet
)
(
    input            clk,
    input            reset,
    input            start,           
    input            in_game,         //0 = menu / end screen, stays full
    input            is_hider,        
    input            shoot,           
    input      [1:0] weapon_sel,      
    input            can_move,        //0 = paused / frozen / link lost, ignore presses
    output reg [3:0] ammo,            
    output reg [2:0] uses,            
    output           has_ammo,       
    output           has_use,         
    output           fired_gun,       //1 cycle, gun shot that actually counted
    output           used_item        //1 cycle, item use that actually counted
);
    //full amounts for our role
    wire [3:0] full_ammo = is_hider ? HIDER_AMMO : SEEKER_AMMO;
    wire [2:0] full_uses = is_hider ? HIDER_USES : SEEKER_USES;

    assign has_ammo = (ammo != 4'd0);
    assign has_use  = (uses != 3'd0);

    wire act = shoot && in_game && can_move;
    assign fired_gun = act && (weapon_sel[0] == 1'b0) && has_ammo;
    assign used_item = act && (weapon_sel[0] == 1'b1) && has_use;

    // Seeker pistol recharge: the timer only runs while the pistol is below full and I can
    // act (it stops while paused / frozen / link lost).  At full it sits at 0, so the first
    // bullet after a shot comes RECHARGE_S seconds later.  Shots do not reset the timer.
    localparam integer RECHARGE_CYCLES = CLK_HZ * RECHARGE_S;
    reg [26:0] recharge_cnt;
    wire can_recharge  = !is_hider && (ammo < full_ammo);
    wire recharge_tick = can_recharge && can_move && (recharge_cnt == RECHARGE_CYCLES - 1);

    always @(posedge clk) begin
        if (reset || start || !in_game) begin
            ammo <= full_ammo;
            uses <= full_uses;
            recharge_cnt <= 27'd0;
        end else begin
            // A shot and a recharge in the same cycle cancel out
            case ({fired_gun, recharge_tick})
                2'b10:   ammo <= ammo - 4'd1;
                2'b01:   ammo <= ammo + 4'd1;
                default: ;
            endcase
            if (used_item) uses <= uses - 3'd1;
            
            if (!can_recharge || recharge_tick) recharge_cnt <= 27'd0;
            else if (can_move)                  recharge_cnt <= recharge_cnt + 27'd1;
        end
    end
endmodule