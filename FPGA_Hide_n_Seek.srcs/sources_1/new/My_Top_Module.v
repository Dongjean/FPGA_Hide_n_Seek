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
// OLED #1 (3D view) on JB, OLED #2 (minimap + HUD) on JXADC.
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
    output [7:0]JXADC,
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
    wire peer_flash;                        // other board's Hider used a Flashbang
    wire signed [15:0]reveal_x, reveal_y;

    // ================= Andrew: world generation =================
    // A new maze is built on every start_game, from the shared game_seed, so both
    // boards (or the player and the bot) get the same map.  A boot maze (seed ACE1)
    // is built once after power-up/reset so the screens are never all wall while
    // the players pick roles.  Each new maze places this player on a corner
    // (load_pos -> player_movement) and gives the bot the opposite corner.
    wire is_hider = !sw[13];                 // sw13: 1 = Seeker (Jian Bin's role switch)

    reg [2:0] boot_cnt = 3'd0;
    reg       boot_start = 1'b0;
    always @(posedge oled_clk) begin
        if (reset_game) begin
            boot_cnt   <= 3'd0;
            boot_start <= 1'b0;
        end else begin
            boot_start <= (boot_cnt == 3'd3);          // exactly one pulse
            if (boot_cnt != 3'd4) boot_cnt <= boot_cnt + 3'd1;
        end
    end

    wire        gen_start = start_game | boot_start;
    wire [15:0] gen_seed  = start_game ? game_seed : 16'hACE1;

    wire [199:0]       cells;
    wire [99:0]        map_bits;
    wire               load_pos;
    wire signed [15:0] load_x, load_y;
    wire [7:0]         load_dir;
    wire signed [15:0] bot_spawn_x, bot_spawn_y;
    wire               bump;                 // player walked into a solid cell -> portal_ctrl
    wire [3:0]         bump_cx, bump_cy;
    wire               map_done;
    wire [6:0]         hider_cell, seeker_cell;

    // world_top write ports (portal_ctrl > capsule_ctrl)
    wire               portal_we, portal_wgrant, cap_we, cap_wgrant;
    wire [7:0]         portal_waddr, cap_waddr;
    wire [1:0]         portal_wdata, cap_wdata;

    // portal_ctrl -> capsule_ctrl / player_movement
    wire [1:0]         pair_valid;
    wire [27:0]        exit_cells;
    wire               tp_load;
    wire signed [15:0] tp_x, tp_y;
    wire [7:0]         tp_dir;

    // capsule_ctrl <-> multiplayer_core / minimap / timer
    wire [3:0]         capsule_valid;
    wire [31:0]        capsule_cells;
    wire               ev_capsule, peer_capsule, time_penalty;
    wire [7:0]         capsule_id, peer_capsule_id;
    wire [1:0]         cap_fade_valid;
    wire [6:0]         cap_fade_cell0, cap_fade_cell1;

    // timer + ammo/uses (placeholders until Isaac's timer / the team's counters)
    wire [8:0]         seconds_left;
    wire [2:0]         ammo;
    wire [1:0]         uses;
    wire               fired_gun;

    world_top #(.LOOP_WALLS(3)) world (
        .clk           (oled_clk),
        .reset         (reset_game),
        .start         (gen_start),
        .seed          (gen_seed),
        .is_hider      (is_hider),
        .respawn       (1'b0),               // game logic later: pulse on the countdown "go"
        .portal_we     (portal_we),          // portal_ctrl
        .portal_waddr  (portal_waddr),
        .portal_wdata  (portal_wdata),
        .portal_wgrant (portal_wgrant),
        .cap_we        (cap_we),             // capsule_ctrl
        .cap_waddr     (cap_waddr),
        .cap_wdata     (cap_wdata),
        .cap_wgrant    (cap_wgrant),
        .rd_x          (4'd0),
        .rd_y          (4'd0),
        .rd_type       (),
        .cells         (cells),
        .map_bits      (map_bits),
        .gen_busy      (),
        .map_ready     (),
        .map_done      (map_done),
        .load_pos      (load_pos),
        .load_x        (load_x),
        .load_y        (load_y),
        .load_dir      (load_dir),
        .opp_x         (),
        .opp_y         (),
        .opp_dir       (),
        .opp_spawn_x   (bot_spawn_x),        // valid 1 cycle after start: in time for the bot
        .opp_spawn_y   (bot_spawn_y),
        .hider_cell    (hider_cell),
        .seeker_cell   (seeker_cell)
    );

    // ---- Warp Portals: placed after each maze, teleport on bump ----
    portal_ctrl portals (
        .clk           (oled_clk),
        .reset         (reset_game),
        .start         (gen_start),
        .seed          (gen_seed),
        .map_done      (map_done),
        .cells         (cells),
        .hider_cell    (hider_cell),
        .seeker_cell   (seeker_cell),
        .portal_we     (portal_we),
        .portal_waddr  (portal_waddr),
        .portal_wdata  (portal_wdata),
        .portal_wgrant (portal_wgrant),
        .bump          (bump),
        .bump_cx       (bump_cx),
        .bump_cy       (bump_cy),
        .game_paused   (game_paused),
        .tp_load       (tp_load),
        .tp_x          (tp_x),
        .tp_y          (tp_y),
        .tp_dir        (tp_dir),
        .portals_ready (),
        .pair_valid    (pair_valid),
        .portal_cells  (),
        .exit_cells    (exit_cells)
    );

    // ---- Time Capsules: spawn every 40 s, the Hider walks over one to take time off ----
    capsule_ctrl capsules (
        .clk             (oled_clk),
        .reset           (reset_game),
        .start           (gen_start),
        .seed            (gen_seed),
        .in_game         (in_game),
        .game_paused     (game_paused),
        .solo_mode       (sw[12]),           // player-distance rule only vs the bot
        .cells           (cells),
        .hider_cell      (hider_cell),
        .seeker_cell     (seeker_cell),
        .exit_cells      (exit_cells),
        .pair_valid      (pair_valid),
        .cap_we          (cap_we),
        .cap_waddr       (cap_waddr),
        .cap_wdata       (cap_wdata),
        .cap_wgrant      (cap_wgrant),
        .player_x        (player_x),
        .player_y        (player_y),
        .op_x            (op_x),
        .op_y            (op_y),
        .is_hider        (is_hider),
        .ev_capsule      (ev_capsule),
        .capsule_id      (capsule_id),
        .peer_capsule    (peer_capsule),
        .peer_capsule_id (peer_capsule_id),
        .capsule_valid   (capsule_valid),
        .capsule_cells   (capsule_cells),
        .time_penalty    (time_penalty),
        .cap_fade_valid  (cap_fade_valid),
        .cap_fade_cell0  (cap_fade_cell0),
        .cap_fade_cell1  (cap_fade_cell1),
        .game_sec        ()
    );

    // ---- 5:00 match timer (PLACEHOLDER: replace with Isaac's, same ports) ----
    match_timer timer (
        .clk               (oled_clk),
        .reset             (reset_game),
        .start             (start_game),
        .in_game           (in_game),
        .game_paused       (game_paused),
        .time_penalty      (time_penalty),
        .game_seconds_left (seconds_left),
        .time_up           ()                 // game logic (Dongjin): Hider wins at 0
    );

    // ---- Ammo / item uses (PLACEHOLDER until the team decides the owner) ----
    // Shown on the HUD and used to block capsule shots when empty.  Jian Bin's
    // multiplayer_core does not check them yet, so player shots still work at 0.
    item_counters items (
        .clk          (oled_clk),
        .reset        (reset_game),
        .start        (start_game),
        .in_game      (in_game),
        .game_paused  (game_paused),
        .shoot        (shoot),
        .weapon_sel   (weapon_sel),
        .can_move     (can_move),
        .ammo         (ammo),
        .uses         (uses),
        .has_ammo     (),
        .has_use      (),
        .fired_gun    (fired_gun),
        .used_item    ()
    );

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
        .bot_spawn_x     (bot_spawn_x),
        .bot_spawn_y     (bot_spawn_y),
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
        .peer_stim_used  (peer_flash),       // the Hider used a Flashbang (Stim event reused)
        .capsule_valid   (capsule_valid),    // the bot (Hider) can see and shoot capsules
        .capsule_cells   (capsule_cells),
        .ev_capsule      (ev_capsule),       // I shot a capsule -> other board
        .capsule_id      (capsule_id),
        .peer_capsule    (peer_capsule),     // other board / bot shot one -> capsule_ctrl
        .peer_capsule_id (peer_capsule_id),
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
    // load_pos (from world_top) places the player on its corner whenever a maze finishes;
    // tp_load (portal_ctrl) teleports.  The spawn wins if both happen in one cycle.
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
        .load_pos     (load_pos | tp_load),
        .load_x       (load_pos ? load_x   : tp_x),
        .load_y       (load_pos ? load_y   : tp_y),
        .load_dir     (load_pos ? load_dir : tp_dir),
        .bump         (bump),
        .bump_cx      (bump_cx),
        .bump_cy      (bump_cy),
        .player_x     (player_x),
        .player_y     (player_y),
        .view_dir     (view_dir)
    );

    // ================= Andrew: OLED #2 on JXADC (minimap + HUD) =================
    wire        frame_begin2;
    wire        sending_pixels2;
    wire        sample_pixel2;
    wire [12:0] pixel_index2;
    wire [15:0] pixel_data2;
    wire [15:0] minimap_pixel;
    wire        in_minimap;

    Oled_Display oled_display2 (
        .clk            (oled_clk),
        .reset          (reset_game),
        .frame_begin    (frame_begin2),
        .sending_pixels (sending_pixels2),
        .sample_pixel   (sample_pixel2),
        .pixel_index    (pixel_index2),
        .pixel_data     (pixel_data2),
        .cs             (JXADC[0]),
        .sdin           (JXADC[1]),
        .sclk           (JXADC[3]),
        .d_cn           (JXADC[4]),
        .resn           (JXADC[5]),
        .vccen          (JXADC[6]),
        .pmoden         (JXADC[7])
    );
    assign JXADC[2] = 1'b0;

    // OLED #2 sits on JXADC, which faces the opposite way to JB, so the screen is
    // turned 180 degrees: pixel i of the screen shows what the renderers draw for
    // pixel 6143 - i (6143 = 96*64 - 1 reverses both x and y).
    wire [12:0] pix2 = 13'd6143 - pixel_index2;

    // Flashbang: on the Seeker's minimap the Hider's dot blinks 1 s, then is
    // hidden 5 s (dot and Pinger blip).  Only the Seeker's board reacts.
    wire opp_visible;
    flashbang_ctrl flashbang (
        .clk          (oled_clk),
        .reset        (reset_game),
        .start        (start_game),
        .game_paused  (game_paused),
        .flash        (peer_flash && !is_hider),
        .opp_visible  (opp_visible),
        .flash_active ()
    );

    minimap_render minimap (
        .clk            (oled_clk),
        .reset          (reset_game),
        .pixel_index    (pix2),
        .cells          (cells),
        .player_x       (player_x),
        .player_y       (player_y),
        .view_dir       (view_dir),
        .pinger_active  (reveal_active && opp_visible),  // Pinger blip, unless flashbanged
        .rx_hider_x     (reveal_x),
        .rx_hider_y     (reveal_y),
        .opp_show       (in_game && opp_visible),        // opponent dot, unless flashbanged
        .opp_x          (op_x),              // other board's player, or the bot in solo
        .opp_y          (op_y),
        .cap_fade_valid (cap_fade_valid),    // capsule blinks in its last 5 s
        .cap_fade_cell0 (cap_fade_cell0),
        .cap_fade_cell1 (cap_fade_cell1),
        .pixel_data     (minimap_pixel),
        .in_minimap     (in_minimap)
    );

    // Right strip (x = 64..95): weapon, ammo/uses, HP, time
    wire [15:0] hud_pixel;
    hud_render hud (
        .clk          (oled_clk),
        .reset        (reset_game),
        .pixel_index  (pix2),
        .is_hider     (is_hider),
        .weapon_sel   (weapon_sel),
        .ammo         (ammo),
        .uses         (uses),
        .health       (my_health),
        .seconds_left (seconds_left),
        .pixel_data   (hud_pixel),
        .in_hud       ()
    );

    assign pixel_data2 = in_minimap ? minimap_pixel : hud_pixel;

endmodule