`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
//  FILL IN THE FOLLOWING INFORMATION:
//  STUDENT A NAME: Dongjin Shin
//  STUDENT B NAME: Isaac Goh Yong Chee
//  STUDENT C NAME: Andrew Chong Kian Wei
//  STUDENT D NAME: Toh Jian Bin
//////////////////////////////////////////////////////////////////////////////////

// Top module
module My_Top_Module (input clk, btnC, btnU, btnD, btnL, btnR, output [7:0]JB);

    wire oled_clk;
    clk_6p25m oled_clk_gen (.clk(clk), .slow_clk(oled_clk));

    wire frame_begin;
    wire sending_pixels;
    wire sample_pixel;
    wire [12:0]pixel_index;
    wire [15:0]pixel_data;

    // Oled Display module
    Oled_Display oled_display (
        .clk            (oled_clk),
        .reset          (btnC),
        .frame_begin    (frame_begin),
        .sending_pixels (sending_pixels),
        .sample_pixel   (sample_pixel),
        .pixel_index    (pixel_index),
        .pixel_data     (pixel_data),
        .cs             (JB[0]),
        .sdin           (JB[1]),
        .sclk           (JB[3]),
        .d_cn           (JB[4]),
        .resn           (JB[5]),
        .vccen          (JB[6]),
        .pmoden         (JB[7])
    );

    localparam [7:0]DIR_NORTH = 8'd0;
    localparam [7:0]DIR_EAST  = 8'd64;
    localparam [7:0]DIR_SOUTH = 8'd128;
    localparam [7:0]DIR_WEST  = 8'd192;

    // Player location in Q8.8 units.  Start at the centre of grid square
    wire signed [15:0]player_x;
    wire signed [15:0]player_y;
    wire [7:0]view_dir;

    localparam [99:0] DEFAULT_MAP = {
        10'b1111111111,
        10'b1010001001,
        10'b1010001001,
        10'b1010011001,
        10'b1010010001,
        10'b1000000001,
        10'b1100011001,
        10'b1000010001,
        10'b1000010001,
        10'b1111111111
    };
    wire [99:0] map_bits = DEFAULT_MAP;

    // 3D Renderer
    Raycast_3D_Engine #(
        .DIR_NORTH (DIR_NORTH),
        .DIR_EAST  (DIR_EAST),
        .DIR_SOUTH (DIR_SOUTH),
        .DIR_WEST  (DIR_WEST)
    ) renderer (
        .clk         (oled_clk),
        .reset       (btnC),
        .player_x    (player_x),
        .player_y    (player_y),
        .view_dir    (view_dir),
        .frame_begin (frame_begin),
        .pixel_index (pixel_index),
        .map_bits    (map_bits),
        .pixel_data  (pixel_data)
    );
    
    // Player Movement Module
    player_movement #(
        .DIR_NORTH (DIR_NORTH),
        .DIR_EAST  (DIR_EAST),
        .DIR_SOUTH (DIR_SOUTH),
        .DIR_WEST  (DIR_WEST)
    ) player_mover (
        .clk          (oled_clk),
        .reset        (btnC),
        .btn_forward  (btnU),
        .btn_backward (btnD),
        .btn_left     (btnL),
        .btn_right    (btnR),
        .frame_begin  (frame_begin),
        .map_bits     (map_bits),
        .player_x     (player_x),
        .player_y     (player_y),
        .view_dir     (view_dir)
    );

endmodule