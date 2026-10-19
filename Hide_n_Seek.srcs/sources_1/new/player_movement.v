`timescale 1ns / 1ps

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
    
    output reg signed [15:0]player_x = 16'sd1408,
    output reg signed [15:0]player_y = 16'sd1408,
    output reg [7:0]view_dir = DIR_EAST
);
    `include "trig_LUT.vh"
    `include "wall_helpers.vh"
    
    reg [1:0]move_phase;
    reg [15:0]new_x;
    reg [15:0]new_y;
    
    function [31:0]move_player (input signed [15:0]x, signed [15:0]y, [7:0]dir);
        begin
            move_player = {x + sin_lut(dir), y - cos_lut(dir)};
        end
    endfunction

    // Direction and walking controls, sampled at the display frame rate.
    // The outer wall map makes the movement collision test sufficient here.
    always @(posedge clk) begin
        if (reset) begin
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
                    if (!map_is_wall(new_x >>> 8, new_y >>> 8, map_bits)) begin
                        player_x <= new_x;
                        player_y <= new_y;
                    end
                end else if (btn_backward) begin
                    // (direction - 128) is behind
                    {new_x, new_y} = move_player(player_x, player_y, view_dir-128);
                    if (!map_is_wall(new_x >>> 8, new_y >>> 8, map_bits)) begin
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