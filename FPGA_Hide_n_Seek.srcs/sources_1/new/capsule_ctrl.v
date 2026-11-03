`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// capsule_ctrl - Time Capsules (Andrew, world generation)
//
// Rev 10 (4 Nov 2026): capsules are now PICKED UP BY WALKING OVER THEM
// (the Hider only), instead of being shot.  The ray march is gone.
//
// What it does
//   1. Game time: counts seconds while the match runs (in_game and not paused),
//      starting from start.  Both boards get start_game and game_paused from
//      Jian Bin's link, so both count the same seconds.
//   2. Every SPAWN_SEC seconds it places a capsule (type 11) on a random floor
//      cell: not a spawn cell, not a portal exit, and (solo mode only) not
//      within AVOID_CELLS cells of either player.  It disappears after LIFE_SEC
//      seconds; in the last FADE_SEC seconds the minimap blinks it.
//      At most 2 capsules at once (slots 0 and 1).
//   3. Pick-up: when THIS player is the Hider and stands in a capsule's cell
//      while the game runs, the capsule is taken: clear the cell, pulse
//      time_penalty, pulse ev_capsule with the slot number (Jian Bin's link
//      sends it to the other board).  The Seeker walks through capsules.
//   4. peer_capsule (the other board's Hider, or the bot, took capsule
//      peer_capsule_id): clear that slot and pulse time_penalty here too,
//      because each board runs its own timer.  So every pick-up takes
//      PENALTY time off BOTH timers, once each (the amount is set in the timer).
//   5. Solo mode, bot is the Hider: the bot standing in a capsule's cell also
//      takes it (penalty, no ev_capsule, since there is no other board).
//
// Sync rule
//   All random choices come from an lfsr16 loaded from the match seed, and it
//   only steps while searching for a spawn cell, so both boards pick the same
//   cells.  Only the Hider's own board decides a pick-up (from its exact
//   position) and tells the other board, so both boards stay identical.
//
// capsule_id = slot number (0 or 1), the same convention ai_bot uses.
// capsule_cells (for the bot): {y[3:0], x[3:0]} per slot; slots 2, 3 unused (0).
//
// Cell-type array: cells[2*(y*10+x) +: 2] - 00 floor, 01 wall, 10 portal, 11 capsule
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
//////////////////////////////////////////////////////////////////////////////////
module capsule_ctrl
#(
    parameter integer SEC_CYCLES  = 6_250_000,  // clocks per second
    parameter integer SPAWN_SEC   = 40,         // a new capsule every 40 s of game time
    parameter integer LIFE_SEC    = 20,         // each one lasts 20 s
    parameter integer FADE_SEC    = 5,          // blinks on the minimap in its last 5 s
    parameter integer AVOID_CELLS = 3,          // solo mode: keep this far from the players
    parameter integer MAX_TRIES   = 255,        // random cells tried before giving up this spawn
    parameter [15:0]  SEED_XOR    = 16'hC0DE    // different random stream from map_gen/portals
)
(
    input                    clk,
    input                    reset,

    // ---- Match (Jian Bin) ----
    input                    start,          // 1-cycle: new match (start_game)
    input             [15:0] seed,           // game_seed
    input                    in_game,
    input                    game_paused,
    input                    solo_mode,      // 1 = playing the bot (sw12)

    // ---- World (world_top / portal_ctrl) ----
    input            [199:0] cells,
    input             [6:0]  hider_cell,     // spawn cells, y*10 + x
    input             [6:0]  seeker_cell,
    input             [27:0] exit_cells,     // portal exits, 4 x 7 bits
    input             [1:0]  pair_valid,     // which portal pairs exist

    // ---- Write port into world_top (hold we until wgrant) ----
    output reg               cap_we,
    output reg        [7:0]  cap_waddr,
    output reg        [1:0]  cap_wdata,
    input                    cap_wgrant,

    // ---- Players ----
    input  signed     [15:0] player_x,       // this player, Q8.8
    input  signed     [15:0] player_y,
    input  signed     [15:0] op_x,           // other player or bot
    input  signed     [15:0] op_y,
    input                    is_hider,       // this player is the Hider

    // ---- Link (Jian Bin's multiplayer_core capsule interface) ----
    output reg               ev_capsule,     // 1-cycle: I took capsule capsule_id
    output reg        [7:0]  capsule_id,
    input                    peer_capsule,   // 1-cycle: the other side took one
    input             [7:0]  peer_capsule_id,
    output            [3:0]  capsule_valid,  // for the bot
    output            [31:0] capsule_cells,  // {y, x} per slot

    // ---- Timer (Isaac) ----
    output reg               time_penalty,   // 1-cycle: take the capsule time off

    // ---- Minimap ----
    output            [1:0]  cap_fade_valid, // slot is in its last FADE_SEC seconds
    output            [6:0]  cap_fade_cell0,
    output            [6:0]  cap_fade_cell1,

    // ---- Debug ----
    output reg        [9:0]  game_sec        // seconds of game time since start
);

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;

    localparam S_RUN    = 1'b0,     // normal: timers, waiting for events
               S_SEARCH = 1'b1;     // looking for a spawn cell

    // =====================================================================
    // Slots
    // =====================================================================
    reg  [1:0] valid;
    reg  [3:0] sx0, sy0, sx1, sy1;      // slot cell x, y
    reg  [6:0] si0, si1;                // slot cell index y*10 + x
    reg  [4:0] life0, life1;            // seconds left

    assign capsule_valid = {2'b00, valid};
    assign capsule_cells = {16'd0, sy1, sx1, sy0, sx0};

    assign cap_fade_valid = {valid[1] && life1 <= FADE_SEC, valid[0] && life0 <= FADE_SEC};
    assign cap_fade_cell0 = si0;
    assign cap_fade_cell1 = si1;

    // Pending writes into the cell array, one per slot (set = 11, clear = 00)
    reg  [1:0] wr_pend;
    reg  [1:0] wr_val0, wr_val1;
    reg  [6:0] wr_idx0, wr_idx1;
    reg        wr_slot;                 // slot whose write is on the port

    // =====================================================================
    // Game time
    // =====================================================================
    wire       running = in_game && !game_paused;
    reg [22:0] sub_cnt;                 // clocks within the current second
    wire       sec_tick = running && (sub_cnt == SEC_CYCLES - 1);
    reg [5:0]  spawn_cnt;               // seconds since the last spawn

    // =====================================================================
    // Random numbers (step only while searching -> same sequence on both boards)
    // =====================================================================
    reg         state;
    wire [15:0] rnd;
    lfsr16 rng (
        .clk   (clk),
        .reset (reset),
        .load  (start),
        .seed  (seed ^ SEED_XOR),
        .step  (state == S_SEARCH),
        .out   (rnd)
    );

    // =====================================================================
    // Spawn candidate check (combinational on the current LFSR value)
    // =====================================================================
    function [1:0] type_at (input [199:0] c, input [3:0] x, input [3:0] y);
        reg [6:0] i;
        begin
            i = {y, 3'b000} + {y, 1'b0} + x;              // y*10 + x
            if (x > 4'd9 || y > 4'd9) type_at = T_WALL;
            else                      type_at = c[{i, 1'b0} +: 2];
        end
    endfunction

    function [3:0] absdiff (input [3:0] a, input [3:0] b);
        absdiff = (a > b) ? (a - b) : (b - a);
    endfunction

    wire [3:0] cx    = rnd[3:0];
    wire [3:0] cy    = rnd[7:4];
    wire [6:0] c_idx = {cy, 3'b000} + {cy, 1'b0} + cx;

    // Player cells.  Positions in the map are 0..2559 (Q8.8), so bits [11:8] are the cell.
    wire [3:0] pcx = player_x[11:8], pcy = player_y[11:8];
    wire [3:0] ocx = op_x[11:8],     ocy = op_y[11:8];
    wire [4:0] d_me = absdiff(cx, pcx) + absdiff(cy, pcy);
    wire [4:0] d_op = absdiff(cx, ocx) + absdiff(cy, ocy);

    wire is_exit = (pair_valid[0] && (c_idx == exit_cells[6:0]  || c_idx == exit_cells[13:7])) ||
                   (pair_valid[1] && (c_idx == exit_cells[20:14] || c_idx == exit_cells[27:21]));

    wire cand_ok = (cx <= 4'd9) && (cy <= 4'd9) &&
                   (type_at(cells, cx, cy) == T_FLOOR) &&          // floor, so not a wall/portal/capsule
                   (c_idx != hider_cell) && (c_idx != seeker_cell) &&
                   !is_exit &&
                   (!solo_mode || (d_me > AVOID_CELLS && d_op > AVOID_CELLS));

    reg  [7:0] tries;
    reg        new_slot;                // slot being filled
    reg        spawn_req;               // a spawn is due

    // =====================================================================
    // Pick-up test (walk over).  Uses the slot registers, not the cell array,
    // so a capsule counts from the cycle it is placed.
    // =====================================================================
    // Me (Hider): my own board decides and tells the other board.
    wire me_on0  = valid[0] && pcx == sx0 && pcy == sy0;
    wire me_on1  = valid[1] && pcx == sx1 && pcy == sy1;
    wire me_take = running && is_hider && (me_on0 || me_on1);
    wire me_slot = !me_on0;                                   // slot 0 first if (impossibly) both

    // Bot (solo mode, bot is the Hider because I am the Seeker)
    wire bot_on0  = valid[0] && ocx == sx0 && ocy == sy0;
    wire bot_on1  = valid[1] && ocx == sx1 && ocy == sy1;
    wire bot_take = running && solo_mode && !is_hider && (bot_on0 || bot_on1);
    wire bot_slot = !bot_on0;

    // =====================================================================
    // Main logic
    // =====================================================================
    always @(posedge clk) begin
        if (reset || start) begin
            // New match: map_gen is rebuilding the cells, so just forget everything
            state        <= S_RUN;
            valid        <= 2'b00;
            sx0 <= 4'd0; sy0 <= 4'd0; sx1 <= 4'd0; sy1 <= 4'd0;
            si0 <= 7'd0; si1 <= 7'd0;
            life0 <= 5'd0; life1 <= 5'd0;
            wr_pend      <= 2'b00;
            wr_val0 <= T_FLOOR; wr_val1 <= T_FLOOR;
            wr_idx0 <= 7'd0;    wr_idx1 <= 7'd0;
            wr_slot      <= 1'b0;
            cap_we       <= 1'b0;
            cap_waddr    <= 8'd0;
            cap_wdata    <= T_FLOOR;
            sub_cnt      <= 23'd0;
            spawn_cnt    <= 6'd0;
            game_sec     <= 10'd0;
            tries        <= 8'd0;
            new_slot     <= 1'b0;
            spawn_req    <= 1'b0;
            ev_capsule   <= 1'b0;
            capsule_id   <= 8'd0;
            time_penalty <= 1'b0;
        end else begin
            ev_capsule   <= 1'b0;           // 1-cycle pulses
            time_penalty <= 1'b0;

            // ---------------- Write port (one pending write at a time) ----------------
            if (!cap_we) begin
                if (wr_pend[0]) begin
                    cap_we <= 1'b1; cap_waddr <= {1'b0, wr_idx0}; cap_wdata <= wr_val0; wr_slot <= 1'b0;
                end else if (wr_pend[1]) begin
                    cap_we <= 1'b1; cap_waddr <= {1'b0, wr_idx1}; cap_wdata <= wr_val1; wr_slot <= 1'b1;
                end
            end else if (cap_wgrant) begin
                cap_we <= 1'b0;
                // Done, unless a newer request for this slot came in meanwhile
                // (a newer request below re-sets wr_pend in this same cycle).
                if (wr_slot == 1'b0 && cap_waddr[6:0] == wr_idx0 && cap_wdata == wr_val0) wr_pend[0] <= 1'b0;
                if (wr_slot == 1'b1 && cap_waddr[6:0] == wr_idx1 && cap_wdata == wr_val1) wr_pend[1] <= 1'b0;
            end

            // ---------------- Game clock ----------------
            if (running) sub_cnt <= sec_tick ? 23'd0 : sub_cnt + 23'd1;

            if (sec_tick) begin
                game_sec <= game_sec + 10'd1;

                // Lifetimes: count down; at 0 the capsule disappears
                if (valid[0]) begin
                    if (life0 == 5'd1) begin
                        valid[0] <= 1'b0;
                        wr_pend[0] <= 1'b1; wr_val0 <= T_FLOOR; wr_idx0 <= si0;
                    end
                    life0 <= life0 - 5'd1;
                end
                if (valid[1]) begin
                    if (life1 == 5'd1) begin
                        valid[1] <= 1'b0;
                        wr_pend[1] <= 1'b1; wr_val1 <= T_FLOOR; wr_idx1 <= si1;
                    end
                    life1 <= life1 - 5'd1;
                end

                // Spawn timer
                if (spawn_cnt == SPAWN_SEC - 1) begin
                    spawn_cnt <= 6'd0;
                    spawn_req <= 1'b1;               // handled in S_RUN below
                end else begin
                    spawn_cnt <= spawn_cnt + 6'd1;
                end
            end

            // ---------------- FSM (spawning) ----------------
            case (state)
                S_RUN: begin
                    if (spawn_req) begin
                        spawn_req <= 1'b0;
                        if (!(valid[0] && valid[1])) begin   // else: both slots full, skip
                            new_slot <= valid[0];            // first free slot
                            tries    <= 8'd0;
                            state    <= S_SEARCH;
                        end
                    end
                end

                // One random cell per clock; the LFSR steps every clock in this state
                S_SEARCH: begin
                    if (cand_ok) begin
                        if (new_slot == 1'b0) begin
                            valid[0] <= 1'b1; sx0 <= cx; sy0 <= cy; si0 <= c_idx; life0 <= LIFE_SEC;
                            wr_pend[0] <= 1'b1; wr_val0 <= T_CAPSULE; wr_idx0 <= c_idx;
                        end else begin
                            valid[1] <= 1'b1; sx1 <= cx; sy1 <= cy; si1 <= c_idx; life1 <= LIFE_SEC;
                            wr_pend[1] <= 1'b1; wr_val1 <= T_CAPSULE; wr_idx1 <= c_idx;
                        end
                        state <= S_RUN;
                    end else if (tries == MAX_TRIES) begin
                        state <= S_RUN;              // no room this time; try again next period
                    end
                    tries <= tries + 8'd1;
                end

                default: state <= S_RUN;
            endcase

            // ---------------- Pick-ups ----------------
            // After the lifetime code, so a pick-up in the capsule's last second
            // still counts (both clear the same slot; the penalty still fires).
            if (me_take) begin
                if (me_slot == 1'b0) begin
                    valid[0] <= 1'b0;
                    wr_pend[0] <= 1'b1; wr_val0 <= T_FLOOR; wr_idx0 <= si0;
                end else begin
                    valid[1] <= 1'b0;
                    wr_pend[1] <= 1'b1; wr_val1 <= T_FLOOR; wr_idx1 <= si1;
                end
                time_penalty <= 1'b1;
                ev_capsule   <= 1'b1;                // tell the other board which slot
                capsule_id   <= {7'd0, me_slot};
            end else if (bot_take) begin
                if (bot_slot == 1'b0) begin
                    valid[0] <= 1'b0;
                    wr_pend[0] <= 1'b1; wr_val0 <= T_FLOOR; wr_idx0 <= si0;
                end else begin
                    valid[1] <= 1'b0;
                    wr_pend[1] <= 1'b1; wr_val1 <= T_FLOOR; wr_idx1 <= si1;
                end
                time_penalty <= 1'b1;                // no ev_capsule: the bot is on this board
            end

            // ---------------- The other side took a capsule ----------------
            // `valid` check: a slot already cleared here (e.g. the bot's own
            // walk-over above) gives no second penalty.
            if (peer_capsule && peer_capsule_id[7:1] == 7'd0) begin
                if (peer_capsule_id[0] == 1'b0 && valid[0]) begin
                    valid[0] <= 1'b0;
                    wr_pend[0] <= 1'b1; wr_val0 <= T_FLOOR; wr_idx0 <= si0;
                    time_penalty <= 1'b1;
                end
                if (peer_capsule_id[0] == 1'b1 && valid[1]) begin
                    valid[1] <= 1'b0;
                    wr_pend[1] <= 1'b1; wr_val1 <= T_FLOOR; wr_idx1 <= si1;
                    time_penalty <= 1'b1;
                end
            end
        end
    end

endmodule