`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// portal_ctrl - Warp Portals (Andrew, world generation)
//
// Rev 11 (4 Nov 2026): new game spec.
//   - 1 portal pair by default (NUM_PAIRS = 1; 2 still works).
//   - Portals can now also be INSIDE the maze: an inner wall cell with open
//     cells on two OPPOSITE sides (a thin wall between two corridors) is a
//     "through" portal.  You can walk into it from either side; its exit is
//     one of the two sides, picked at random from the seed.  (Before, almost
//     every portal was on the border wall; see the NOTE below.)
//
// What it does
//   1. After each new maze (world_top.map_done) it picks NUM_PAIRS portal pairs
//      (portal 0 <-> portal 1, portal 2 <-> portal 3) and writes them into
//      world_top's cell array as type 10 (portal) through the portal write port.
//   2. When this player walks into a portal (player_movement.bump on a portal
//      cell) it sends a 1-cycle tp_load with the centre of the PARTNER portal's
//      exit cell, facing away from the partner portal.  3 s cooldown after that.
//
// Where a portal may go (all checked on the finished maze):
//   - a wall cell that is not a map corner,
//   - with exactly ONE open orthogonal neighbour (floor or capsule) = its exit,
//     OR (ALLOW_THROUGH = 1) exactly two open neighbours on opposite sides
//     (E+W or N+S) = a through portal; one of them, chosen by an LFSR bit, is
//     its exit,
//   - exit is not a spawn cell and is >= MIN_SPAWN_DIST cells (Manhattan) from
//     both spawn cells,
//   - no portal cell and no exit cell used twice,
//   - the two exits of a pair are >= MIN_PAIR_DIST cells apart (else the
//     teleport would barely move you).
//   NOTE: in this 10x10 maze almost every INTERIOR wall touches 2+ corridors, so
//   with one-sided portals only, nearly all portals end up on the outer border
//   wall.  Through portals (rev 11) add the thin inner walls between corridors.
//
// How the search works (deterministic, so both boards pick the same portals)
//   Own lfsr16, loaded with (seed ^ SEED_XOR) on start.  Each cycle in S_RANDOM
//   the LFSR gives a random (x, y) = (out[3:0], out[7:4]); if that cell passes
//   every rule it becomes the next portal.  If MAX_TRIES random tries are not
//   enough, S_SCAN walks all 100 cells in order with the pair-distance rule
//   relaxed, so the result never depends on luck.  If even that finds fewer than
//   4, only the complete pairs are used (pair_valid).
//
// Cell-type array: cells[2*(y*10+x) +: 2] - 00 floor, 01 wall, 10 portal, 11 capsule
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
//////////////////////////////////////////////////////////////////////////////////
module portal_ctrl
#(
    parameter integer NUM_PAIRS      = 1,          // portal pairs (1 or 2)
    parameter integer ALLOW_THROUGH  = 1,          // 1 = inner two-sided portals allowed
    parameter integer COOLDOWN       = 18_750_000, // 3 s at 6.25 MHz
    parameter integer MAX_TRIES      = 1023,       // random tries before the ordered scan
    parameter integer MIN_SPAWN_DIST = 4,          // exit cell to each spawn cell
    parameter integer MIN_PAIR_DIST  = 4,          // exit to the partner's exit
    parameter [15:0]  SEED_XOR       = 16'h5A3C    // different random stream from map_gen
)
(
    input                    clk,
    input                    reset,

    // ---- From world_top ----
    input                    start,          // 1-cycle: new match (same pulse as world_top.start)
    input             [15:0] seed,           // same seed as world_top
    input                    map_done,       // 1-cycle: the maze is finished
    input            [199:0] cells,          // cell-type array
    input             [6:0]  hider_cell,     // spawn cells, y*10 + x
    input             [6:0]  seeker_cell,

    // ---- Write port into world_top (hold we until wgrant) ----
    output reg               portal_we,
    output reg        [7:0]  portal_waddr,   // y*10 + x
    output            [1:0]  portal_wdata,   // always 10 (portal)
    input                    portal_wgrant,

    // ---- From player_movement ----
    input                    bump,           // 1-cycle: a move was blocked
    input             [3:0]  bump_cx,        // by this cell
    input             [3:0]  bump_cy,
    input                    game_paused,    // cooldown stops while paused

    // ---- Teleport: OR into player_movement's load_pos (world_top's spawn wins) ----
    output reg               tp_load,        // 1-cycle
    output reg signed [15:0] tp_x,           // Q8.8 cell centre
    output reg signed [15:0] tp_y,
    output reg        [7:0]  tp_dir,         // 0 N, 64 E, 128 S, 192 W

    // ---- Status / for capsule_ctrl ----
    output reg               portals_ready,  // portals written, teleports active
    output reg        [1:0]  pair_valid,     // bit p = pair p (portals 2p, 2p+1) exists
                                             // (NUM_PAIRS = 1: bit 1 always 0)
    output            [27:0] portal_cells,   // 4 x 7-bit y*10+x, portal i at [7*i +: 7]
    output            [27:0] exit_cells      // 4 x 7-bit, exit of portal i (unused slots 0)
);

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;
    localparam [7:0] DIR_N = 8'd0, DIR_E = 8'd64, DIR_S = 8'd128, DIR_W = 8'd192;
    localparam [2:0] LAST  = 2*NUM_PAIRS - 1;   // index of the last portal to find

    localparam [2:0] S_IDLE   = 3'd0,   // waiting for map_done
                     S_RANDOM = 3'd1,   // random tries from the LFSR
                     S_SCAN   = 3'd2,   // ordered scan of all cells (fallback)
                     S_WRITE  = 3'd3,   // write the portals into world_top
                     S_READY  = 3'd4;   // teleports active

    assign portal_wdata = T_PORTAL;

    // =====================================================================
    // Random numbers
    // =====================================================================
    wire [15:0] rnd;
    reg         rnd_step;

    lfsr16 rng (
        .clk   (clk),
        .reset (reset),
        .load  (start),
        .seed  (seed ^ SEED_XOR),
        .step  (rnd_step),
        .out   (rnd)
    );

    // =====================================================================
    // Stored portals
    // =====================================================================
    reg [6:0] p_cell [0:3];     // portal cell
    reg [6:0] e_cell [0:3];     // its exit cell
    reg [3:0] e_x    [0:3];     // exit x, y (kept so no /10 is needed later)
    reg [3:0] e_y    [0:3];
    reg [7:0] e_dir  [0:3];     // direction from the portal to its exit = "facing away"
    reg [3:0] o_x    [0:3];     // the OTHER open side of a through portal (= exit if one-sided)
    reg [3:0] o_y    [0:3];
    reg [6:0] o_cell [0:3];
    reg [2:0] n_found;          // portals found so far (0..4)

    assign portal_cells = {p_cell[3], p_cell[2], p_cell[1], p_cell[0]};
    assign exit_cells   = {e_cell[3], e_cell[2], e_cell[1], e_cell[0]};

    reg [2:0]  state;
    reg [9:0]  tries;
    reg [3:0]  scan_x, scan_y;
    reg [2:0]  wr_i;            // portal being written (0..4; 3 bits so it can pass 3)

    // =====================================================================
    // Candidate cell (x, y) for this cycle
    // =====================================================================
    wire [3:0] cx = (state == S_SCAN) ? scan_x : rnd[3:0];
    wire [3:0] cy = (state == S_SCAN) ? scan_y : rnd[7:4];

    // cell type at (x, y); anything off the map is a wall
    function [1:0] type_at (input [199:0] c, input [4:0] x, input [4:0] y);
        reg [6:0] i;
        begin
            i = {y[3:0], 3'b000} + {y[3:0], 1'b0} + x[3:0];   // y*10 + x
            if (x > 5'd9 || y > 5'd9) type_at = T_WALL;
            else                      type_at = c[{i, 1'b0} +: 2];
        end
    endfunction

    function is_open (input [1:0] t);
        is_open = (t == T_FLOOR) || (t == T_CAPSULE);
    endfunction

    // |a - b| for 4-bit coordinates
    function [3:0] absdiff (input [3:0] a, input [3:0] b);
        absdiff = (a > b) ? (a - b) : (b - a);
    endfunction

    // x and y of a cell index 0..99 without a divider: y = (i * 205) >> 11
    // is exact for 0..179, so it is exact for every cell.
    function [3:0] idx_y (input [6:0] i);
        reg [14:0] t;
        begin
            t     = i * 8'd205;
            idx_y = t[14:11];
        end
    endfunction
    function [3:0] idx_x (input [6:0] i);
        reg [3:0] y;
        begin
            y     = idx_y(i);
            idx_x = i - ({y, 3'b000} + {y, 1'b0});   // i - y*10
        end
    endfunction

    wire [3:0] hx = idx_x(hider_cell),  hy = idx_y(hider_cell);
    wire [3:0] sx = idx_x(seeker_cell), sy = idx_y(seeker_cell);

    // Neighbours in the order E, S, W, N.  {1'b0, c} - 1 wraps to 31 at the
    // edge, which is > 9 and so reads as a wall in type_at.
    wire [4:0] xe = {1'b0, cx} + 5'd1, xw = {1'b0, cx} - 5'd1;
    wire [4:0] ys = {1'b0, cy} + 5'd1, yn = {1'b0, cy} - 5'd1;
    wire open_e = is_open(type_at(cells, xe, {1'b0, cy}));
    wire open_s = is_open(type_at(cells, {1'b0, cx}, ys));
    wire open_w = is_open(type_at(cells, xw, {1'b0, cy}));
    wire open_n = is_open(type_at(cells, {1'b0, cx}, yn));
    wire [2:0] n_open = open_e + open_s + open_w + open_n;

    // Shape of the candidate wall
    wire one_side = (n_open == 3'd1);                              // dead-end wall
    wire thru_ew  = open_e && open_w && !open_n && !open_s;        // corridor | wall | corridor
    wire thru_ns  = open_n && open_s && !open_e && !open_w;
    wire through  = (ALLOW_THROUGH != 0) && (thru_ew || thru_ns);
    wire side     = rnd[8];        // through portal: 1 = exit E (or S), 0 = exit W (or N);
                                   // from the seeded LFSR, so both boards pick the same

    // The exit cell, the "facing away" direction, and the other side (ox, oy):
    // the cell you can walk in from that is NOT the exit (one-sided: = exit)
    reg  [3:0] ex, ey, ox, oy;
    reg  [7:0] edir;
    always @(*) begin
        ex = cx; ey = cy; edir = DIR_N;
        ox = cx; oy = cy;
        if (through) begin
            if (thru_ew) begin
                ex   = side ? cx + 4'd1 : cx - 4'd1;
                ox   = side ? cx - 4'd1 : cx + 4'd1;
                edir = side ? DIR_E     : DIR_W;
            end else begin
                ey   = side ? cy + 4'd1 : cy - 4'd1;
                oy   = side ? cy - 4'd1 : cy + 4'd1;
                edir = side ? DIR_S     : DIR_N;
            end
        end else if (open_e) begin ex = cx + 4'd1; edir = DIR_E; end
        else if   (open_s) begin ey = cy + 4'd1; edir = DIR_S; end
        else if   (open_w) begin ex = cx - 4'd1; edir = DIR_W; end
        else if   (open_n) begin ey = cy - 4'd1; edir = DIR_N; end
        if (!through) begin ox = ex; oy = ey; end
    end

    wire [6:0] c_idx = {cy, 3'b000} + {cy, 1'b0} + cx;
    wire [6:0] e_idx = {ey, 3'b000} + {ey, 1'b0} + ex;
    wire [6:0] o_idx = {oy, 3'b000} + {oy, 1'b0} + ox;

    wire in_map    = (cx <= 4'd9) && (cy <= 4'd9);
    wire is_corner = (cx == 4'd0 || cx == 4'd9) && (cy == 4'd0 || cy == 4'd9);
    wire is_wall   = (type_at(cells, {1'b0, cx}, {1'b0, cy}) == T_WALL);

    // Manhattan distances from the exit to each spawn (each term <= 9, sum <= 18)
    wire [4:0] d_hider  = absdiff(ex, hx) + absdiff(ey, hy);
    wire [4:0] d_seeker = absdiff(ex, sx) + absdiff(ey, sy);
    wire far_from_spawns = (e_idx != hider_cell) && (e_idx != seeker_cell) &&
                           (d_hider  >= MIN_SPAWN_DIST) && (d_seeker >= MIN_SPAWN_DIST);

    // Not already used: compare with every portal found so far.  The side cells
    // must not be shared either: if my entry side were the partner's exit, you
    // would step in and land on the same cell.
    // (Everything is passed in as arguments, so the function only uses its inputs.)
    function clash (input [6:0] pc, input [6:0] ec, input [6:0] oc,     // a found portal
                    input [6:0] c,  input [6:0] e,  input [6:0] o);     // the candidate
        clash = (pc == c) || (ec == e) || (ec == o) || (oc == e) || (oc == o);
    endfunction
    wire used0 = (n_found > 3'd0) && clash(p_cell[0], e_cell[0], o_cell[0], c_idx, e_idx, o_idx);
    wire used1 = (n_found > 3'd1) && clash(p_cell[1], e_cell[1], o_cell[1], c_idx, e_idx, o_idx);
    wire used2 = (n_found > 3'd2) && clash(p_cell[2], e_cell[2], o_cell[2], c_idx, e_idx, o_idx);
    wire not_used = !(used0 || used1 || used2);

    // Second portal of a pair (n_found = 1 or 3): far from the partner.  Checked
    // between my exit and the partner's exit, and (through portals) between each
    // side and the other portal's other side, so the jump always moves you.
    wire [2:0] partner = n_found - 3'd1;
    wire [1:0] pt      = partner[1:0];
    wire [4:0] d_ee = absdiff(ex, e_x[pt]) + absdiff(ey, e_y[pt]);
    wire [4:0] d_eo = absdiff(ex, o_x[pt]) + absdiff(ey, o_y[pt]);
    wire [4:0] d_oe = absdiff(ox, e_x[pt]) + absdiff(oy, e_y[pt]);
    wire pair_ok = !n_found[0] || (state == S_SCAN) ||
                   (d_ee >= MIN_PAIR_DIST && d_eo >= MIN_PAIR_DIST && d_oe >= MIN_PAIR_DIST);

    wire good = in_map && !is_corner && is_wall && (one_side || through) &&
                far_from_spawns && not_used && pair_ok;

    // =====================================================================
    // Teleport lookup: which portal did we walk into?
    // =====================================================================
    wire [6:0] b_idx = {bump_cy, 3'b000} + {bump_cy, 1'b0} + bump_cx;
    wire hit0 = pair_valid[0] && (b_idx == p_cell[0]);
    wire hit1 = pair_valid[0] && (b_idx == p_cell[1]);
    wire hit2 = pair_valid[1] && (b_idx == p_cell[2]);
    wire hit3 = pair_valid[1] && (b_idx == p_cell[3]);
    // partner of i is i ^ 1 (0<->1, 2<->3)
    wire [1:0] dest = hit0 ? 2'd1 : hit1 ? 2'd0 : hit2 ? 2'd3 : 2'd2;

    reg [24:0] cooldown;        // counts down; 0 = teleport allowed

    integer k;

    // =====================================================================
    // Main FSM
    // =====================================================================
    always @(posedge clk) begin
        if (reset) begin
            state         <= S_IDLE;
            rnd_step      <= 1'b0;
            n_found       <= 3'd0;
            tries         <= 10'd0;
            scan_x        <= 4'd0;
            scan_y        <= 4'd0;
            wr_i          <= 3'd0;
            portal_we     <= 1'b0;
            portal_waddr  <= 8'd0;
            portals_ready <= 1'b0;
            pair_valid    <= 2'b00;
            tp_load       <= 1'b0;
            tp_x          <= 16'sd0;
            tp_y          <= 16'sd0;
            tp_dir        <= DIR_N;
            cooldown      <= 25'd0;
            for (k = 0; k < 4; k = k + 1) begin
                p_cell[k] <= 7'd0;  e_cell[k] <= 7'd0;
                e_x[k]    <= 4'd0;  e_y[k]    <= 4'd0;  e_dir[k] <= DIR_N;
                o_x[k]    <= 4'd0;  o_y[k]    <= 4'd0;  o_cell[k] <= 7'd0;
            end
        end else if (start) begin
            // New match: forget the old portals (map_gen is overwriting the cells)
            state         <= S_IDLE;
            rnd_step      <= 1'b0;
            portal_we     <= 1'b0;
            portals_ready <= 1'b0;
            pair_valid    <= 2'b00;
            tp_load       <= 1'b0;
            cooldown      <= 25'd0;
        end else begin
            tp_load  <= 1'b0;                       // default: 1-cycle pulse
            rnd_step <= 1'b0;

            // Cooldown runs in every state, but not while paused
            if (cooldown != 25'd0 && !game_paused)
                cooldown <= cooldown - 25'd1;

            case (state)
                S_IDLE: begin
                    if (map_done) begin
                        n_found  <= 3'd0;
                        tries    <= 10'd0;
                        rnd_step <= 1'b1;           // move away from the raw seed value
                        state    <= S_RANDOM;
                    end
                end

                // ---- One random candidate per cycle ----
                // rnd_step is registered, so the LFSR moves every second cycle;
                // the cycle in between re-checks the same candidate, which is
                // harmless (it is then "used" and rejected).
                S_RANDOM: begin
                    rnd_step <= ~rnd_step;
                    tries    <= tries + 10'd1;
                    if (good && rnd_step == 1'b0) begin   // only on a fresh value
                        p_cell[n_found[1:0]] <= c_idx;
                        e_cell[n_found[1:0]] <= e_idx;
                        e_x[n_found[1:0]]    <= ex;
                        e_y[n_found[1:0]]    <= ey;
                        e_dir[n_found[1:0]]  <= edir;
                        o_x[n_found[1:0]]    <= ox;
                        o_y[n_found[1:0]]    <= oy;
                        o_cell[n_found[1:0]] <= o_idx;
                        n_found              <= n_found + 3'd1;
                        if (n_found == LAST) begin       // that was the last one needed
                            wr_i  <= 3'd0;
                            state <= S_WRITE;
                        end
                    end else if (tries == MAX_TRIES) begin
                        scan_x <= 4'd0;
                        scan_y <= 4'd0;
                        state  <= S_SCAN;
                    end
                end

                // ---- Ordered scan of every cell (pair-distance rule relaxed) ----
                S_SCAN: begin
                    if (good) begin
                        p_cell[n_found[1:0]] <= c_idx;
                        e_cell[n_found[1:0]] <= e_idx;
                        e_x[n_found[1:0]]    <= ex;
                        e_y[n_found[1:0]]    <= ey;
                        e_dir[n_found[1:0]]  <= edir;
                        o_x[n_found[1:0]]    <= ox;
                        o_y[n_found[1:0]]    <= oy;
                        o_cell[n_found[1:0]] <= o_idx;
                        n_found              <= n_found + 3'd1;
                    end
                    if ((good && n_found == LAST) || (scan_x == 4'd9 && scan_y == 4'd9)) begin
                        wr_i  <= 3'd0;
                        state <= S_WRITE;
                    end else if (scan_x == 4'd9) begin
                        scan_x <= 4'd0;
                        scan_y <= scan_y + 4'd1;
                    end else begin
                        scan_x <= scan_x + 4'd1;
                    end
                end

                // ---- Write portals 0..(2*pairs-1) into world_top ----
                S_WRITE: begin
                    // Only complete pairs are kept: 4 found -> 2 pairs, 2 or 3 -> 1
                    // (n_found never passes 2*NUM_PAIRS, so NUM_PAIRS = 1 gives 1 pair)
                    if (!portal_we) begin
                        if (wr_i < {n_found[2:1], 1'b0}) begin
                            portal_we    <= 1'b1;
                            portal_waddr <= {1'b0, p_cell[wr_i[1:0]]};
                        end else begin
                            pair_valid    <= {n_found[2], n_found[2] | n_found[1]};
                            portals_ready <= 1'b1;
                            state         <= S_READY;
                        end
                    end else if (portal_wgrant) begin
                        portal_we <= 1'b0;          // written this edge
                        wr_i      <= wr_i + 3'd1;
                    end
                end

                // ---- Teleports ----
                S_READY: begin
                    if (bump && cooldown == 25'd0 && !game_paused &&
                        (hit0 || hit1 || hit2 || hit3)) begin
                        tp_load  <= 1'b1;
                        tp_x     <= {4'b0000, e_x[dest], 8'h80};   // centre = (c << 8) + 128
                        tp_y     <= {4'b0000, e_y[dest], 8'h80};
                        tp_dir   <= e_dir[dest];                   // facing away from that portal
                        cooldown <= COOLDOWN;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule