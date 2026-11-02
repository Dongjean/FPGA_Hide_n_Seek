`timescale 1ns / 1ps
// Jian Bin's top module: one-board demo of the link, controls and AI bot,
// before integration with the team's game.
// Shows a top-down view of the map on the OLED (JB) and lets you play hide-and-seek
// against the AI bot, or against a second board running the same bitstream.
//
// Uses the team's Oled_Display, clk_6p25m and player_movement unchanged.
//
// Controls (any mix of buttons, a USB mouse or a USB keyboard):
//   walk btnU/btnD, W/S         turn btnL/btnR, A/D, mouse
//   shoot btnC, Space, left click
//   weapon sw[1:0], 1/2, right click   (weapon 0 = gun, weapon 1 = Pinger/Stim)
//   pause flip sw[15], Esc/P          reset: hold btnC 2 s
// Set-up switches:
//   sw[12]    1 = play the bot, 0 = play the other board (wire on JA)
//   sw[13]    my role: 1 = Seeker, 0 = Hider
//   sw[14]    ready (flip up to start; flip down and up again after a restart)
//   sw[11:10] bot difficulty 0 = easy .. 3 = expert
//   btnD held 2 s while paused: restart the match
//
// OLED: walls grey, me blue (with a dot showing where I face), opponent red
//   (cyan while frozen, flashing yellow during a Radio Pinger reveal),
//   right-hand bars: my health (blue) and opponent health (red).
// LEDs: 15 in game, 14 link up, 13 mouse, 12 keyboard, 11 reveal, 10 I'm frozen,
//   9 role conflict, 8 paused, 4 flips when I'm hit, 1:0 weapon.
// 7-segment: my health (left two digits) and opponent health (right two), in hex.
//   With sw[9] up it shows USB device debugging instead:
//   digit 3 = detection state (7 = mouse running, 8 = keyboard running),
//   digit 2 = bytes received (counts up, wraps at F), digits 1-0 = last byte in hex.

module jb_top
(
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
    localparam integer CLK_HZ = 6_250_000;
    localparam [99:0]MAP = {
        10'b1111111111, 10'b1010001001, 10'b1010001001, 10'b1010011001, 10'b1010010001,
        10'b1000000001, 10'b1100011001, 10'b1000010001, 10'b1000010001, 10'b1111111111
    };

    wire oled_clk;
    clk_6p25m oled_clk_gen (.clk(clk), .slow_clk(oled_clk));

    // ---------------- Controls ----------------
    wire move_forward, move_backward, turn_left, turn_right, shoot;
    wire [1:0]weapon_sel;
    wire paused, reset_game, mouse_present, keyboard_present;
    wire [15:0]ps2_debug;
    wire frame_begin;

    player_controls #(.CLK_HZ(CLK_HZ)) controls (
        .clk              (oled_clk),
        .frame_tick       (frame_begin),
        .btnU             (btnU),
        .btnD             (btnD),
        .btnL             (btnL),
        .btnR             (btnR),
        .btnC             (btnC),
        .sw               (sw),
        .ps2_clk          (PS2Clk),
        .ps2_data         (PS2Data),
        .move_forward     (move_forward),
        .move_backward    (move_backward),
        .turn_left        (turn_left),
        .turn_right       (turn_right),
        .shoot            (shoot),
        .weapon_sel       (weapon_sel),
        .weapon_changed   (),
        .paused           (paused),
        .pause_changed    (),
        .confirm          (),
        .reset_game       (reset_game),
        .mouse_present    (mouse_present),
        .keyboard_present (keyboard_present),
        .ps2_debug        (ps2_debug)
    );

    // ---------------- Me ----------------
    wire signed [15:0]my_x, my_y;
    wire [7:0]my_dir;
    reg [7:0]my_health = 8'd100;
    reg [31:0]my_frozen_count = 32'd0;
    wire my_frozen = (my_frozen_count != 32'd0);
    wire game_paused;
    wire in_game;

    player_movement player_mover (
        .clk          (oled_clk),
        .reset        (reset_game),
        .btn_forward  (move_forward),
        .btn_backward (move_backward),
        .btn_left     (turn_left),
        .btn_right    (turn_right),
        .frame_begin  (frame_begin && !game_paused && !my_frozen && my_health != 8'd0),
        .map_bits     (MAP),
        .player_x     (my_x),
        .player_y     (my_y),
        .view_dir     (my_dir)
    );

    // ---------------- Opponent (bot or second board) ----------------
    wire [1:0]my_role = sw[13] ? 2'd2 : 2'd1;
    wire seeker = sw[13];
    wire signed [15:0]op_x, op_y;
    wire [7:0]op_dir, op_health;
    wire op_frozen, link_up, role_conflict, start_game, reveal_active, restart_game;
    wire got_hit, got_frozen, got_pinged;
    wire [7:0]got_damage;

    // Shooting test for the demo: the opponent must be within 4 cells and
    // within about 30 degrees of where I am facing (walls are ignored here;
    // in the real game the renderer decides what was hit).
    wire signed [15:0]dx = op_x - my_x;
    wire signed [15:0]dy = op_y - my_y;
    wire [15:0]adx = (dx < 0) ? -dx : dx;
    wire [15:0]ady = (dy < 0) ? -dy : dy;
    wire [7:0]aim = direction_to(dx, dy);
    wire [7:0]aim_error = aim - my_dir;
    wire on_target = (adx + ady <= 16'd1024) && ((aim_error <= 8'd21) || (aim_error >= 8'd235));

    function [7:0]direction_to(input signed [15:0]ddx, input signed [15:0]ddy);
        reg [19:0]ax, ay;
        reg [7:0]a;
        begin
            ax = (ddx < 0) ? -ddx : ddx;
            ay = (ddy < 0) ? -ddy : ddy;
            if      (ax * 5 < ay)     a = 8'd0;
            else if (ax * 3 < ay * 2) a = 8'd16;
            else if (ax * 2 < ay * 3) a = 8'd32;
            else if (ax < ay * 5)     a = 8'd48;
            else                      a = 8'd64;
            if (ddx >= 0 && ddy <= 0) direction_to = a;
            else if (ddx >= 0)        direction_to = 8'd128 - a;
            else if (ddy > 0)         direction_to = 8'd128 + a;
            else                      direction_to = 8'd0 - a;
        end
    endfunction

    wire can_act = in_game && !game_paused && !my_frozen && my_health != 8'd0;
    wire fire_gun = shoot && can_act && weapon_sel[0] == 1'b0;
    wire use_item = shoot && can_act && weapon_sel[0] == 1'b1;
    wire ev_hit    = fire_gun && seeker && on_target;
    wire ev_freeze = fire_gun && !seeker && on_target;
    wire ev_ping   = use_item && seeker;
    wire ev_stim   = use_item && !seeker;

    // Restart: hold btnD for 2 s while paused
    reg [31:0]restart_hold = 32'd0;
    wire ev_restart = (restart_hold == CLK_HZ * 2);
    always @(posedge oled_clk)
        restart_hold <= (btnD && paused && in_game) ? ((restart_hold == CLK_HZ * 2) ? restart_hold : restart_hold + 32'd1) : 32'd0;

    opponent_select #(.CLK_HZ(CLK_HZ)) other_player (
        .clk             (oled_clk),
        .reset           (reset_game),
        .solo_mode       (sw[12]),
        .difficulty      (sw[11:10]),
        .link_rx         (link_rx),
        .link_tx         (link_tx),
        .frame_tick      (frame_begin),
        .playing         (in_game),
        .map_bits        (MAP),
        .bot_spawn_x     (16'sd2176),        // cell (8,8)
        .bot_spawn_y     (16'sd2176),
        .capsule_valid   (4'd0),
        .capsule_cells   (32'd0),
        .my_role         (my_role),
        .my_ready        (sw[14]),
        .peer_role       (),
        .peer_ready      (),
        .role_conflict   (role_conflict),
        .in_game         (in_game),
        .start_game      (start_game),
        .game_seed       (),
        .my_x            (my_x),
        .my_y            (my_y),
        .my_dir          (my_dir),
        .my_health       (my_health),
        .my_paused       (paused),
        .my_frozen       (my_frozen),
        .my_stim         (1'b0),
        .peer_x          (op_x),
        .peer_y          (op_y),
        .peer_dir        (op_dir),
        .peer_health     (op_health),
        .peer_paused     (),
        .peer_frozen     (op_frozen),
        .peer_stim       (),
        .link_up         (link_up),
        .game_paused     (game_paused),
        .ev_hit          (ev_hit),
        .hit_damage      (8'd20),
        .ev_freeze       (ev_freeze),
        .ev_ping         (ev_ping),
        .ev_stim         (ev_stim),
        .ev_capsule      (1'b0),
        .capsule_id      (8'd0),
        .ev_restart      (ev_restart),
        .got_hit         (got_hit),
        .got_hit_damage  (got_damage),
        .got_frozen      (got_frozen),
        .got_pinged      (got_pinged),
        .peer_stim_used  (),
        .peer_capsule    (),
        .peer_capsule_id (),
        .restart_game    (restart_game),
        .reveal_active   (reveal_active),
        .reveal_x        (),
        .reveal_y        ()
    );

    // My health and freeze timer
    reg hit_toggle = 1'b0;
    always @(posedge oled_clk) begin
        if (reset_game || start_game || restart_game) begin
            my_health       <= 8'd100;
            my_frozen_count <= 32'd0;
        end else begin
            if (got_hit) begin
                my_health  <= (got_damage >= my_health) ? 8'd0 : my_health - got_damage;
                hit_toggle <= ~hit_toggle;
            end
            if (got_frozen)
                my_frozen_count <= CLK_HZ * 5;
            else if (my_frozen && !game_paused)
                my_frozen_count <= my_frozen_count - 32'd1;
        end
    end

    // ---------------- Top-down view on the OLED ----------------
    wire sending_pixels, sample_pixel;
    wire [12:0]pixel_index;
    reg [15:0]pixel_data;

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

    localparam [15:0]C_WALL = 16'h8410, C_FLOOR = 16'h0841, C_ME = 16'h3A7F, C_OP = 16'hF800;
    localparam [15:0]C_FROZEN = 16'h07FF, C_REVEAL = 16'hFFE0, C_BLACK = 16'h0000, C_FACE = 16'hFFFF;

    // Map area: 10 x 10 cells of 6 x 6 pixels, starting at screen (18, 2)
    wire [6:0]px = pixel_index % 96;
    wire [5:0]py = pixel_index / 96;
    wire in_map = (px >= 7'd18) && (px < 7'd78) && (py >= 6'd2) && (py < 6'd62);
    wire [6:0]mx = px - 7'd18;           // 0..59 inside the map
    wire [5:0]my = py - 6'd2;
    wire [3:0]cell_x = mx / 6;
    wire [3:0]cell_y = my / 6;
    wire cell_is_wall = MAP[99 - (cell_y * 10 + cell_x)];

    // Screen position of a Q8.8 map point: 6 pixels per cell
    function [6:0]to_screen(input signed [15:0]v);
        reg [19:0]scaled;
        begin
            scaled = v * 6;
            to_screen = scaled[14:8];
        end
    endfunction
    wire [6:0]me_sx = to_screen(my_x);
    wire [6:0]me_sy = to_screen(my_y);
    wire [6:0]op_sx = to_screen(op_x);
    wire [6:0]op_sy = to_screen(op_y);

    // Facing dot two pixels from my centre, in the nearest of 8 directions
    reg signed [2:0]face_dx, face_dy;
    always @(*) begin
        case ((my_dir + 8'd16) >> 5)
            3'd0: begin face_dx =  0; face_dy = -2; end
            3'd1: begin face_dx =  2; face_dy = -2; end
            3'd2: begin face_dx =  2; face_dy =  0; end
            3'd3: begin face_dx =  2; face_dy =  2; end
            3'd4: begin face_dx =  0; face_dy =  2; end
            3'd5: begin face_dx = -2; face_dy =  2; end
            3'd6: begin face_dx = -2; face_dy =  0; end
            default: begin face_dx = -2; face_dy = -2; end
        endcase
    end

    wire near_me = (mx + 7'd1 >= me_sx) && (mx <= me_sx + 7'd1) && ({1'b0, my} + 7'd1 >= me_sy) && ({1'b0, my} <= me_sy + 7'd1);
    wire on_face = (mx == me_sx + {{4{face_dx[2]}}, face_dx}) && ({1'b0, my} == me_sy + {{4{face_dy[2]}}, face_dy});
    wire near_op = (mx + 7'd1 >= op_sx) && (mx <= op_sx + 7'd1) && ({1'b0, my} + 7'd1 >= op_sy) && ({1'b0, my} <= op_sy + 7'd1);
    wire ring_op = (mx + 7'd3 >= op_sx) && (mx <= op_sx + 7'd3) && ({1'b0, my} + 7'd3 >= op_sy) && ({1'b0, my} <= op_sy + 7'd3) && !near_op;

    // Blink for the reveal ring (about 4 Hz)
    reg [20:0]blink = 21'd0;
    always @(posedge oled_clk) blink <= blink + 21'd1;

    // Health bars: x 82-86 me, x 89-93 opponent; 0-100 health shown as 0-50 pixels high
    wire [5:0]my_bar = (my_health > 8'd100 ? 8'd100 : my_health) >> 1;
    wire [5:0]op_bar = (op_health > 8'd100 ? 8'd100 : op_health) >> 1;
    wire in_my_bar = (px >= 7'd82) && (px <= 7'd86) && (py >= 6'd57 - my_bar) && (py < 6'd57);
    wire in_op_bar = (px >= 7'd89) && (px <= 7'd93) && (py >= 6'd57 - op_bar) && (py < 6'd57);

    always @(*) begin
        if (in_map) begin
            if (on_face)
                pixel_data = C_FACE;
            else if (near_me)
                pixel_data = C_ME;
            else if (in_game && near_op)
                pixel_data = op_frozen ? C_FROZEN : C_OP;
            else if (in_game && reveal_active && ring_op && blink[20])
                pixel_data = C_REVEAL;
            else
                pixel_data = cell_is_wall ? C_WALL : C_FLOOR;
        end else if (in_my_bar) begin
            pixel_data = C_ME;
        end else if (in_op_bar) begin
            pixel_data = C_OP;
        end else begin
            pixel_data = C_BLACK;
        end
    end

    // ---------------- LEDs and 7-segment ----------------
    assign led = {in_game, link_up, mouse_present, keyboard_present, reveal_active, my_frozen,
                  role_conflict, game_paused, 3'd0, hit_toggle, 2'd0, weapon_sel};

    seven_segment_display #(.CLK_HZ(CLK_HZ)) health_display (
        .clk   (oled_clk),
        .value (sw[9] ? ps2_debug : {my_health, op_health}),
        .seg   (seg),
        .dp    (dp),
        .an    (an)
    );
endmodule
