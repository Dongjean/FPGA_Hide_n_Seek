`timescale 1ns / 1ps

//item_counters - gun ammo and item uses (andrew)

module item_counters
#(
    parameter integer SEEKER_AMMO = 10,   //seeking pistol bullets
    parameter integer SEEKER_USES = 5,    //radio pinger uses
    parameter integer HIDER_AMMO  = 5,    //freeze gun bullets
    parameter integer HIDER_USES  = 5     //flashbang uses
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