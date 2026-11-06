`timescale 1ns / 1ps
// The other player, whoever it is. The game connects to this one module:
//
//   solo_mode = 0: the other player is on the second Basys3 board (multiplayer_link)
//   solo_mode = 1: the other player is the AI bot (ai_bot)
//
// my_mode (0 = choosing, 1 = singleplayer, 2 = multiplayer) is always sent to the
// other board, even in solo mode, so it knows when Multiplayer is unavailable.
//
// Both sides use exactly the same signals, so the rest of the game works the same
// in both modes: it sends this player's state and events in, and gets the other
// player's state and events out.
//
// In solo mode the start-up is local: as soon as the player confirms a role on
// the main menu, the game starts with a random seed and the bot takes the other
// role. The bot is placed at bot_spawn once the match is running AND the new map
// is fully generated (map_ready), and only plays from then on. Game over and the
// return to the menu are also local, and the bot's hits, freezes and Flashbangs
// are turned into player-state changes for this player's FSM. The bot takes Time
// Capsules by standing on them (capsule_ctrl sees that), so peer_capsule is never
// pulsed in solo mode.

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
    input map_ready,                     // world_top: the map for this match is finished
    input signed [15:0]bot_spawn_x,      // where the other player starts
    input signed [15:0]bot_spawn_y,
    input [3:0]capsule_valid,
    input [31:0]capsule_cells,           // {y, x} per capsule

    // Main menu
    input [1:0]my_mode,                  // 0 = choosing, 1 = singleplayer, 2 = multiplayer
    output [1:0]peer_mode,               // the other board's my_mode (0 while the link is down)
    input [1:0]my_pick,                  // role this player picked: 1 = Hider, 2 = Seeker
    input my_confirmed,                  // ... and confirmed
    output [1:0]peer_pick,               // the other player's pick (second board only)
    output peer_confirmed,
    output is_master,
    output master_decided,
    output [1:0]my_role,                 // this player's role in the match
    output in_game,
    output start_game,
    output [15:0]game_seed,

    // End of match
    input ev_game_over,
    input [1:0]winner_in,                // 1 = Hider won, 2 = Seeker won
    input ev_menu,
    output game_over,
    output [1:0]winner,

    // This player
    input signed [15:0]my_x,
    input signed [15:0]my_y,
    input [7:0]my_dir,
    input [7:0]my_health,
    input my_paused,
    input my_frozen,
    input my_stim,
    input [1:0]my_hand,
 

    // The other player
    output signed [15:0]peer_x,
    output signed [15:0]peer_y,
    output [7:0]peer_dir,
    output [7:0]peer_health,
    output peer_paused,
    output peer_frozen,
    output peer_stim,
    output [1:0]peer_hand,               // the bot always has its gun ready
    output link_up,                      // board-to-board link status (multiplayer)
    output game_paused,

    // Events this player causes
    input ev_hit,
    input [7:0]hit_damage,
    input ev_freeze,
    input ev_ping,
    input ev_flash,
    input ev_capsule,
    input [7:0]capsule_id,
    input ev_restart,
    input state_change_valid,            // put the other player's FSM into player_state
    input [1:0]player_state,

    // Events the other player causes
    output got_hit,
    output [7:0]got_hit_damage,
    output got_frozen,
    output got_pinged,
    output peer_flash_used,
    output peer_capsule,
    output [7:0]peer_capsule_id,
    output restart_game,
    output got_state_change,             // put my FSM into got_player_state
    output [1:0]got_player_state,

    // Radio Pinger reveal (this player is the Seeker)
    output reveal_active,
    output signed [15:0]reveal_x,
    output signed [15:0]reveal_y
);
    localparam [1:0]ROLE_HIDER  = 2'd1;
    localparam [1:0]ROLE_SEEKER = 2'd2;
    localparam integer REVEAL_CLKS = REVEAL_MS * (CLK_HZ / 1000);

    // ---------------- Second board ----------------
    wire [1:0]l_peer_pick, l_role, l_winner, l_pstate;
    wire l_peer_confirmed, l_master, l_decided, l_in_game, l_start, l_game_over, l_state_change;
    wire [15:0]l_seed;
    wire signed [15:0]l_x, l_y;
    wire [7:0]l_dir, l_health;
    wire l_paused, l_frozen, l_stim, l_game_paused;
    wire [1:0]l_hand;
    wire l_got_hit, l_got_frozen, l_got_pinged, l_stim_used, l_capsule, l_restart;
    wire l_paused, l_frozen, l_game_paused;
    wire l_got_hit, l_got_frozen, l_got_pinged, l_flash_used, l_capsule, l_restart;
    wire [7:0]l_damage, l_capsule_id;
    wire l_reveal;

    multiplayer_link #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .REVEAL_MS(REVEAL_MS)) link (
        .clk            (clk),
        .reset          (reset),
        .link_rx        (link_rx),
        .link_tx        (link_tx),
        .my_mode        (my_mode),
        .peer_mode      (peer_mode),
        .my_pick        (my_pick),
        .my_confirmed   (my_confirmed && !solo_mode),
        .peer_pick      (l_peer_pick),
        .peer_confirmed (l_peer_confirmed),
        .is_master      (l_master),
        .master_decided (l_decided),
        .my_role        (l_role),
        .in_game        (l_in_game),
        .start_game     (l_start),
        .game_seed      (l_seed),
        .ev_game_over   (ev_game_over && !solo_mode),
        .winner_in      (winner_in),
        .ev_menu        (ev_menu && !solo_mode),
        .game_over      (l_game_over),
        .winner         (l_winner),
        .my_x           (my_x),
        .my_y           (my_y),
        .my_dir         (my_dir),
        .my_health      (my_health),
        .my_paused      (my_paused),
        .my_frozen      (my_frozen),
        .my_stim        (my_stim),
        .my_hand        (my_hand),
        .peer_hand      (l_hand),
        .peer_x         (l_x),
        .peer_y         (l_y),
        .peer_dir       (l_dir),
        .peer_health    (l_health),
        .peer_paused    (l_paused),
        .peer_frozen    (l_frozen),
        .peer_in_game   (),
        .link_up        (link_up),
        .game_paused    (l_game_paused),
        .ev_hit         (ev_hit && !solo_mode),
        .hit_damage     (hit_damage),
        .ev_freeze      (ev_freeze && !solo_mode),
        .ev_ping        (ev_ping && !solo_mode),
        .ev_flash       (ev_flash && !solo_mode),
        .ev_capsule     (ev_capsule && !solo_mode),
        .capsule_id     (capsule_id),
        .ev_restart     (ev_restart && !solo_mode),
        .state_change_valid (state_change_valid && !solo_mode),
        .player_state   (player_state),
        .got_hit        (l_got_hit),
        .got_hit_damage (l_damage),
        .got_frozen     (l_got_frozen),
        .got_pinged     (l_got_pinged),
        .peer_flash_used(l_flash_used),
        .peer_capsule   (l_capsule),
        .peer_capsule_id(l_capsule_id),
        .restart_game   (l_restart),
        .got_state_change (l_state_change),
        .got_player_state (l_pstate),
        .reveal_active  (l_reveal),
        .reveal_x       (),
        .reveal_y       (),
        .rx_error_count (),
        .ev_overflow    ()
    );

    // ---------------- Solo start-up ----------------
    reg s_in_game = 1'b0;
    reg s_start = 1'b0;
    reg s_start_next = 1'b0;             // s_role is set: start on the next clock
    reg s_restart = 1'b0;
    reg [15:0]s_seed = 16'd1;
    reg [1:0]s_role = ROLE_HIDER;
    reg s_game_over = 1'b0;
    reg [1:0]s_winner = 2'd0;
    reg [15:0]free_count = 16'd0;
    reg playing_prev = 1'b0;
    reg bot_place = 1'b0;
    reg bot_waiting = 1'b0;              // match started, waiting for the map
    reg bot_live = 1'b0;                 // placed on the new map: the bot may play
    reg [31:0]s_reveal = 32'd0;

    wire [1:0]bot_role = (s_role == ROLE_HIDER) ? ROLE_SEEKER : ROLE_HIDER;

    always @(posedge clk) begin
        s_start      <= 1'b0;
        s_restart    <= 1'b0;
        bot_place    <= 1'b0;
        free_count   <= free_count + 16'd1;
        playing_prev <= playing;
        if (s_reveal != 32'd0)
            s_reveal <= s_reveal - 32'd1;

        if (reset || !solo_mode) begin
            s_in_game    <= 1'b0;
            s_start_next <= 1'b0;
            s_game_over  <= 1'b0;
            s_reveal     <= 32'd0;
            bot_waiting  <= 1'b0;
            bot_live     <= 1'b0;
        end else begin
            // Confirming a role on the menu starts the match straight away
            if (s_start_next) begin
                s_start_next <= 1'b0;
                s_in_game    <= 1'b1;
                s_start      <= 1'b1;
            end else if (!s_in_game && !s_game_over && my_confirmed && my_pick != 2'd0) begin
                s_role       <= my_pick;
                s_seed       <= (free_count == 16'd0) ? 16'd1 : free_count;
                s_start_next <= 1'b1;
            end
            if (ev_restart) begin
                s_in_game <= 1'b0;
                s_restart <= 1'b1;
            end
            if (ev_game_over && s_in_game) begin
                s_in_game   <= 1'b0;
                s_game_over <= 1'b1;
                s_winner    <= winner_in;
            end
            if (ev_menu && s_game_over)
                s_game_over <= 1'b0;
            // Place the bot once the new map is finished (map_ready drops at the
            // start and rises when the map is done)
            if (playing && !playing_prev) begin
                bot_waiting <= 1'b1;
                bot_live    <= 1'b0;
            end else if (bot_waiting && map_ready) begin
                bot_waiting <= 1'b0;
                bot_place   <= 1'b1;
                bot_live    <= 1'b1;
            end
            if (!s_in_game)
                bot_live <= 1'b0;
            if (ev_ping)
                s_reveal <= REVEAL_CLKS;
        end
    end

    // ---------------- AI bot ----------------
    wire signed [15:0]b_x, b_y;
    wire [7:0]b_dir, b_health;
    wire b_frozen;
    wire b_got_hit, b_got_frozen, b_got_pinged, b_flash_used;
    wire [7:0]b_damage;
    wire s_paused = s_in_game && my_paused;

    ai_bot #(.CLK_HZ(CLK_HZ), .MAP_W(MAP_W), .MAP_H(MAP_H)) bot (
        .clk             (clk),
        .reset           (reset || !solo_mode),
        .enable          (solo_mode && s_in_game && playing && bot_live && !s_paused),
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
        .ev_flash        (ev_flash && solo_mode),
        .capsule_valid   (capsule_valid),
        .capsule_cells   (capsule_cells),
        .bot_x           (b_x),
        .bot_y           (b_y),
        .bot_dir         (b_dir),
        .bot_health      (b_health),
        .bot_frozen      (b_frozen),
        .bot_holding     (),
        .got_hit         (b_got_hit),
        .got_hit_damage  (b_damage),
        .got_frozen      (b_got_frozen),
        .got_pinged      (b_got_pinged),
        .peer_flash_used (b_flash_used),
        .can_see_player  ()
    );

    // The bot's actions, as player-state changes for this player:
    // Freeze Gun -> stunned (1), Seeking Gun hit -> attacked (3), Flashbang -> flashed (2)
    wire b_state_change = b_got_frozen || b_got_hit || b_flash_used;
    wire [1:0]b_pstate  = b_got_frozen ? 2'd1 : b_got_hit ? 2'd3 : 2'd2;

    // ---------------- Choose the source ----------------
    assign peer_pick       = solo_mode ? 2'd0         : l_peer_pick;
    assign peer_confirmed  = solo_mode ? 1'b0         : l_peer_confirmed;
    assign is_master       = solo_mode ? 1'b1         : l_master;
    assign master_decided  = solo_mode ? 1'b1         : l_decided;
    assign my_role         = solo_mode ? s_role       : l_role;
    assign in_game         = solo_mode ? s_in_game    : l_in_game;
    assign start_game      = solo_mode ? s_start      : l_start;
    assign game_seed       = solo_mode ? s_seed       : l_seed;
    assign game_over       = solo_mode ? s_game_over  : l_game_over;
    assign winner          = solo_mode ? s_winner     : l_winner;

    assign peer_x          = solo_mode ? b_x          : l_x;
    assign peer_y          = solo_mode ? b_y          : l_y;
    assign peer_dir        = solo_mode ? b_dir        : l_dir;
    assign peer_health     = solo_mode ? b_health     : l_health;
    assign peer_paused     = solo_mode ? 1'b0         : l_paused;
    assign peer_frozen     = solo_mode ? b_frozen     : l_frozen;
    assign peer_stim       = solo_mode ? b_stim       : l_stim;
    assign peer_hand       = solo_mode ? 2'd1         : l_hand;
    assign game_paused     = solo_mode ? s_paused     : l_game_paused;

    assign got_hit         = solo_mode ? b_got_hit    : l_got_hit;
    assign got_hit_damage  = solo_mode ? b_damage     : l_damage;
    assign got_frozen      = solo_mode ? b_got_frozen : l_got_frozen;
    assign got_pinged      = solo_mode ? b_got_pinged : l_got_pinged;
    assign peer_flash_used = solo_mode ? b_flash_used : l_flash_used;
    assign peer_capsule    = solo_mode ? 1'b0         : l_capsule;
    assign peer_capsule_id = solo_mode ? 8'd0         : l_capsule_id;
    assign restart_game    = solo_mode ? s_restart    : l_restart;
    assign got_state_change = solo_mode ? b_state_change : l_state_change;
    assign got_player_state = solo_mode ? b_pstate       : l_pstate;

    assign reveal_active   = solo_mode ? (s_reveal != 32'd0) : l_reveal;
    assign reveal_x        = peer_x;
    assign reveal_y        = peer_y;
endmodule
