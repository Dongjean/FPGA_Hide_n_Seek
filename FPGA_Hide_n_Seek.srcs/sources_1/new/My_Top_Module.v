`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
//  FILL IN THE FOLLOWING INFORMATION:
//  STUDENT A NAME: Dongjin Shin
//  STUDENT B NAME: Isaac Goh Yong Chee
//  STUDENT C NAME: Andrew Chong Kian Wei
//  STUDENT D NAME: Toh Jian Bin
//////////////////////////////////////////////////////////////////////////////////

// Top module
module My_Top_Module (input clk, btnC, btnU, btnD, btnL, btnR, [4:0]sw, output [7:0]JB);

    wire oled_clk;
    clk_6p25m oled_clk_gen (.clk(clk), .slow_clk(oled_clk));
    
    // Game state managers for FSM
    localparam [1:0]STATE_MENU    = 2'd0;
    localparam [1:0]STATE_PLAYING = 2'd1;
    localparam [1:0]STATE_END     = 2'd2;
    wire [1:0]game_state;

    wire frame_begin;
    wire sending_pixels;
    wire sample_pixel;
    wire [12:0]pixel_index;
    
    // Pixel data variables
    wire [15:0]pixel_data;      // Master Oled Display (we set this to wtv we want the Oled to show)
    wire [15:0]game_pixel_data; // 3D engine output data
    wire [15:0]ui_pixel_data;   // menu / end screen output data

    // Decide what to display based on the game state
    assign pixel_data = (game_state == STATE_PLAYING) ? game_pixel_data : ui_pixel_data;

    // Oled Display module (this just displays whatever pixel_data has)
    Oled_Display oled_display (
        .clk            (oled_clk),
        .reset          (1'b0),
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
    
    // Game state machine
    // MENU -> PLAYING -> END -> MENU ...
    // This sets game_state
    game_fsm fsm (
        .clk         (oled_clk),
        .reset       (1'b0),
        .frame_begin (frame_begin),
        .btn_confirm (btnC),
        .state       (game_state)
    );

    // Menu/end screens (TODO: add pause screen too)
    game_screens screens (
        .clk         (oled_clk),
        .frame_begin (frame_begin),
        .state       (game_state),
        .pixel_index (pixel_index),
        .pixel_data  (ui_pixel_data)
    );

    localparam [7:0]DIR_NORTH = 8'd0;
    localparam [7:0]DIR_EAST  = 8'd64;
    localparam [7:0]DIR_SOUTH = 8'd128;
    localparam [7:0]DIR_WEST  = 8'd192;

    // Player location in Q8.8 units.  Start at the centre of grid square
    wire signed [15:0]player_x;
    wire signed [15:0]player_y;
    wire [7:0]view_dir;
    
    wire signed [15:0] op_x;
    wire signed [15:0] op_y;
    wire [7:0] op_dir;

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

    // ---- Sprite, shots, ornaments (Isaac) ----
    // Seeker sees the Hider as a room object (from the seed), Hider sees the hunter
    wire       spr_enable = 1'b1;
//    wire [1:0] disguise   = (game_seed[1:0] == 2'd3) ? 2'd1 : game_seed[1:0] + 2'd1;   // 1..3
    wire [1:0] spr_obj    = 1'b1 ? 2'd0 : 2'd1;

    // 3D Renderer
    Raycast_3D_Engine #(
        .DIR_NORTH (DIR_NORTH),
        .DIR_EAST  (DIR_EAST),
        .DIR_SOUTH (DIR_SOUTH),
        .DIR_WEST  (DIR_WEST)
    ) renderer (
        .clk         (oled_clk),
        .reset       (reset_game),
        .player_x    (player_x),
        .player_y    (player_y),
        .view_dir    (view_dir),
        .frame_begin (frame_begin),
        .pixel_index (pixel_index),
        .map_bits    (map_bits),
        .spr_enable  (spr_enable),
        .spr_obj     (spr_obj),
        .spr_x       (op_x),
        .spr_y       (op_y),
        .spr_facing  (op_dir),
        .crosshair_hit (crosshair_hit),
        .pixel_data  (game_pixel_data)
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

    // Enemy Player Movement Module
    player_movement #(
        .DIR_NORTH (DIR_NORTH),
        .DIR_EAST  (DIR_EAST),
        .DIR_SOUTH (DIR_SOUTH),
        .DIR_WEST  (DIR_WEST)
    ) enemy_player_mover (
        .clk          (oled_clk),
        .reset        (btnC),
        .btn_forward  (sw[0]),
        .btn_backward (sw[1]),
        .btn_left     (sw[2]),
        .btn_right    (sw[4]),
        .frame_begin  (frame_begin),
        .map_bits     (map_bits),
        .player_x     (op_x),
        .player_y     (op_y),
        .view_dir     (op_dir)
    );

endmodule