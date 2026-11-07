`timescale 1ns / 1ps
// Computer opponent for single-player mode. It plays the role the human did not
// pick, and talks to the game through the same signals as the other board does
// in multiplayer_link (position, health, flags and event pulses), so the game cannot
// tell whether it is playing a person or the bot.
//
// Every frame the bot:
//   1. Looks: line-of-sight check to the player (32 steps along the line, blocked
//      by any wall) within its sight range; as Hider it also looks for capsules.
//   2. Decides where to go:
//        Seeker: chase the player if seen, else head to where it last saw them;
//                if it loses them for a while it uses the Radio Pinger (3 uses)
//                to find them; otherwise it patrols random open cells.
//        Hider:  flee from the player when seen or after being pinged; otherwise
//                wander to random open cells.
//   3. Plans: runs the BFS engine (chase = search from the goal and step to a
//      closer neighbour; flee = search from the player and step to a farther one).
//   4. Moves one step towards the next cell centre (so it never cuts through a wall
//      corner), at a speed set by the difficulty.
//   5. Acts once it has seen the player for its reaction time:
//        Seeker: fires the Seeking Gun (10 bullets, no recharge); each shot hits
//                with the difficulty's accuracy.
//        Hider:  fires the Freeze Gun (5 bullets) when the Seeker is within 3 cells.
//      As a reflex (no reaction delay) the Hider throws a Flashbang (5 uses) when
//      the Seeker comes into view within 2 cells.
//   Time Capsules: the Hider walks to a capsule it can see; capsule_ctrl takes it
//   when the bot stands on it. The Seeker walks past capsules.
//   Flashbanged (ev_flash, the player is the Hider): the bot Seeker cannot see for
//   FLASH_MS and forgets where the player was.
//
// Difficulty (2 bits):          easy   medium  hard   expert
//   speed (1/256 cell/frame)      6      10     14      16
//   reaction time (ms)          1000     600    350     200
//     + random extra (ms)      0-1023  0-511  0-255   0-127
//   hit chance                   35%     60%    80%     92%
//   sight range (cells)            4       6      8      10
//   pings after lost for (s)      20      12      6       4
//     + random extra (s)         0-16    0-8    0-4     0-2
//   random pause (about every)    6 s     9 s   17 s   never   (0.25-0.75 s, while it
//                                                               cannot see the player)
// The random numbers come from the bot's own 16-bit LFSR, which steps every clock.

module ai_bot
#(
    parameter integer CLK_HZ       = 6_250_000,
    parameter integer MAP_W        = 10,
    parameter integer MAP_H        = 10,
    parameter [7:0]START_HEALTH    = 8'd3,
    parameter [7:0]SHOT_DAMAGE     = 8'd1,
    parameter integer FREEZE_MS    = 3000,       // same as player_state_FSM STUN_MS
    parameter integer FLASH_MS     = 2000,       // same as player_state_FSM FLASH_MS
    parameter integer COOLDOWN_MS  = 800,
    parameter integer ALERT_MS     = 3000,
    parameter [3:0]SEEKER_AMMO     = 4'd10,      // Seeking Gun bullets
    parameter [2:0]SEEKER_PINGS    = 3'd5,       // Radio Pinger uses
    parameter [3:0]HIDER_AMMO      = 4'd5,       // Freeze Gun bullets
    parameter [2:0]HIDER_FLASHES   = 3'd5        // Flashbang uses
)
(
    input clk,
    input reset,
    input enable,                  // single-player game running and not paused
    input frame_tick,
    input start_game,              // place the bot and refill health and ammo
    input [MAP_W*MAP_H-1:0]map_bits,
    input [1:0]bot_role,           // 1 = Hider, 2 = Seeker
    input [1:0]difficulty,
    input signed [15:0]spawn_x,    // Q8.8
    input signed [15:0]spawn_y,

    // The human player
    input signed [15:0]player_x,
    input signed [15:0]player_y,

    // Events from the human (the same pulses multiplayer_link would send to the other board)
    input ev_hit,
    input [7:0]hit_damage,
    input ev_freeze,
    input ev_ping,
    input ev_flash,                // the player (Hider) threw a Flashbang at the bot

    // Time Capsules: up to 4, each cell as {y[3:0], x[3:0]}
    input [3:0]capsule_valid,
    input [31:0]capsule_cells,

    // The bot, as the game sees the other player
    output reg signed [15:0]bot_x = 16'sd0,
    output reg signed [15:0]bot_y = 16'sd0,
    output reg [7:0]bot_dir = 8'd0,
    output reg [7:0]bot_health = 8'd0,
    output bot_frozen,
    output [1:0]bot_holding,       // {empty, 0}: the bot always holds its gun

    // Events the bot causes (the same pulses multiplayer_link would deliver)
    output reg got_hit = 1'b0,
    output reg [7:0]got_hit_damage = 8'd0,
    output reg got_frozen = 1'b0,
    output reg got_pinged = 1'b0,
    output reg peer_flash_used = 1'b0,

    output reg can_see_player = 1'b0       // for debugging and the demo
);
    localparam [1:0]ROLE_HIDER  = 2'd1;
    localparam [1:0]ROLE_SEEKER = 2'd2;
    localparam integer CELLS = MAP_W * MAP_H;
    localparam integer CLKS_PER_MS = CLK_HZ / 1000;
    localparam [7:0]FAR = 8'd255;

    // ---------------- Difficulty table ----------------
    reg [7:0]speed;
    reg [15:0]reaction_ms;
    reg [7:0]accuracy;          // out of 256
    reg [3:0]sight_cells;
    reg [15:0]ping_after_ms;
    reg [9:0]react_mask;        // random extra reaction time: lfsr AND this mask (ms)
    reg [13:0]ping_mask;        // random extra wait before pinging (ms)
    reg [1:0]pause_chance;      // random pause: chance per frame, out of 1024
    always @(*) begin
        case (difficulty)
            2'd0: begin speed = 8'd6;  reaction_ms = 16'd1000; accuracy = 8'd90;  sight_cells = 4'd4;  ping_after_ms = 16'd20000;
                        react_mask = 10'h3FF; ping_mask = 14'h3FFF; pause_chance = 2'd3; end
            2'd1: begin speed = 8'd10; reaction_ms = 16'd600;  accuracy = 8'd154; sight_cells = 4'd6;  ping_after_ms = 16'd12000;
                        react_mask = 10'h1FF; ping_mask = 14'h1FFF; pause_chance = 2'd2; end
            2'd2: begin speed = 8'd14; reaction_ms = 16'd350;  accuracy = 8'd205; sight_cells = 4'd8;  ping_after_ms = 16'd6000;
                        react_mask = 10'h0FF; ping_mask = 14'h0FFF; pause_chance = 2'd1; end
            default: begin speed = 8'd16; reaction_ms = 16'd200; accuracy = 8'd236; sight_cells = 4'd10; ping_after_ms = 16'd4000;
                        react_mask = 10'h07F; ping_mask = 14'h07FF; pause_chance = 2'd0; end
        endcase
    end

    // ---------------- Helpers ----------------
    // The map is an argument so combinational uses re-evaluate when it changes
    function is_wall(input [CELLS-1:0]map, input [3:0]x, input [3:0]y);
        begin
            if (x >= MAP_W || y >= MAP_H)
                is_wall = 1'b1;
            else
                is_wall = map[CELLS - 1 - (y * MAP_W + x)];
        end
    endfunction

    // Direction from one point to another, in the team's units: 0 = north (-y),
    // 64 = east (+x), 128 = south, 192 = west. Accurate to 1/16 of a turn, using
    // only comparisons (no division or arctangent).
    function [7:0]direction_to(input signed [15:0]dx, input signed [15:0]dy);
        reg [19:0]ax, ay;
        reg [7:0]a;
        begin
            ax = (dx < 0) ? -dx : dx;
            ay = (dy < 0) ? -dy : dy;
            if      (ax * 5 < ay)     a = 8'd0;    // under 11.25 degrees from north/south
            else if (ax * 3 < ay * 2) a = 8'd16;   // under 33.75
            else if (ax * 2 < ay * 3) a = 8'd32;   // under 56.25
            else if (ax < ay * 5)     a = 8'd48;   // under 78.75
            else                      a = 8'd64;
            if (dx >= 0 && dy <= 0)      direction_to = a;            // north-east
            else if (dx >= 0)            direction_to = 8'd128 - a;   // south-east
            else if (dy > 0)             direction_to = 8'd128 + a;   // south-west
            else                         direction_to = 8'd0 - a;     // north-west
        end
    endfunction

    // ---------------- Random numbers ----------------
    reg [15:0]lfsr = 16'hACE1;
    always @(posedge clk)
        lfsr <= lfsr[0] ? ((lfsr >> 1) ^ 16'hB400) : (lfsr >> 1);

    // ---------------- Millisecond timers ----------------
    reg [31:0]ms_count = 32'd0;
    wire ms_tick = (ms_count == CLKS_PER_MS - 1);
    always @(posedge clk)
        ms_count <= ms_tick ? 32'd0 : ms_count + 32'd1;

    reg [15:0]frozen_ms = 16'd0;
    reg [15:0]blind_ms = 16'd0;      // flashbanged: cannot see the player
    reg [15:0]pause_ms = 16'd0;      // random pause: standing still
    reg [15:0]flash_cd_ms = 16'd0;   // Hider: time before the next Flashbang
    reg [9:0]react_extra = 10'd0;    // random extra reaction time for this sighting (ms)
    reg [13:0]ping_extra = 14'd0;    // random extra wait before the next ping (ms)
    reg [15:0]alert_ms = 16'd0;      // Hider: recently pinged, so it knows it is hunted
    reg [15:0]seen_ms = 16'd0;       // how long the player has been in view
    reg [15:0]lost_ms = 16'd0;       // Seeker: how long since the player was last seen
    reg [15:0]cooldown_ms = 16'd0;
    reg [3:0]ammo = 4'd10;
    reg [2:0]pings_left = 3'd5;
    reg [2:0]flashes_left = 3'd5;

    assign bot_frozen  = (frozen_ms != 16'd0);
    assign bot_holding = {(ammo == 4'd0), 1'b0};
    wire dead = (bot_health == 8'd0);

    // ---------------- Pathfinding engine ----------------
    reg bfs_start = 1'b0;
    reg [3:0]bfs_src_x, bfs_src_y;
    wire bfs_done;
    reg [3:0]q_x, q_y;
    wire [7:0]q_dist;

    bfs_pathfinder #(.MAP_W(MAP_W), .MAP_H(MAP_H)) planner (
        .clk        (clk),
        .reset      (reset),
        .map_bits   (map_bits),
        .start      (bfs_start),
        .src_x      (bfs_src_x),
        .src_y      (bfs_src_y),
        .busy       (),
        .done       (bfs_done),
        .query_x    (q_x),
        .query_y    (q_y),
        .query_dist (q_dist)
    );

    // ---------------- Per-frame state machine ----------------
    localparam [3:0]B_WAIT     = 4'd0;
    localparam [3:0]B_LOOK_P   = 4'd1;   // start line of sight to the player
    localparam [3:0]B_LOS      = 4'd2;   // stepping along a line
    localparam [3:0]B_LOOK_C   = 4'd3;   // next capsule to check
    localparam [3:0]B_DECIDE   = 4'd4;
    localparam [3:0]B_PLAN     = 4'd5;
    localparam [3:0]B_BFS      = 4'd6;
    localparam [3:0]B_NEIGH    = 4'd7;   // read distances of own cell and 4 neighbours
    localparam [3:0]B_MOVE     = 4'd8;
    localparam [3:0]B_ACT      = 4'd9;

    reg [3:0]state = B_WAIT;

    // Line of sight
    reg signed [15:0]los_x, los_y, los_step_x, los_step_y;
    reg [5:0]los_count;
    reg los_clear;
    reg los_for_capsule;
    reg [1:0]cap_index;
    reg cap_seen;
    reg [1:0]cap_seen_id;

    // Knowledge and goals
    reg known = 1'b0;                 // Seeker knows where to look
    reg [3:0]target_x, target_y;      // last known player cell
    reg wander_valid = 1'b0;
    reg [3:0]wander_x, wander_y;
    reg fleeing;
    reg bfs_valid = 1'b0;
    reg [3:0]last_src_x, last_src_y;

    // Movement
    reg signed [15:0]way_x, way_y;    // centre of the cell being moved to
    reg [2:0]n_index;
    reg [7:0]own_dist;
    reg [7:0]best_dist;
    reg [2:0]best_dir;                // 0-3 = up/right/down/left, 4 = stay

    wire [3:0]bot_cx = bot_x[11:8];
    wire [3:0]bot_cy = bot_y[11:8];
    wire [3:0]player_cx = player_x[11:8];
    wire [3:0]player_cy = player_y[11:8];
    wire at_waypoint = (bot_x == way_x) && (bot_y == way_y);

    wire signed [15:0]to_player_x = player_x - bot_x;
    wire signed [15:0]to_player_y = player_y - bot_y;
    wire [15:0]abs_px = (to_player_x < 0) ? -to_player_x : to_player_x;
    wire [15:0]abs_py = (to_player_y < 0) ? -to_player_y : to_player_y;
    wire [15:0]player_distance = abs_px + abs_py;     // Manhattan, Q8.8

    // Capsule being checked
    wire [7:0]cap_cell = capsule_cells[8 * cap_index +: 8];
    wire signed [15:0]cap_cx = {4'd0, cap_cell[3:0], 8'h80};
    wire signed [15:0]cap_cy = {4'd0, cap_cell[7:4], 8'h80};

    // Capsule the Hider saw this frame: {y, x}
    wire [7:0]seen_cap_cell = capsule_cells[8 * cap_seen_id +: 8];

    // Neighbour being read
    always @(*) begin
        q_x = bot_cx; q_y = bot_cy;
        case (n_index)
            3'd1: q_y = bot_cy - 4'd1;
            3'd2: q_x = bot_cx + 4'd1;
            3'd3: q_y = bot_cy + 4'd1;
            3'd4: q_x = bot_cx - 4'd1;
            default: ;
        endcase
    end

    reg [15:0]move_step;
    reg signed [15:0]diff;
    reg signed [15:0]next_x, next_y;
    
    // The bot may not get closer than 0.125 cell (16'd32) to the player
    // Same as player movement
    localparam [15:0] MIN_SEP = 16'd32;

    function opp_blocks (input signed [15:0]nx, input signed [15:0]ny,
                         input signed [15:0]cx, input signed [15:0]cy,
                         input signed [15:0]ox, input signed [15:0]oy);
        reg signed [15:0]ndx, ndy, odx, ody;
        reg [15:0]nd, od;
        begin
            ndx = nx - ox;  if (ndx < 0) ndx = -ndx;
            ndy = ny - oy;  if (ndy < 0) ndy = -ndy;
            odx = cx - ox;  if (odx < 0) odx = -odx;
            ody = cy - oy;  if (ody < 0) ody = -ody;
            nd = (ndx > ndy) ? ndx : ndy;
            od = (odx > ody) ? odx : ody;
            opp_blocks = (nd < MIN_SEP) && (nd < od);
        end
    endfunction
    reg [3:0]src_x, src_y;

    always @(posedge clk) begin
        bfs_start      <= 1'b0;
        got_hit        <= 1'b0;
        got_frozen     <= 1'b0;
        got_pinged     <= 1'b0;
        peer_flash_used <= 1'b0;

        if (reset || start_game) begin
            state        <= B_WAIT;
            bot_x        <= spawn_x;
            bot_y        <= spawn_y;
            way_x        <= {spawn_x[15:8], 8'h80};
            way_y        <= {spawn_y[15:8], 8'h80};
            bot_dir      <= 8'd0;
            bot_health   <= START_HEALTH;
            frozen_ms    <= 16'd0;
            blind_ms     <= 16'd0;
            pause_ms     <= 16'd0;
            flash_cd_ms  <= 16'd0;
            alert_ms     <= 16'd0;
            seen_ms      <= 16'd0;
            lost_ms      <= 16'd0;
            cooldown_ms  <= 16'd0;
            ammo         <= (bot_role == ROLE_SEEKER) ? SEEKER_AMMO : HIDER_AMMO;
            pings_left   <= SEEKER_PINGS;
            flashes_left <= HIDER_FLASHES;
            known        <= 1'b0;
            wander_valid <= 1'b0;
            bfs_valid    <= 1'b0;
            can_see_player <= 1'b0;
        end else if (enable) begin
            // ---------- Timers (paused when the game is paused) ----------
            if (ms_tick) begin
                if (frozen_ms != 0)   frozen_ms   <= frozen_ms - 16'd1;
                if (blind_ms != 0)    blind_ms    <= blind_ms - 16'd1;
                if (pause_ms != 0)    pause_ms    <= pause_ms - 16'd1;
                if (flash_cd_ms != 0) flash_cd_ms <= flash_cd_ms - 16'd1;
                if (alert_ms != 0)    alert_ms    <= alert_ms - 16'd1;
                if (cooldown_ms != 0) cooldown_ms <= cooldown_ms - 16'd1;
                if (can_see_player) begin
                    if (seen_ms != 16'hFFFF) seen_ms <= seen_ms + 16'd1;
                    lost_ms <= 16'd0;
                end else begin
                    seen_ms <= 16'd0;
                    if (lost_ms != 16'hFFFF) lost_ms <= lost_ms + 16'd1;
                end
            end

            // Random extras: re-rolled until they are needed, then held
            if (!can_see_player)
                react_extra <= lfsr[9:0] & react_mask;     // fixed once the player is seen
            if (can_see_player)
                ping_extra  <= lfsr[13:0] & ping_mask;     // fixed once the player is lost

            // ---------- Events from the human ----------
            if (ev_hit)
                bot_health <= (hit_damage >= bot_health) ? 8'd0 : bot_health - hit_damage;
            if (ev_freeze)
                frozen_ms <= FREEZE_MS;
            if (ev_ping)
                alert_ms <= ALERT_MS;
            if (ev_flash) begin
                blind_ms <= FLASH_MS;
                known    <= 1'b0;                          // forgets where the player was
            end

            // ---------- One pass per frame ----------
            case (state)
                B_WAIT: begin
                    if (frame_tick && !dead)
                        state <= B_LOOK_P;
                end

                // 1. Look for the player
                B_LOOK_P: begin
                    los_for_capsule <= 1'b0;
                    if (player_distance > {sight_cells, 8'h00}) begin
                        los_clear <= 1'b0;                // too far away to see
                        state <= B_LOOK_C;
                        can_see_player <= 1'b0;
                        cap_index <= 2'd0;
                        cap_seen  <= 1'b0;
                    end else begin
                        los_x      <= bot_x;
                        los_y      <= bot_y;
                        los_step_x <= to_player_x >>> 5;
                        los_step_y <= to_player_y >>> 5;
                        los_count  <= 6'd0;
                        los_clear  <= 1'b1;
                        state      <= B_LOS;
                    end
                end

                // Walk 32 steps along the line; any wall cell blocks the view
                B_LOS: begin
                    if (is_wall(map_bits, los_x[11:8], los_y[11:8]))
                        los_clear <= 1'b0;
                    los_x <= los_x + los_step_x;
                    los_y <= los_y + los_step_y;
                    los_count <= los_count + 6'd1;
                    if (los_count == 6'd31) begin
                        if (!los_for_capsule) begin
                            can_see_player <= los_clear && !is_wall(map_bits, los_x[11:8], los_y[11:8]) &&
                                              (blind_ms == 16'd0);
                            cap_index <= 2'd0;
                            cap_seen  <= 1'b0;
                        end else if (los_clear && !is_wall(map_bits, los_x[11:8], los_y[11:8]) && !cap_seen) begin
                            cap_seen    <= 1'b1;
                            cap_seen_id <= cap_index;
                        end
                        if (los_for_capsule)
                            cap_index <= cap_index + 2'd1;
                        state <= (los_for_capsule && cap_index == 2'd3) ? B_DECIDE : B_LOOK_C;
                        if (bot_role != ROLE_HIDER)
                            state <= B_DECIDE;           // only the Hider looks for capsules
                    end
                end

                // Hider: check each capsule in sight range
                B_LOOK_C: begin
                    if (bot_role != ROLE_HIDER) begin
                        state <= B_DECIDE;
                    end else if (!capsule_valid[cap_index] ||
                                 (((cap_cx > bot_x) ? cap_cx - bot_x : bot_x - cap_cx) +
                                  ((cap_cy > bot_y) ? cap_cy - bot_y : bot_y - cap_cy)) > {sight_cells, 8'h00}) begin
                        if (cap_index == 2'd3) state <= B_DECIDE;
                        cap_index <= cap_index + 2'd1;
                    end else begin
                        los_for_capsule <= 1'b1;
                        los_x      <= bot_x;
                        los_y      <= bot_y;
                        los_step_x <= (cap_cx - bot_x) >>> 5;
                        los_step_y <= (cap_cy - bot_y) >>> 5;
                        los_count  <= 6'd0;
                        los_clear  <= 1'b1;
                        state      <= B_LOS;
                    end
                end

                // 2. Decide where to go
                B_DECIDE: begin
                    fleeing <= 1'b0;
                    if (bot_role == ROLE_SEEKER) begin
                        if (can_see_player) begin
                            known    <= 1'b1;
                            target_x <= player_cx;
                            target_y <= player_cy;
                        end else if (pings_left != 3'd0 && lost_ms >= ping_after_ms + {2'd0, ping_extra} &&
                                     !bot_frozen && blind_ms == 16'd0) begin
                            // Radio Pinger: reveals the player's position
                            got_pinged <= 1'b1;
                            pings_left <= pings_left - 3'd1;
                            known      <= 1'b1;
                            target_x   <= player_cx;
                            target_y   <= player_cy;
                            lost_ms    <= 16'd0;
                        end else if (known && bot_cx == target_x && bot_cy == target_y && at_waypoint) begin
                            known <= 1'b0;   // reached the last known spot and nobody is here
                        end
                    end else begin
                        fleeing <= can_see_player || (alert_ms != 16'd0);
                    end

                    // Random pause (not while the player is in view)
                    if (!can_see_player && pause_ms == 16'd0 && lfsr[15:6] < {8'd0, pause_chance})
                        pause_ms <= 16'd250 + {7'd0, lfsr[8:0]};

                    // Hider: walk to a Time Capsule it can see, unless it is running away
                    if (bot_role == ROLE_HIDER && cap_seen && !can_see_player && alert_ms == 16'd0) begin
                        wander_x     <= seen_cap_cell[3:0];
                        wander_y     <= seen_cap_cell[7:4];
                        wander_valid <= 1'b1;
                    end else
                    // Pick a new random destination when there is nothing better to do
                    if (!wander_valid || (bot_cx == wander_x && bot_cy == wander_y && at_waypoint)) begin
                        if (lfsr[3:0] < MAP_W && lfsr[7:4] < MAP_H && !is_wall(map_bits, lfsr[3:0], lfsr[7:4])) begin
                            wander_x     <= lfsr[3:0];
                            wander_y     <= lfsr[7:4];
                            wander_valid <= 1'b1;
                        end else begin
                            wander_valid <= 1'b0;   // try again next frame
                        end
                    end
                    state <= B_PLAN;
                end

                // 3. Choose the search source; search again only if it changed
                B_PLAN: begin
                    if (fleeing) begin
                        src_x = player_cx;  src_y = player_cy;
                    end else if (bot_role == ROLE_SEEKER && known) begin
                        src_x = target_x;   src_y = target_y;
                    end else begin
                        src_x = wander_x;   src_y = wander_y;
                    end
                    n_index <= 3'd0;
                    if (bfs_valid && src_x == last_src_x && src_y == last_src_y) begin
                        state <= at_waypoint ? B_NEIGH : B_MOVE;   // table still valid
                    end else begin
                        bfs_src_x  <= src_x;
                        bfs_src_y  <= src_y;
                        last_src_x <= src_x;
                        last_src_y <= src_y;
                        bfs_start  <= 1'b1;
                        bfs_valid  <= 1'b0;
                        state      <= B_BFS;
                    end
                end

                // Wait for the search to finish (about 400 clocks)
                B_BFS: begin
                    if (bfs_done) begin
                        bfs_valid <= 1'b1;
                        state     <= at_waypoint ? B_NEIGH : B_MOVE;
                    end
                end

                // At a cell centre: read own and neighbour distances, pick the next cell
                B_NEIGH: begin
                    if (n_index == 3'd0) begin
                        own_dist  <= q_dist;
                        best_dist <= q_dist;
                        best_dir  <= 3'd4;
                        if (q_dist == FAR && !fleeing)
                            wander_valid <= 1'b0;        // goal unreachable from here
                    end else begin
                        if (q_dist != FAR) begin
                            if (fleeing ? (q_dist > best_dist) : (q_dist < best_dist)) begin
                                best_dist <= q_dist;
                                best_dir  <= n_index - 3'd1;
                            end
                        end
                    end
                    if (n_index == 3'd4) begin
                        state <= B_MOVE;
                    end
                    n_index <= n_index + 3'd1;
                end

                // 4. Move
                B_MOVE: begin
                    if (at_waypoint && n_index == 3'd5) begin
                        // set the next waypoint from the choice just made
                        case (best_dir)
                            3'd0: way_y <= way_y - 16'sd256;
                            3'd1: way_x <= way_x + 16'sd256;
                            3'd2: way_y <= way_y + 16'sd256;
                            3'd3: way_x <= way_x - 16'sd256;
                            default: ;
                        endcase
                        if (best_dir != 3'd4 && !(can_see_player && bot_role == ROLE_SEEKER))
                            bot_dir <= {best_dir[1:0], 6'd0};   // face the way it walks
                        n_index <= 3'd0;
                    end else if (!bot_frozen && pause_ms == 16'd0) begin
                        move_step = {8'd0, speed};
                        if (bot_x != way_x) begin
                            diff = way_x - bot_x;
                            if (diff > 0) next_x = (diff > move_step) ? bot_x + move_step : way_x;
                            else          next_x = (-diff > move_step) ? bot_x - move_step : way_x;
                            if (!opp_blocks(next_x, bot_y, bot_x, bot_y, player_x, player_y))
                                bot_x <= next_x;             // else wait for the player to move
                        end else if (bot_y != way_y) begin
                            diff = way_y - bot_y;
                            if (diff > 0) next_y = (diff > move_step) ? bot_y + move_step : way_y;
                            else          next_y = (-diff > move_step) ? bot_y - move_step : way_y;
                            if (!opp_blocks(bot_x, next_y, bot_x, bot_y, player_x, player_y))
                                bot_y <= next_y;
                        end
                    end
                    if (can_see_player && bot_role == ROLE_SEEKER)
                        bot_dir <= direction_to(to_player_x, to_player_y);   // aim at the player
                    if (!(at_waypoint && n_index == 3'd5))
                        state <= B_ACT;
                end

                // 5. Act
                B_ACT: begin
                    if (!bot_frozen && seen_ms >= reaction_ms + {6'd0, react_extra} && cooldown_ms == 16'd0) begin
                        if (bot_role == ROLE_SEEKER) begin
                            if (can_see_player && ammo != 4'd0) begin
                                ammo        <= ammo - 4'd1;
                                cooldown_ms <= COOLDOWN_MS;
                                if (lfsr[15:8] < accuracy) begin
                                    got_hit        <= 1'b1;
                                    got_hit_damage <= SHOT_DAMAGE;
                                end
                            end
                        end else begin
                            if (can_see_player && player_distance <= 16'd768 && ammo != 4'd0) begin
                                // Seeker within 3 cells: Freeze Gun
                                ammo        <= ammo - 4'd1;
                                cooldown_ms <= COOLDOWN_MS;
                                if (lfsr[15:8] < accuracy)
                                    got_frozen <= 1'b1;
                            end
                        end
                    end
                    // Hider reflex: Seeker in view within 2 cells -> Flashbang to escape
                    // (no reaction delay, so the bot doesn't wait until it's too late)
                    if (bot_role == ROLE_HIDER && !bot_frozen && can_see_player &&
                        player_distance <= 16'd512 && flashes_left != 3'd0 && flash_cd_ms == 16'd0) begin
                        flash_cd_ms     <= FLASH_MS;
                        flashes_left    <= flashes_left - 3'd1;
                        peer_flash_used <= 1'b1;
                    end
                    state <= B_WAIT;
                end

                default: state <= B_WAIT;
            endcase
        end
    end
endmodule
