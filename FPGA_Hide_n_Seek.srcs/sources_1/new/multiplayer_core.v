`timescale 1ns / 1ps
// Controls, the other player (second board or AI bot) and status display in one
// block, for the team's top module:
//   - all player controls (buttons, switches, USB mouse or keyboard)   player_controls
//   - the main menu (role pick), pause, and the end of the match
//   - the other player, on the second board or the AI bot             opponent_select
//   - this player's health
//   - status LEDs and the 7-segment display
//
// The team's top module keeps player_movement and the renderer, and connects:
//   controls out  -> player_movement (gate its frame_begin with can_move)
//   player_movement's position -> my_x / my_y / my_dir in
//   op_* out      -> whatever draws the other player (sprite, minimap)
//   game_seed / start_game out -> map generator (same map on both boards)
//   game_state out -> which screen to show (same on both boards)
//   got_state_change / got_player_state out -> player_state_FSM set_valid / set_state
//
// Screens (game_state): 0 = main menu, 1 = playing, 2 = end screen.
//   Menu:    btnL = Hider, btnR = Seeker, btnC = confirm. A role the other player
//            has confirmed cannot be picked. The match starts when both players
//            have confirmed (solo: as soon as I confirm).
//   Playing: btnU/btnD walk, btnL/btnR turn, btnC shoot.
//            Flip sw[15] to pause both boards; only the player who paused can
//            resume, with btnC. Hold btnD 2 s while paused = abandon the match.
//   End:     the Hider wins when the timer runs out, the Seeker when the Hider's
//            health reaches 0. btnC on either board goes back to the menu.
//
// Switches used here:
//   sw[1:0]   weapon (0 = gun, 1 = Pinger for the Seeker / Stim for the Hider)
//   sw[9]     7-segment shows USB device debugging instead of health
//   sw[11:10] bot difficulty, 0 = easy .. 3 = expert
//   sw[12]    1 = play the AI bot, 0 = play the other board (wire on JA)
//   sw[15]    pause (flip either way)
//
// LEDs: 15 in game, 14 link up, 13 mouse, 12 keyboard, 11 reveal, 10 I'm stunned,
//   9 master board, 8 game paused, 7 I paused, 6 other player confirmed,
//   5 I confirmed, 4 flips when I'm hit, 1:0 weapon.
// 7-segment: my health (left two digits), other player's health (right two), hex.
//
// Hits: with SIMPLE_AIM = 0 a gun shot hits when the renderer says the other
// player is under the crosshair (renderer_hit = crosshair_hit, which respects
// walls). SIMPLE_AIM = 1 keeps the old test for tops without a renderer (other
// player within 4 cells and about 30 degrees of where I face, walls ignored).
//
// Player state: when my shot or item affects the other player, state_change_valid /
// player_state tell their player_state_FSM what to do (Freeze Gun hit -> stunned,
// Seeking Gun hit -> attacked, Stim/Flashbang -> flashed).
 
module multiplayer_core
#(
    parameter integer CLK_HZ     = 6_250_000,
    parameter integer SIMPLE_AIM = 1,
    parameter [7:0]HIT_DAMAGE    = 8'd20
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
    input time_up,                     // match_timer: the time ran out (Hider wins)
    input my_stunned,                  // player_state_FSM is in the stunned state
 
    // Controls for the rest of the game
    output move_forward,
    output move_backward,
    output turn_left,
    output turn_right,
    output can_move,                   // AND this into player_movement's frame_begin
    output shoot,
    output [1:0]weapon_sel,
    output paused,                     // I paused the game (only I can resume it)
    output reset_game,
 
    // This player (from player_movement)
    input signed [15:0]my_x,
    input signed [15:0]my_y,
    input [7:0]my_dir,
    output reg [7:0]my_health = 8'd100,
    output my_frozen,
 
    // Match
    input has_ammo,
    input has_uses,
    output [1:0]game_state,            // 0 = menu, 1 = playing, 2 = end, same on both boards
    output [1:0]my_role,               // 1 = Hider, 2 = Seeker (on the menu: the highlighted role)
    output [1:0]menu_pick,             // menu: highlighted role
    output menu_confirmed,             // menu: I have confirmed menu_pick
    output peer_confirmed,             // menu: the other player has confirmed (the other role)
    output is_master,
    output [1:0]winner,                // end screen: 1 = Hider won, 2 = Seeker won
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
    output got_state_change,           // -> player_state_FSM set_valid
    output [1:0]got_player_state,      // -> player_state_FSM set_state
 
    // Hooks for the rest of the team
    input renderer_hit,                // with SIMPLE_AIM = 0: crosshair_hit from the renderer
    input my_stim,                     // Stim Shot active on me
    output peer_stim_used,
    input [3:0]capsule_valid,          // Time Capsules for the bot to look at
    input [31:0]capsule_cells,         // {y, x} per capsule
    input ev_capsule,                  // I took Time Capsule capsule_id
    input [7:0]capsule_id,
    output peer_capsule,               // the other player took Time Capsule peer_capsule_id
    output [7:0]peer_capsule_id,
 
    // Board outputs
    output [15:0]led,
    output [6:0]seg,
    output dp,
    output [3:0]an
);
    localparam [1:0]ROLE_HIDER  = 2'd1;
    localparam [1:0]ROLE_SEEKER = 2'd2;
    localparam [1:0]GS_MENU     = 2'd0;
    localparam [1:0]GS_PLAYING  = 2'd1;
    localparam [1:0]GS_END      = 2'd2;
    // player_state_FSM states
    localparam [1:0]PS_STUNNED  = 2'd1;
    localparam [1:0]PS_FLASHED  = 2'd2;
    localparam [1:0]PS_ATTACKED = 2'd3;
 
    // ---------------- Controls ----------------
    wire mouse_present, keyboard_present;
    wire [15:0]ps2_debug;
    wire pause_changed;
 
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
        .paused           (),
        .pause_changed    (pause_changed),
        .confirm          (),
        .reset_game       (reset_game),
        .mouse_present    (mouse_present),
        .keyboard_present (keyboard_present),
        .ps2_debug        (ps2_debug)
    );
 
    // ---------------- Match state ----------------
    wire game_over;
    wire master_decided;
    wire [1:0]peer_pick;
    wire [1:0]match_role;              // my role in the current or last match
    wire in_menu = !in_game && !game_over;
    assign game_state = in_game ? GS_PLAYING : (game_over ? GS_END : GS_MENU);
 
    function [1:0]other_role(input [1:0]r);
        other_role = (r == ROLE_HIDER) ? ROLE_SEEKER : ROLE_HIDER;
    endfunction
 
    // ---------------- Main menu ----------------
    // btnL / btnR (or mouse / keyboard turning) highlight Hider / Seeker, btnC confirms
    reg [1:0]pick = ROLE_HIDER;
    reg confirmed = 1'b0;
    reg turn_left_prev = 1'b0;
    reg turn_right_prev = 1'b0;
    wire link_ready = sw[12] || (link_up && master_decided);
    wire pick_taken = peer_confirmed && (peer_pick == pick);   // the other player has this role
 
    always @(posedge clk) begin
        turn_left_prev  <= turn_left;
        turn_right_prev <= turn_right;
        if (reset_game || !in_menu || !link_ready) begin
            confirmed <= 1'b0;
        end else if (!confirmed) begin
            if (turn_left && !turn_left_prev)
                pick <= ROLE_HIDER;
            else if (turn_right && !turn_right_prev)
                pick <= ROLE_SEEKER;
            else if (pick_taken)
                pick <= other_role(pick);
            else if (shoot)
                confirmed <= 1'b1;
        end else if (pick_taken && !is_master) begin
            // Both confirmed the same role at the same moment: the master keeps it
            confirmed <= 1'b0;
            pick      <= other_role(pick);
        end
    end
 
    assign menu_pick      = pick;
    assign menu_confirmed = confirmed;
    assign my_role        = in_menu ? pick : match_role;
 
    // ---------------- Pause ----------------
    // Flipping sw[15] (or Esc / P) pauses; only the player who paused resumes, with btnC
    reg my_pause = 1'b0;
    always @(posedge clk) begin
        if (reset_game || !in_game)
            my_pause <= 1'b0;
        else if (!my_pause && pause_changed)
            my_pause <= 1'b1;
        else if (my_pause && shoot)
            my_pause <= 1'b0;
    end
    assign paused = my_pause;
 
    // ---------------- Shooting and items ----------------
    wire seeker = (match_role == ROLE_SEEKER);
    assign my_frozen = my_stunned;
    assign can_move  = in_game && !game_paused && !my_stunned && (my_health != 8'd0);
 
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
 
    wire can_act  = can_move;
    wire fire_gun = shoot && can_act && weapon_sel[0] == 1'b0 && has_ammo;
    wire use_item = shoot && can_act && weapon_sel[0] == 1'b1 && has_uses;
    wire hit      = (SIMPLE_AIM != 0) ? (fire_gun && on_target) : (fire_gun && renderer_hit);
    wire ev_hit    = hit && seeker;      // Seeker's gun damages the Hider
    wire ev_freeze = hit && !seeker;     // Hider's Freeze Gun freezes the Seeker
    wire ev_ping   = use_item && seeker;
    wire ev_stim   = use_item && !seeker;
 
    // What my action does to the other player's player_state_FSM
    wire state_change_valid = ev_hit || ev_freeze || ev_stim;
    wire [1:0]player_state  = ev_freeze ? PS_STUNNED : (ev_hit ? PS_ATTACKED : PS_FLASHED);
 
    // Restart: hold btnD for 2 s while I have paused
    localparam integer HOLD_CLKS = CLK_HZ * 2;
    reg [31:0]restart_hold = 32'd0;
    wire ev_restart = (restart_hold == HOLD_CLKS);
    always @(posedge clk)
        restart_hold <= (btnD && my_pause && in_game) ?
                        ((restart_hold == HOLD_CLKS) ? restart_hold : restart_hold + 32'd1) : 32'd0;
 
    // ---------------- End of the match ----------------
    // Wait a few clocks after the start so health from the last match is not counted
    reg [2:0]live_count = 3'd0;
    always @(posedge clk)
        live_count <= !in_game ? 3'd0 : ((live_count == 3'd7) ? live_count : live_count + 3'd1);
    wire live = (live_count == 3'd7);
 
    // The Hider's board judges its own health; against the bot, I judge the bot's
    wire hider_dead   = (match_role == ROLE_HIDER  && my_health == 8'd0) ||
                        (sw[12] && match_role == ROLE_SEEKER && op_health == 8'd0);
    wire ev_game_over = live && (hider_dead || time_up);
    wire [1:0]winner_in = hider_dead ? ROLE_SEEKER : ROLE_HIDER;
    wire ev_menu      = game_over && shoot;      // btnC on the end screen
 
    // ---------------- The other player ----------------
    wire got_hit, got_frozen;
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
        .my_pick         (pick),
        .my_confirmed    (confirmed),
        .peer_pick       (peer_pick),
        .peer_confirmed  (peer_confirmed),
        .is_master       (is_master),
        .master_decided  (master_decided),
        .my_role         (match_role),
        .in_game         (in_game),
        .start_game      (start_game),
        .game_seed       (game_seed),
        .ev_game_over    (ev_game_over),
        .winner_in       (winner_in),
        .ev_menu         (ev_menu),
        .game_over       (game_over),
        .winner          (winner),
        .my_x            (my_x),
        .my_y            (my_y),
        .my_dir          (my_dir),
        .my_health       (my_health),
        .my_paused       (my_pause),
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
        .state_change_valid (state_change_valid),
        .player_state    (player_state),
        .got_hit         (got_hit),
        .got_hit_damage  (got_damage),
        .got_frozen      (got_frozen),
        .got_pinged      (got_pinged),
        .peer_stim_used  (peer_stim_used),
        .peer_capsule    (peer_capsule),
        .peer_capsule_id (peer_capsule_id),
        .restart_game    (restart_game),
        .got_state_change (got_state_change),
        .got_player_state (got_player_state),
        .reveal_active   (reveal_active),
        .reveal_x        (reveal_x),
        .reveal_y        (reveal_y)
    );
 
    // ---------------- My health ----------------
    // (A Freeze Gun hit on me now arrives as got_state_change = stunned, which
    //  player_state_FSM times; got_frozen is no longer needed here.)
    reg hit_toggle = 1'b0;
    always @(posedge clk) begin
        if (reset_game || start_game || restart_game) begin
            my_health <= 8'd100;
        end else if (got_hit) begin
            my_health  <= (got_damage >= my_health) ? 8'd0 : my_health - got_damage;
            hit_toggle <= ~hit_toggle;
        end
    end
 
    // ---------------- LEDs and 7-segment ----------------
    assign led = {in_game, link_up, mouse_present, keyboard_present, reveal_active, my_frozen,
                  is_master, game_paused, my_pause, peer_confirmed, confirmed, hit_toggle,
                  2'd0, weapon_sel};
 
    seven_segment_display #(.CLK_HZ(CLK_HZ)) status_display (
        .clk   (clk),
        .value (sw[9] ? ps2_debug : {my_health, op_health}),
        .seg   (seg),
        .dp    (dp),
        .an    (an)
    );
endmodule