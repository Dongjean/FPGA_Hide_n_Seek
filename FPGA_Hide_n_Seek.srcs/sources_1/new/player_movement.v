`timescale 1ns / 1ps
// PROPOSED edit of Dongjin's player_movement.v (adds load_pos/load_x/load_y/load_dir and bump/bump_cx/bump_cy).
// Not a replacement until Dongjin approves; the same change is in player_movement_edits.diff.

module player_movement
#(
    parameter [7:0]DIR_NORTH = 8'd0,
    parameter [7:0]DIR_EAST = 8'd64,
    parameter [7:0]DIR_SOUTH = 8'd128,
    parameter [7:0]DIR_WEST = 8'd192
)
(
    input clk,
    input reset,
    input btn_forward,
    input btn_backward,
    input btn_left,
    input btn_right,
    input frame_begin,
    input [99:0]map_bits,
    input signed [15:0]opp_x,
    input signed [15:0]opp_y,

    // Spawn / teleport load from world_top (later also portal_ctrl)
    input load_pos,                   // 1-cycle: jump to (load_x, load_y) facing load_dir
    input signed [15:0]load_x,        // Q8.8
    input signed [15:0]load_y,
    input [7:0]load_dir,

    output reg bump = 1'b0,           // 1-cycle: a move was blocked by a solid cell
    output reg [3:0]bump_cx = 4'd0,   // the blocked cell (for portal_ctrl)
    output reg [3:0]bump_cy = 4'd0,
    
    output reg signed [15:0]player_x = 16'sd1408,
    output reg signed [15:0]player_y = 16'sd1408,
    output reg [7:0]view_dir = DIR_EAST
);
    `include "trig_LUT.vh"
    `include "wall_helpers.vh"
    
    reg [1:0]move_phase;
    reg [15:0]new_x;
    reg [15:0]new_y;
    
    // Players may not get closer than 0.25 cell (16'd64) to each other.
    // A move is refused only if it ends inside that gap AND brings the players closer, so
    // two players who already overlap (portal landing, link lag) can always walk apart.
    localparam [15:0] MIN_SEP = 16'd64;

    function opp_blocks (input signed [15:0]nx, input signed [15:0]ny,
                         input signed [15:0]cx, input signed [15:0]cy,
                         input signed [15:0]ox, input signed [15:0]oy);
        reg signed [15:0]ndx, ndy, odx, ody;
        reg [15:0]nd, od;
        begin
            ndx = nx - ox;  if (ndx < 0) ndx = -ndx;
            ndy = ny - oy;  if (ndy < 0) ndy = -ndy;
            odx = cx - ox;  if (odx < 0) odx = -odx;
            ody = cy - oy;  if (ody < 0) ody = -ody;
            nd = (ndx > ndy) ? ndx : ndy;
            od = (odx > ody) ? odx : ody;
            opp_blocks = (nd < MIN_SEP) && (nd < od);
        end
    endfunction
    
    function [31:0]move_player (input signed [15:0]x, signed [15:0]y, [7:0]dir);
        begin
            move_player = {x + sin_lut(dir), y - cos_lut(dir)};
        end
    endfunction

    // Direction and walking controls, sampled at the display frame rate.
    // The outer wall map makes the movement collision test sufficient here.
    always @(posedge clk) begin
        bump <= 1'b0;                     // default: bump is a 1-cycle pulse
        if (reset) begin
            move_phase <= 2'd0;
        end else if (load_pos) begin
            // Spawn or teleport: overrides this cycle's movement
            player_x   <= load_x;
            player_y   <= load_y;
            view_dir   <= load_dir;
            move_phase <= 2'd0;
        end else if (frame_begin) begin
            if (btn_left && !btn_right)
                view_dir <= view_dir - 7'd3;
            else if (btn_right && !btn_left)
                view_dir <= view_dir + 7'd3;

            if (move_phase == 2'd3) begin
                move_phase <= 2'd0;
                if (btn_forward && !btn_backward) begin
                    {new_x, new_y} = move_player(player_x, player_y, view_dir);
                    if (map_is_wall(new_x >>> 8, new_y >>> 8, map_bits)) begin
                        bump    <= 1'b1;
                        bump_cx <= new_x[11:8];
                        bump_cy <= new_y[11:8];
                    end else if (!opp_blocks(new_x, new_y, player_x, player_y, opp_x, opp_y)) begin
                        player_x <= new_x;
                        player_y <= new_y;
                    end
                end else if (btn_backward) begin
                    {new_x, new_y} = move_player(player_x, player_y, view_dir-128);
                    if (map_is_wall(new_x >>> 8, new_y >>> 8, map_bits)) begin
                        bump    <= 1'b1;
                        bump_cx <= new_x[11:8];
                        bump_cy <= new_y[11:8];
                    end else if (!opp_blocks(new_x, new_y, player_x, player_y, opp_x, opp_y)) begin
                        player_x <= new_x;
                        player_y <= new_y;
                    end
                end
            end else begin
                move_phase <= move_phase + 2'd1;
            end
        end
    end
endmodule