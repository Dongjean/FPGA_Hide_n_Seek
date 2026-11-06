`timescale 1ns / 1ps

module capsule_ctrl
#(
    parameter integer SEC_CYCLES  = 6_250_000,// clocks per second
    parameter integer SPAWN_SEC   = 40, // new capsule every 40 s of game time
    parameter integer LIFE_SEC    = 20, // each one lasts 20 s
    parameter integer FADE_SEC    = 5, // blinks on the minimap in its last 5 s
    parameter integer AVOID_CELLS = 3, // solo mode: keep this far from the players
    parameter integer MAX_TRIES   = 255, // random cells to try before skipping this spawn
    parameter [15:0]  SEED_XOR    = 16'hC0DE // so it gets different random numbers from map_gen/portals
)
(
    input                    clk,
    input                    reset,

    // match (from Jian Bin)
    input                    start, // new match (start_game)
    input             [15:0] seed, // game_seed
    input                    in_game,
    input                    game_paused,
    input                    solo_mode, // 1 = playing the bot (sw12)

    // world (from world_top / portal_ctrl)
    input            [199:0] cells,
    input             [6:0]  hider_cell,
    input             [6:0]  seeker_cell,
    input             [27:0] exit_cells, // portal exits, 4 x 7 bits
    input             [1:0]  pair_valid, // which portal pairs exist

    // write port into world_top (hold we high until wgrant)
    output reg               cap_we,
    output reg        [7:0]  cap_waddr,
    output reg        [1:0]  cap_wdata,
    input                    cap_wgrant,

    // players
    input  signed     [15:0] player_x,
    input  signed     [15:0] player_y,
    // other player or bot
    input  signed     [15:0] op_x, 
    input  signed     [15:0] op_y,
    input                    is_hider,
    // this player is the Hider       

    // link (Jian Bin's multiplayer_core capsule signals)
    output reg               ev_capsule, // capture capsule capsule_id
    output reg        [7:0]  capsule_id,
    input                    peer_capsule, // the other board took one
    input             [7:0]  peer_capsule_id,
    output            [3:0]  capsule_valid,  // for the bot
    output            [31:0] capsule_cells,  // {y, x} per slot

    // timer (Isaac)
    output reg               time_penalty,   // take the capsule time off

    // minimap
    output            [1:0]  cap_fade_valid, // 1 = slot is in its last FADE_SEC seconds
    output            [6:0]  cap_fade_cell0,
    output            [6:0]  cap_fade_cell1,

    // debug
    output reg        [9:0]  game_sec // seconds of game time since start
);

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;

    //states
    localparam S_RUN    = 1'b0, // normal: timers running, waiting for events
               S_SEARCH = 1'b1; // looking for a cell to spawn on

    //slots (slot 0 and slot 1)
    reg  [1:0] valid;
    reg  [3:0] sx0, sy0, sx1, sy1; // slot cell x, y
    reg  [6:0] si0, si1; // slot cell index y*10 + x
    reg  [4:0] life0, life1; // seconds left

    assign capsule_valid = {2'b00, valid};
    assign capsule_cells = {16'd0, sy1, sx1, sy0, sx0};

    assign cap_fade_valid = {valid[1] && life1 <= FADE_SEC, valid[0] && life0 <= FADE_SEC};
    assign cap_fade_cell0 = si0;
    assign cap_fade_cell1 = si1;

    //writes waiting to go into the cell array, 1 per slot (set = 11, clear = 00)
    reg  [1:0] wr_pend;
    reg  [1:0] wr_val0, wr_val1;
    reg  [6:0] wr_idx0, wr_idx1;
    reg        wr_slot; // which slot's write is on the port now

    //game time
    //sub_cnt is a mod-SEC_CYCLES counter -> sec_tick once every second
    wire       running = in_game && !game_paused;
    reg [22:0] sub_cnt; // clock cycles into the current second
    wire       sec_tick = running && (sub_cnt == SEC_CYCLES - 1);
    reg [5:0]  spawn_cnt; // seconds since the last spawn

    //random numbers (only steps while searching -> same numbers on both boards)
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

    //check if the random cell can be used for a spawn (combinational)
    function [1:0] type_at (input [199:0] c, input [3:0] x, input [3:0] y);
        reg [6:0] i;
        begin
            i = {y, 3'b000} + {y, 1'b0} + x;
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

    //player cells. positions in the map are 0..2559 (Q8.8), so bits [11:8] = cell number
    wire [3:0] pcx = player_x[11:8], pcy = player_y[11:8];
    wire [3:0] ocx = op_x[11:8],     ocy = op_y[11:8];
    wire [4:0] d_me = absdiff(cx, pcx) + absdiff(cy, pcy);
    wire [4:0] d_op = absdiff(cx, ocx) + absdiff(cy, ocy);

    wire is_exit = (pair_valid[0] && (c_idx == exit_cells[6:0]  || c_idx == exit_cells[13:7])) ||
                   (pair_valid[1] && (c_idx == exit_cells[20:14] || c_idx == exit_cells[27:21]));

    wire cand_ok = (cx <= 4'd9) && (cy <= 4'd9) &&
                   (type_at(cells, cx, cy) == T_FLOOR) &&          // floor only (not wall/portal/capsule)
                   (c_idx != hider_cell) && (c_idx != seeker_cell) &&
                   !is_exit &&
                   (!solo_mode || (d_me > AVOID_CELLS && d_op > AVOID_CELLS));

    reg  [7:0] tries;
    reg        new_slot;                // slot being filled in
    reg        spawn_req;               // 1 = time to spawn a capsule

    //pick up check (walking over)
    //uses the slot registers, not the cell array, so a capsule counts from the
    //same cycle it is placed
    //me (Hider): my own board decides and tells the other board
    wire me_on0  = valid[0] && pcx == sx0 && pcy == sy0;
    wire me_on1  = valid[1] && pcx == sx1 && pcy == sy1;
    wire me_take = running && is_hider && (me_on0 || me_on1);
    wire me_slot = !me_on0; // slot 0 first if both (shouldn't happen)

    //bot (solo mode, bot is the Hider since I'm the Seeker)
    wire bot_on0  = valid[0] && ocx == sx0 && ocy == sy0;
    wire bot_on1  = valid[1] && ocx == sx1 && ocy == sy1;
    wire bot_take = running && solo_mode && !is_hider && (bot_on0 || bot_on1);
    wire bot_slot = !bot_on0;

    //main logic (sync reset, <= since sequential)
    always @(posedge clk) begin
        if (reset || start) begin
            //new match: map_gen is rebuilding the cells, so just clear everything
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
            ev_capsule   <= 1'b0;           // default 0, so these are 1 cycle pulses
            time_penalty <= 1'b0;

            //write port (1 waiting write at a time)
            if (!cap_we) begin
                if (wr_pend[0]) begin
                    cap_we <= 1'b1; cap_waddr <= {1'b0, wr_idx0}; cap_wdata <= wr_val0; wr_slot <= 1'b0;
                end else if (wr_pend[1]) begin
                    cap_we <= 1'b1; cap_waddr <= {1'b0, wr_idx1}; cap_wdata <= wr_val1; wr_slot <= 1'b1;
                end
            end else if (cap_wgrant) begin
                cap_we <= 1'b0;
                //done, unless a newer write for this slot came in meanwhile
                //(a newer write further down sets wr_pend again in this same cycle)
                if (wr_slot == 1'b0 && cap_waddr[6:0] == wr_idx0 && cap_wdata == wr_val0) wr_pend[0] <= 1'b0;
                if (wr_slot == 1'b1 && cap_waddr[6:0] == wr_idx1 && cap_wdata == wr_val1) wr_pend[1] <= 1'b0;
            end

            //game clock
            if (running) sub_cnt <= sec_tick ? 23'd0 : sub_cnt + 23'd1;

            if (sec_tick) begin
                game_sec <= game_sec + 10'd1;

                //lifetime: count down, capsule disappears at 0
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

                //spawn timer (mod-SPAWN_SEC counter)
                if (spawn_cnt == SPAWN_SEC - 1) begin
                    spawn_cnt <= 6'd0;
                    spawn_req <= 1'b1;               // S_RUN below handles it
                end else begin
                    spawn_cnt <= spawn_cnt + 6'd1;
                end
            end

            //FSM for spawning (S_RUN <-> S_SEARCH)
            case (state)
                S_RUN: begin
                    if (spawn_req) begin
                        spawn_req <= 1'b0;
                        if (!(valid[0] && valid[1])) begin   // else both slots full, skip
                            new_slot <= valid[0];            // first empty slot
                            tries    <= 8'd0;
                            state    <= S_SEARCH;
                        end
                    end
                end

                //1 random cell per clock; LFSR steps every clock in this state
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
                        state <= S_RUN;              // no space this time; try again next spawn
                    end
                    tries <= tries + 8'd1;
                end

                default: state <= S_RUN;
            endcase

            //pick ups
            //placed after the lifetime code, so a pick up in the capsule's last
            //second still counts (both clear the same slot, penalty still happens)
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
                time_penalty <= 1'b1;                // no ev_capsule since the bot is on this board
            end

            //other board took a capsule
            //`valid` check: if the slot is already cleared here (e.g. the bot's
            //own walk over above), no 2nd penalty
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