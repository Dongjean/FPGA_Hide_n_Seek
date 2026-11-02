`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
//  FILL IN THE FOLLOWING INFORMATION:
//  STUDENT A NAME: Dongjin Shin
//  STUDENT B NAME: Isaac Goh Yong Chee
//  STUDENT C NAME: Andrew Chong Kian Wei
//  STUDENT D NAME: Toh Jian Bin
//////////////////////////////////////////////////////////////////////////////////

// Top module
// Constraints: Basys3_Master.xdc + multiplayer_pins.xdc (JA link, USB port, 7-segment).
// Two-board play: JA1 of each board to JA2 of the other, and JA5 (GND) to JA5.
module My_Top_Module (
    input clk,
    input btnC,
    input btnU,
    input btnD,
    input btnL,
    input btnR,
    input [15:0]sw,
    output [15:0]led,
    output [6:0]seg,
    output dp,
    output [3:0]an,
    output [7:0]JB,
    inout PS2Clk,
    inout PS2Data,
    output link_tx,
    input link_rx
);

    wire oled_clk;
    clk_6p25m oled_clk_gen (.clk(clk), .slow_clk(oled_clk));

    localparam [7:0]DIR_NORTH = 8'd0;
    localparam [7:0]DIR_EAST  = 8'd64;
    localparam [7:0]DIR_SOUTH = 8'd128;
    localparam [7:0]DIR_WEST  = 8'd192;

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

    wire frame_begin;
    wire sending_pixels;
    wire sample_pixel;
    wire [12:0]pixel_index;
    wire [15:0]pixel_data;

    // Player location in Q8.8 units
    wire signed [15:0]player_x;
    wire signed [15:0]player_y;
    wire [7:0]view_dir;

    // ---------------- Controls, other player (link or bot), status ----------------
    wire move_forward, move_backward, turn_left, turn_right, can_move;
    wire shoot, paused, reset_game;
    wire [1:0]weapon_sel;
    wire [7:0]my_health;
    wire my_frozen;
    wire in_game, start_game, restart_game, game_paused, link_up;
    wire [15:0]game_seed;
    wire signed [15:0]op_x, op_y;           // other player: draw these (sprite / minimap)
    wire [7:0]op_dir, op_health;
    wire op_frozen;
    wire reveal_active, got_pinged;
    wire signed [15:0]reveal_x, reveal_y;

    multiplayer_core #(.CLK_HZ(6_250_000)) multiplayer (
        .clk             (oled_clk),
        .frame_begin     (frame_begin),
        .btnU            (btnU),
        .btnD            (btnD),
        .btnL            (btnL),
        .btnR            (btnR),
        .btnC            (btnC),
        .sw              (sw),
        .PS2Clk          (PS2Clk),
        .PS2Data         (PS2Data),
        .link_rx         (link_rx),
        .link_tx         (link_tx),
        .map_bits        (map_bits),
        .move_forward    (move_forward),
        .move_backward   (move_backward),
        .turn_left       (turn_left),
        .turn_right      (turn_right),
        .can_move        (can_move),
        .shoot           (shoot),
        .weapon_sel      (weapon_sel),
        .paused          (paused),
        .reset_game      (reset_game),
        .my_x            (player_x),
        .my_y            (player_y),
        .my_dir          (view_dir),
        .my_health       (my_health),
        .my_frozen       (my_frozen),
        .in_game         (in_game),
        .start_game      (start_game),
        .restart_game    (restart_game),
        .game_seed       (game_seed),
        .game_paused     (game_paused),
        .link_up         (link_up),
        .op_x            (op_x),
        .op_y            (op_y),
        .op_dir          (op_dir),
        .op_health       (op_health),
        .op_frozen       (op_frozen),
        .reveal_active   (reveal_active),
        .reveal_x        (reveal_x),
        .reveal_y        (reveal_y),
        .got_pinged      (got_pinged),
        .renderer_hit    (1'b0),
        .my_stim         (1'b0),
        .peer_stim_used  (),
        .capsule_valid   (4'd0),
        .capsule_cells   (32'd0),
        .ev_capsule      (1'b0),
        .capsule_id      (8'd0),
        .peer_capsule    (),
        .peer_capsule_id (),
        .led             (led),
        .seg             (seg),
        .dp              (dp),
        .an              (an)
    );

    // Oled Display module
    Oled_Display oled_display (
        .clk            (oled_clk),
        .reset          (reset_game),
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
    assign JB[2] = 1'b0;

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
        .pixel_data  (pixel_data)
    );

    // Player Movement Module
    // Stops while either player is paused, the link is lost, I am frozen or out of health.
    player_movement #(
        .DIR_NORTH (DIR_NORTH),
        .DIR_EAST  (DIR_EAST),
        .DIR_SOUTH (DIR_SOUTH),
        .DIR_WEST  (DIR_WEST)
    ) player_mover (
        .clk          (oled_clk),
        .reset        (reset_game),
        .btn_forward  (move_forward),
        .btn_backward (move_backward),
        .btn_left     (turn_left),
        .btn_right    (turn_right),
        .frame_begin  (frame_begin && can_move),
        .map_bits     (map_bits),
        .player_x     (player_x),
        .player_y     (player_y),
        .view_dir     (view_dir)
    );

endmodule
