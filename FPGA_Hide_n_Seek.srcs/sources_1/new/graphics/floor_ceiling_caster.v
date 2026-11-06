`timescale 1ns / 1ps
// Textured floor and ceiling with ceiling lamps
module floor_ceiling_caster (
    input signed [15:0] player_x,    // Q8.8
    input signed [15:0] player_y,
    input        [7:0]  view_dir,
    input        [6:0]  pixel_x,
    input        [5:0]  pixel_y,
    input        [99:0] light_bits,  // from ceiling_light_map
    output       [15:0] colour       // RGB565, distance-shaded
);

    `include "trig_LUT.vh"
    `include "ray_helpers.vh"
    `include "wall_helpers.vh"
    `include "gfx_helpers.vh"

    reg [3:0]  tile_index  [0:767];    // tile 0 floor, 1 ceiling, 2 ceiling lamp
    reg [15:0] palette_unlit [0:47];
    reg [15:0] palette_lit   [0:47];

    initial begin
        $readmemh("floorceil_idx.mem",       tile_index);
        $readmemh("floorceil_pal_unlit.mem", palette_unlit);
        $readmemh("floorceil_pal_lit.mem",   palette_lit);
    end

    wire is_floor = pixel_y[5];

    // Rows from the horizon, same units as the wall half height
    wire [5:0] half_height = is_floor ? (pixel_y - 6'd31) : (6'd32 - pixel_y);
    wire [6:0] steps       = floor_dist_steps(half_height);

    // Ray through this column
    wire [7:0] ray_dir = view_dir + ray_angle_offset(pixel_x);
    wire signed [7:0] sin_r = sin_lut(ray_dir);
    wire signed [7:0] cos_r = cos_lut(ray_dir);
    wire signed [7:0] steps_signed = {1'b0, steps};

    // sin/cos are x64 and a step is 1/1024 cell, so (sin * steps) >> 2 is Q8.8
    wire signed [15:0] prod_x = sin_r * steps_signed;
    wire signed [15:0] prod_y = cos_r * steps_signed;
    wire signed [15:0] world_x = player_x + (prod_x >>> 2);
    wire signed [15:0] world_y = player_y - (prod_y >>> 2);

    wire [3:0] tex_u = world_x[7:4];
    wire [3:0] tex_v = world_y[7:4];

    wire pixel_lit;
    wire lamp_in_cell;
    lamp_light_test lamp_test (
        .light_bits (light_bits),
        .x          (world_x),
        .y          (world_y),
        .lit        (pixel_lit),
        .lamp_here  (lamp_in_cell)
    );

    wire [1:0] tile = is_floor ? 2'd0 : (lamp_in_cell ? 2'd2 : 2'd1);

    wire [9:0] tile_addr    = {tile, tex_v, tex_u};
    wire [3:0] index        = tile_index[tile_addr];
    wire [5:0] palette_addr = {tile, index};

    wire [4:0] shade = wall_shade_for_distance({3'd0, steps});

    wire [15:0] base_colour = pixel_lit ? palette_lit[palette_addr] : palette_unlit[palette_addr];
    assign colour = shade_rgb565(base_colour, shade);

endmodule
