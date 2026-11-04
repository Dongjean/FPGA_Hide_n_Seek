// Graphics helpers, include after trig_LUT.vh and wall_helpers.vh

`include "gfx_tables.vh"

// Dim an RGB565 colour by the distance shade (5..31)
function [15:0]shade_rgb565 (input [15:0]colour, input [4:0]shade);
    reg [5:0]  k;
    reg [9:0]  r_m;
    reg [10:0] g_m;
    reg [9:0]  b_m;
    begin
        k   = {1'b0, shade} + 6'd1;
        r_m = colour[15:11] * k;
        g_m = colour[10:5]  * k;
        b_m = colour[4:0]   * k;
        shade_rgb565 = {r_m[9:5], g_m[10:5], b_m[9:5]};
    end
endfunction

// Screen column (can be off screen) to ray angle offset, (column - 48) * 3 / 8
function [7:0]col_to_angle (input signed [9:0]column);
    reg signed [11:0] centred;
    reg signed [11:0] times3;
    begin
        centred      = column - 12'sd48;
        times3       = (centred <<< 1) + centred;
        col_to_angle = times3[10:3];
    end
endfunction