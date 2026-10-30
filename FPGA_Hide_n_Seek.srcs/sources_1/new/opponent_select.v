`timescale 1ns / 1ps
// The other player, whoever it is. The game connects to this one module:
//
//   solo_mode = 0: the other player is on the second Basys3 board (multiplayer_link)
//   solo_mode = 1: the other player is the AI bot (ai_bot)
//
// Both sides use exactly the same signals, so the rest of the game works the same
// in both modes: it sends this player's state and events in, and gets the other
// player's state and events out.
//
// In solo mode the start-up is local: as soon as the player picks a role and
// presses ready, the game starts with a random seed and the bot takes the other
// role. The bot is placed at bot_spawn when `playing` first goes high (after the
// map has been generated and the countdown has finished).

module opponent_select
#(
    parameter integer CLK_HZ = 6_250_000,
    parameter integer BAUD   = 115_200,
    parameter integer MAP_W  = 10,
    parameter integer MAP_H  = 10,
    parameter integer REVEAL_MS = 2000
)
(
    input clk,
    input reset,
    input solo_mode,
    input [1:0]difficulty,               // bot difficulty, 0 = easy to 3 = expert
    input link_rx,
    output link_tx,

    // From the rest of the game
    input frame_tick,
    input playing,                       // countdown over and the match is running
    input [MAP_W*MAP_H-1:0]map_bits,
    input signed [15:0]bot_spawn_x,      // where the other player starts
    input signed [15:0]bot_spawn_y,
    input [3:0]capsule_valid,
    input [31:0]capsule_cells,           // {y, x} per capsule

    // Start-up
    input [1:0]my_role,                  // 1 = Hider, 2 = Seeker
    input my_ready,
    output [1:0]peer_role,
    output peer_ready,
    output role_conflict,
    output in_game,
    output start_game,
    output [15:0]game_seed,

    // This player
    input signed [15:0]my_x,
    input signed [15:0]my_y,
    input [7:0]my_dir,
    input [7:0]my_health,
    input my_paused,
    input my_frozen,
    input my_stim,

    // The other player
    output signed [15:0]peer_x,
    output signed [15:0]peer_y,
    output [7:0]peer_dir,
    output [7:0]peer_health,
    output peer_paused,
    output peer_frozen,
    output peer_stim,
    output link_up,                      // board-to-board link status (multiplayer)
    output game_paused,

    // Events this player causes
    input ev_hit,
    input [7:0]hit_damage,
    input ev_freeze,
    input ev_ping,
    input ev_stim,
    input ev_capsule,
    input [7:0]capsule_id,
    input ev_restart,

    // Events the other player causes
    output got_hit,
    output [7:0]got_hit_damage,
    output got_frozen,
    output got_pinged,
    output peer_stim_used,
    output peer_capsule,
    output [7:0]peer_capsule_id,
    output restart_game,

    // Radio Pinger reveal (this player is the Seeker)
    output reveal_active,
    output signed [15:0]reveal_x,
    output signed [15:0]reveal_y
);
    localparam [1:0]ROLE_HIDER  = 2'd1;
    localparam [1:0]ROLE_SEEKER = 2'd2;
    localparam integer REVEAL_CLKS = REVEAL_MS * (CLK_HZ / 1000);

    // ---------------- Second board ----------------
    wire [1:0]l_peer_role;
    wire l_peer_ready, l_conflict, l_in_game, l_start;
    wire [15:0]l_seed;
    wire signed [15:0]l_x, l_y;
    wire [7:0]l_dir, l_health;
    wire l_paused, l_frozen, l_stim, l_game_paused;
    wire l_got_hit, l_got_frozen, l_got_pinged, l_stim_used, l_capsule, l_restart;
    wire [7:0]l_damage, l_capsule_id;
    wire l_reveal;

    multiplayer_link #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .REVEAL_MS(REVEAL_MS)) link (
        .clk            (clk),
        .reset          (reset),
        .link_rx        (link_rx),
        .link_tx        (link_tx),
        .my_role        (my_role),
        .my_ready       (my_ready && !solo_mode),
        .peer_role      (l_peer_role),
        .peer_ready     (l_peer_ready),
        .role_conflict  (l_conflict),
        .in_game        (l_in_game),
        .start_game     (l_start),
        .game_seed      (l_seed),
        .my_x           (my_x),
        .my_y           (my_y),
        .my_dir         (my_dir),
        .my_health      (my_health),
        .my_paused      (my_paused),
        .my_frozen      (my_frozen),
        .my_stim        (my_stim),
        .peer_x         (l_x),
        .peer_y         (l_y),
        .peer_dir       (l_dir),
        .peer_health    (l_health),
        .peer_paused    (l_paused),
        .peer_frozen    (l_frozen),
        .peer_stim      (l_stim),
        .peer_in_game   (),
        .link_up        (link_up),
        .game_paused    (l_game_paused),
        .ev_hit         (ev_hit && !solo_mode),
        .hit_damage     (hit_damage),
        .ev_freeze      (ev_freeze && !solo_mode),
        .ev_ping        (ev_ping && !solo_mode),
        .ev_stim        (ev_stim && !solo_mode),
        .ev_capsule     (ev_capsule && !solo_mode),
        .capsule_id     (capsule_id),
        .ev_restart     (ev_restart && !solo_mode),
        .got_hit        (l_got_hit),
        .got_hit_damage (l_damage),
        .got_frozen     (l_got_frozen),
        .got_pinged     (l_got_pinged),
        .peer_stim_used (l_stim_used),
        .peer_capsule   (l_capsule),
        .peer_capsule_id(l_capsule_id),
        .restart_game   (l_restart),
        .reveal_active  (l_reveal),
        .reveal_x       (),
        .reveal_y       (),
        .rx_error_count (),
        .ev_overflow    ()
    );

    // ---------------- Solo start-up ----------------
    reg s_in_game = 1'b0;
    reg s_start = 1'b0;
    reg s_restart = 1'b0;
    reg [15:0]s_seed = 16'd1;
    reg s_armed = 1'b0;
    reg [15:0]free_count = 16'd0;
    reg playing_prev = 1'b0;
    reg bot_place = 1'b0;
    reg [31:0]s_reveal = 32'd0;

    wire [1:0]bot_role = (my_role == ROLE_HIDER)  ? ROLE_SEEKER :
                         (my_role == ROLE_SEEKER) ? ROLE_HIDER  : 2'd0;

    always @(posedge clk) begin
        s_start      <= 1'b0;
        s_restart    <= 1'b0;
        bot_place    <= 1'b0;
        free_count   <= free_count + 16'd1;
        playing_prev <= playing;
        if (s_reveal != 32'd0)
            s_reveal <= s_reveal - 32'd1;

        if (reset || !solo_mode) begin
            s_in_game <= 1'b0;
            s_armed   <= 1'b0;
            s_reveal  <= 32'd0;
        end else begin
            if (!my_ready && !s_in_game)
                s_armed <= 1'b1;
            if (!s_in_game && s_armed && my_ready && my_role != 2'd0) begin
                s_in_game <= 1'b1;
                s_start   <= 1'b1;
                s_seed    <= (free_count == 16'd0) ? 16'd1 : free_count;
            end
            if (ev_restart) begin
                s_in_game <= 1'b0;
                s_restart <= 1'b1;
                s_armed   <= 1'b0;
            end
            if (playing && !playing_prev)
                bot_place <= 1'b1;
            if (ev_ping)
                s_reveal <= REVEAL_CLKS;
        end
    end

    // ---------------- AI bot ----------------
    wire signed [15:0]b_x, b_y;
    wire [7:0]b_dir, b_health;
    wire b_frozen, b_stim;
    wire b_got_hit, b_got_frozen, b_got_pinged, b_stim_used, b_capsule;
    wire [7:0]b_damage, b_capsule_id;
    wire s_paused = s_in_game && my_paused;

    ai_bot #(.CLK_HZ(CLK_HZ), .MAP_W(MAP_W), .MAP_H(MAP_H)) bot (
        .clk             (clk),
        .reset           (reset || !solo_mode),
        .enable          (solo_mode && s_in_game && playing && !s_paused),
        .frame_tick      (frame_tick),
        .start_game      (bot_place),
        .map_bits        (map_bits),
        .bot_role        (bot_role),
        .difficulty      (difficulty),
        .spawn_x         (bot_spawn_x),
        .spawn_y         (bot_spawn_y),
        .player_x        (my_x),
        .player_y        (my_y),
        .ev_hit          (ev_hit && solo_mode),
        .hit_damage      (hit_damage),
        .ev_freeze       (ev_freeze && solo_mode),
        .ev_ping         (ev_ping && solo_mode),
        .capsule_valid   (capsule_valid),
        .capsule_cells   (capsule_cells),
        .bot_x           (b_x),
        .bot_y           (b_y),
        .bot_dir         (b_dir),
        .bot_health      (b_health),
        .bot_frozen      (b_frozen),
        .bot_stim        (b_stim),
        .got_hit         (b_got_hit),
        .got_hit_damage  (b_damage),
        .got_frozen      (b_got_frozen),
        .got_pinged      (b_got_pinged),
        .peer_stim_used  (b_stim_used),
        .peer_capsule    (b_capsule),
        .peer_capsule_id (b_capsule_id),
        .can_see_player  ()
    );

    // ---------------- Choose the source ----------------
    assign peer_role       = solo_mode ? bot_role     : l_peer_role;
    assign peer_ready      = solo_mode ? 1'b1         : l_peer_ready;
    assign role_conflict   = solo_mode ? 1'b0         : l_conflict;
    assign in_game         = solo_mode ? s_in_game    : l_in_game;
    assign start_game      = solo_mode ? s_start      : l_start;
    assign game_seed       = solo_mode ? s_seed       : l_seed;

    assign peer_x          = solo_mode ? b_x          : l_x;
    assign peer_y          = solo_mode ? b_y          : l_y;
    assign peer_dir        = solo_mode ? b_dir        : l_dir;
    assign peer_health     = solo_mode ? b_health     : l_health;
    assign peer_paused     = solo_mode ? 1'b0         : l_paused;
    assign peer_frozen     = solo_mode ? b_frozen     : l_frozen;
    assign peer_stim       = solo_mode ? b_stim       : l_stim;
    assign game_paused     = solo_mode ? s_paused     : l_game_paused;

    assign got_hit         = solo_mode ? b_got_hit    : l_got_hit;
    assign got_hit_damage  = solo_mode ? b_damage     : l_damage;
    assign got_frozen      = solo_mode ? b_got_frozen : l_got_frozen;
    assign got_pinged      = solo_mode ? b_got_pinged : l_got_pinged;
    assign peer_stim_used  = solo_mode ? b_stim_used  : l_stim_used;
    assign peer_capsule    = solo_mode ? b_capsule    : l_capsule;
    assign peer_capsule_id = solo_mode ? b_capsule_id : l_capsule_id;
    assign restart_game    = solo_mode ? s_restart    : l_restart;

    assign reveal_active   = solo_mode ? (s_reveal != 32'd0) : l_reveal;
    assign reveal_x        = peer_x;
    assign reveal_y        = peer_y;
endmodule
