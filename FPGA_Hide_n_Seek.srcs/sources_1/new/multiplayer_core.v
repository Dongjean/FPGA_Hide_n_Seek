`timescale 1ns / 1ps
// Controls, the other player (second board or AI bot) and status display in one
// block, for the team's top module:
//   - all player controls (buttons, switches, USB mouse or keyboard)   player_controls
//   - the other player, on the second board or the AI bot             opponent_select
//   - this player's health and freeze timer
//   - status LEDs and the 7-segment display
//
// The team's top module keeps player_movement and the renderer, and connects:
//   controls out  -> player_movement (gate its frame_begin with can_move)
//   player_movement's position -> my_x / my_y / my_dir in
//   op_* out      -> whatever draws the other player (sprite, minimap)
//   game_seed / start_game out -> map generator (same map on both boards)
//
// Switches used here:
//   sw[1:0]   weapon (0 = gun, 1 = Pinger for the Seeker / Stim for the Hider)
//   sw[9]     7-segment shows USB device debugging instead of health
//   sw[11:10] bot difficulty, 0 = easy .. 3 = expert
//   sw[12]    1 = play the AI bot, 0 = play the other board (wire on JA)
//   sw[13]    my role: 1 = Seeker, 0 = Hider
//   sw[14]    ready (flip up to start; flip down and up again after a restart)
//   sw[15]    pause (flip either way)
// Buttons: btnU/btnD walk, btnL/btnR turn, btnC shoot, hold btnC 2 s = reset,
//   hold btnD 2 s while paused = restart the match.
//
// LEDs: 15 in game, 14 link up, 13 mouse, 12 keyboard, 11 reveal, 10 I'm frozen,
//   9 role conflict, 8 paused, 4 flips when I'm hit, 1:0 weapon.
// 7-segment: my health (left two digits), other player's health (right two), hex.
//
// Hits: until the renderer can say what a shot hit, SIMPLE_AIM = 1 uses a simple
// test (other player within 4 cells and about 30 degrees of where I face, walls
// ignored). Set SIMPLE_AIM = 0 and pulse renderer_hit instead when that is ready.

module multiplayer_core
#(
    parameter integer CLK_HZ     = 6_250_000,
    parameter integer SIMPLE_AIM = 1,
    parameter [7:0]HIT_DAMAGE    = 8'd20,
    parameter integer FREEZE_MS  = 5000
)
(
    input clk,                         // oled_clk (6.25 MHz)
    input frame_begin,                 // from Oled_Display

    // Board inputs
    input btnU,
    input btnD,
    input btnL,
    input btnR,
    input btnC,
    input [15:0]sw,
    inout PS2Clk,
    inout PS2Data,
    input link_rx,                     // JA2
    output link_tx,                    // JA1

    input [99:0]map_bits,
    input signed [15:0]bot_spawn_x,    // where the bot starts (Q8.8), e.g. world_top's opp_spawn_x
    input signed [15:0]bot_spawn_y,

    // Controls for the rest of the game
    output move_forward,
    output move_backward,
    output turn_left,
    output turn_right,
    output can_move,                   // AND this into player_movement's frame_begin
    output shoot,
    output [1:0]weapon_sel,
    output paused,                     // this player's own pause switch
    output reset_game,

    // This player (from player_movement)
    input signed [15:0]my_x,
    input signed [15:0]my_y,
    input [7:0]my_dir,
    output reg [7:0]my_health = 8'd100,
    output my_frozen,

    // Match
    output in_game,
    output start_game,                 // one pulse on both boards when a match starts
    output restart_game,               // one pulse on both boards on a restart
    output [15:0]game_seed,            // same on both boards: seed the map generator
    output game_paused,                // either player paused, or the link dropped
    output link_up,

    // The other player (second board or bot)
    output signed [15:0]op_x,
    output signed [15:0]op_y,
    output [7:0]op_dir,
    output [7:0]op_health,
    output op_frozen,
    output reveal_active,              // Radio Pinger: show the Hider on the minimap
    output signed [15:0]reveal_x,
    output signed [15:0]reveal_y,
    output got_pinged,                 // I am the Hider and the Seeker just pinged me

    // Hooks for the rest of the team
    input renderer_hit,                // with SIMPLE_AIM = 0: my shot hit the other player
    input my_stim,                     // Stim Shot active on me
    output peer_stim_used,
    input [3:0]capsule_valid,          // Time Capsules for the bot to look at
    input [31:0]capsule_cells,         // {y, x} per capsule
    input ev_capsule,                  // I shot Time Capsule capsule_id
    input [7:0]capsule_id,
    output peer_capsule,               // the other player shot Time Capsule peer_capsule_id
    output [7:0]peer_capsule_id,

    // Board outputs
    output [15:0]led,
    output [6:0]seg,
    output dp,
    output [3:0]an
);
    // ---------------- Controls ----------------
    wire mouse_present, keyboard_present;
    wire [15:0]ps2_debug;

    player_controls #(.CLK_HZ(CLK_HZ)) controls (
        .clk              (clk),
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

    // ---------------- Shooting and items ----------------
    wire seeker = sw[13];
    wire [1:0]my_role = seeker ? 2'd2 : 2'd1;
    reg [31:0]frozen_count = 32'd0;
    assign my_frozen = (frozen_count != 32'd0);
    assign can_move  = !game_paused && !my_frozen && (my_health != 8'd0);

    // Simple aim test (used while SIMPLE_AIM = 1)
    wire signed [15:0]dx = op_x - my_x;
    wire signed [15:0]dy = op_y - my_y;
    wire [15:0]adx = (dx < 0) ? -dx : dx;
    wire [15:0]ady = (dy < 0) ? -dy : dy;
    wire [7:0]aim_error = direction_to(dx, dy) - my_dir;
    wire on_target = (adx + ady <= 16'd1024) && ((aim_error <= 8'd21) || (aim_error >= 8'd235));

    // Direction (0 = N, 64 = E) from me towards (ddx, ddy), to the nearest 16
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

    wire can_act  = in_game && can_move;
    wire fire_gun = shoot && can_act && weapon_sel[0] == 1'b0;
    wire use_item = shoot && can_act && weapon_sel[0] == 1'b1;
    wire hit      = (SIMPLE_AIM != 0) ? (fire_gun && on_target) : (renderer_hit && can_act);
    wire ev_hit    = hit && seeker;      // Seeker's gun damages the Hider
    wire ev_freeze = hit && !seeker;     // Hider's Freeze Gun freezes the Seeker
    wire ev_ping   = use_item && seeker;
    wire ev_stim   = use_item && !seeker;

    // Restart: hold btnD for 2 s while paused
    localparam integer HOLD_CLKS = CLK_HZ * 2;
    reg [31:0]restart_hold = 32'd0;
    wire ev_restart = (restart_hold == HOLD_CLKS);
    always @(posedge clk)
        restart_hold <= (btnD && paused && in_game) ?
                        ((restart_hold == HOLD_CLKS) ? restart_hold : restart_hold + 32'd1) : 32'd0;

    // ---------------- The other player ----------------
    wire role_conflict, got_hit, got_frozen;
    wire [7:0]got_damage;

    opponent_select #(.CLK_HZ(CLK_HZ)) other_player (
        .clk             (clk),
        .reset           (reset_game),
        .solo_mode       (sw[12]),
        .difficulty      (sw[11:10]),
        .link_rx         (link_rx),
        .link_tx         (link_tx),
        .frame_tick      (frame_begin),
        .playing         (in_game),          // no countdown yet: play as soon as the match starts
        .map_bits        (map_bits),
        .bot_spawn_x     (bot_spawn_x),
        .bot_spawn_y     (bot_spawn_y),
        .capsule_valid   (capsule_valid),
        .capsule_cells   (capsule_cells),
        .my_role         (my_role),
        .my_ready        (sw[14]),
        .peer_role       (),
        .peer_ready      (),
        .role_conflict   (role_conflict),
        .in_game         (in_game),
        .start_game      (start_game),
        .game_seed       (game_seed),
        .my_x            (my_x),
        .my_y            (my_y),
        .my_dir          (my_dir),
        .my_health       (my_health),
        .my_paused       (paused),
        .my_frozen       (my_frozen),
        .my_stim         (my_stim),
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
        .hit_damage      (HIT_DAMAGE),
        .ev_freeze       (ev_freeze),
        .ev_ping         (ev_ping),
        .ev_stim         (ev_stim),
        .ev_capsule      (ev_capsule),
        .capsule_id      (capsule_id),
        .ev_restart      (ev_restart),
        .got_hit         (got_hit),
        .got_hit_damage  (got_damage),
        .got_frozen      (got_frozen),
        .got_pinged      (got_pinged),
        .peer_stim_used  (peer_stim_used),
        .peer_capsule    (peer_capsule),
        .peer_capsule_id (peer_capsule_id),
        .restart_game    (restart_game),
        .reveal_active   (reveal_active),
        .reveal_x        (reveal_x),
        .reveal_y        (reveal_y)
    );

    // ---------------- My health and freeze timer ----------------
    localparam integer FREEZE_CLKS = FREEZE_MS * (CLK_HZ / 1000);
    reg hit_toggle = 1'b0;
    always @(posedge clk) begin
        if (reset_game || start_game || restart_game) begin
            my_health    <= 8'd100;
            frozen_count <= 32'd0;
        end else begin
            if (got_hit) begin
                my_health  <= (got_damage >= my_health) ? 8'd0 : my_health - got_damage;
                hit_toggle <= ~hit_toggle;
            end
            if (got_frozen)
                frozen_count <= FREEZE_CLKS;
            else if (my_frozen && !game_paused)
                frozen_count <= frozen_count - 32'd1;
        end
    end

    // ---------------- LEDs and 7-segment ----------------
    assign led = {in_game, link_up, mouse_present, keyboard_present, reveal_active, my_frozen,
                  role_conflict, game_paused, 3'd0, hit_toggle, 2'd0, weapon_sel};

    seven_segment_display #(.CLK_HZ(CLK_HZ)) status_display (
        .clk   (clk),
        .value (sw[9] ? ps2_debug : {my_health, op_health}),
        .seg   (seg),
        .dp    (dp),
        .an    (an)
    );
endmodule