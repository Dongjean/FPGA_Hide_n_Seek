`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// world_top - owner of the match's cell-type array (Andrew, world generation)
//
// What it does
//   1. Runs map_gen on `start` (seed_capture's seed_valid, or the boot pulse).
//   2. Owns cells[199:0] and arbitrates every write into it:
//        map_gen  >  portal_ctrl  >  capsule_ctrl      (one write per cycle, max)
//      Portal and capsule writes are only accepted while map_ready is high
//      (after the map is finished and before the next start), because map_gen
//      would overwrite them anyway.  A request that loses must be held until
//      its *_wgrant is seen high.
//   3. Converts cells to Dongjin's engine format map_bits[99:0].
//   4. Picks the spawns (spawn rule "option B") and drives load_pos/load_x/
//      load_y/load_dir into player_movement one cycle after the map is done,
//      and again on every `respawn` pulse (e.g. the countdown "go" event).
//   5. Gives a combinational cell-type read port for Toh's AI bot.
//
// Spawn rule (option B, 10x10)
//   Corners are fixed room cells, always on opposite corners of the maze:
//     diag = 0 : (1,1) and (7,7)          diag = 1 : (7,1) and (1,7)
//     swap = 0 : Hider on the first one   swap = 1 : Hider on the second one
//   diag and swap come from the seed, so both boards pick the same layout
//   with no extra link traffic.  Facing = first open neighbour in the order
//   E, S, W, N ("open" = floor or capsule; wall and portal are solid).
//   With this maze, (1,1), (7,1) and (7,7) always face East; (1,7) faces
//   East or South depending on the maze.
//
// Cell-type array: cells[2*(y*10+x) +: 2] - 00 floor, 01 wall, 10 portal, 11 capsule
// Engine map     : map_bits[99 - (y*10+x)], 1 = solid (wall or portal)
//
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high (btnC).
//////////////////////////////////////////////////////////////////////////////////
module world_top
#(
    parameter integer LOOP_WALLS = 3
)
(
    input                 clk,
    input                 reset,

    // ---- Match start ----
    input                 start,          // 1-cycle: build a new map from `seed`
    input          [15:0] seed,
    input                 is_hider,       // role of THIS board's player (from game logic)
    input                 respawn,        // 1-cycle: send the spawn to player_movement again

    // ---- Lower-priority write ports (hold *_we until *_wgrant) ----
    input                 portal_we,
    input          [7:0]  portal_waddr,   // y*10 + x
    input          [1:0]  portal_wdata,
    output                portal_wgrant,
    input                 cap_we,
    input          [7:0]  cap_waddr,
    input          [1:0]  cap_wdata,
    output                cap_wgrant,

    // ---- Read port for the AI bot (combinational) ----
    input          [3:0]  rd_x,
    input          [3:0]  rd_y,
    output         [1:0]  rd_type,        // 01 (wall) if (rd_x, rd_y) is off the map

    // ---- Map outputs ----
    output reg    [199:0] cells,          // to minimap_render, portal/capsule ctrl
    output        [99:0]  map_bits,       // to Raycast_3D_Engine and player_movement
    output                gen_busy,
    output reg            map_ready,      // level: map finished, writes accepted
    output                map_done,       // 1-cycle: map finished (same cycle as map_gen.done)

    // ---- Spawn: this board's player (to player_movement) ----
    output reg            load_pos,       // 1-cycle
    output reg signed [15:0] load_x,      // Q8.8 cell centre
    output reg signed [15:0] load_y,
    output reg     [7:0]  load_dir,       // 0 N, 64 E, 128 S, 192 W

    // ---- Spawn: the other player (for the AI bot), valid on the same load_pos ----
    output reg signed [15:0] opp_x,
    output reg signed [15:0] opp_y,
    output reg     [7:0]  opp_dir,

    // ---- Spawn cells (y*10 + x) for portal_ctrl / capsule_ctrl ----
    output         [6:0]  hider_cell,
    output         [6:0]  seeker_cell
);

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;
    localparam [7:0] DIR_N = 8'd0, DIR_E = 8'd64, DIR_S = 8'd128, DIR_W = 8'd192;

    // Corner cell indices (y*10 + x)
    localparam [6:0] C11 = 7'd11;   // (1,1)
    localparam [6:0] C71 = 7'd17;   // (7,1)  x = 7, y = 1
    localparam [6:0] C17 = 7'd71;   // (1,7)  x = 1, y = 7
    localparam [6:0] C77 = 7'd77;   // (7,7)

    // =====================================================================
    // Maze generator
    // =====================================================================
    wire       gen_done, gen_we;
    wire [7:0] gen_waddr;
    wire [1:0] gen_wdata;

    map_gen #(.LOOP_WALLS(LOOP_WALLS)) maze (
        .clk   (clk),
        .reset (reset),
        .start (start),
        .seed  (seed),
        .busy  (gen_busy),
        .done  (gen_done),
        .we    (gen_we),
        .waddr (gen_waddr),
        .wdata (gen_wdata)
    );

    assign map_done = gen_done;

    // map_ready: high from the cycle after done until the next start.
    always @(posedge clk) begin
        if (reset)         map_ready <= 1'b0;
        else if (start)    map_ready <= 1'b0;   // start wins over a done in the same cycle
        else if (gen_done) map_ready <= 1'b1;
    end

    // =====================================================================
    // Write arbitration
    // =====================================================================
    // map_gen only writes while busy, and busy means !map_ready, so map_gen
    // never collides with the other two.  `!start` closes the one cycle where
    // map_ready is still 1 but a new map has just been requested.
    wire wr_open = map_ready && !start;

    assign portal_wgrant = portal_we && wr_open && (portal_waddr < 8'd100);
    assign cap_wgrant    = cap_we    && wr_open && (cap_waddr    < 8'd100) && !portal_we;

    always @(posedge clk) begin
        if (reset)
            cells <= {100{T_WALL}};                         // all solid until the first map
        else if (gen_we)
            cells[{gen_waddr[6:0], 1'b0} +: 2] <= gen_wdata;   // {addr,0} = 2*addr
        else if (portal_wgrant)
            cells[{portal_waddr[6:0], 1'b0} +: 2] <= portal_wdata;
        else if (cap_wgrant)
            cells[{cap_waddr[6:0], 1'b0} +: 2] <= cap_wdata;
    end

    // =====================================================================
    // Engine format: bit (99 - i) = 1 when cell i is solid
    // =====================================================================
    genvar gi;
    generate
        for (gi = 0; gi < 100; gi = gi + 1) begin : g_map_bits
            assign map_bits[99 - gi] = (cells[2*gi +: 2] == T_WALL) ||
                                       (cells[2*gi +: 2] == T_PORTAL);
        end
    endgenerate

    // =====================================================================
    // Read port for the AI bot
    // =====================================================================
    wire       rd_in  = (rd_x <= 4'd9) && (rd_y <= 4'd9);
    wire [6:0] rd_idx = {rd_y, 3'b000} + {rd_y, 1'b0} + rd_x;    // y*8 + y*2 + x
    assign rd_type = rd_in ? cells[{rd_idx, 1'b0} +: 2] : T_WALL;

    // =====================================================================
    // Spawn selection (option B)
    // =====================================================================
    // Two layout bits taken from the seed at start.  XOR-reducing a byte uses
    // every bit of it, so these are not just a copy of map_gen's first coin flip.
    reg diag, swap;
    always @(posedge clk) begin
        if (reset) begin
            diag <= 1'b0;
            swap <= 1'b0;
        end else if (start) begin
            diag <= ^seed[15:8];
            swap <= ^seed[7:0];
        end
    end

    // Facing for one cell: first non-solid neighbour in the order E, S, W, N.
    // i is always one of the four constant corners, so each call reduces to a
    // few 2-bit compares on fixed bits of cells - no variable mux.
    function is_open (input [1:0] t);
        is_open = (t == T_FLOOR) || (t == T_CAPSULE);
    endfunction

    function [7:0] first_open (input [199:0] c, input [6:0] i);
        begin
            if      (is_open(c[2*(i + 7'd1)  +: 2])) first_open = DIR_E;
            else if (is_open(c[2*(i + 7'd10) +: 2])) first_open = DIR_S;
            else if (is_open(c[2*(i - 7'd1)  +: 2])) first_open = DIR_W;
            else if (is_open(c[2*(i - 7'd10) +: 2])) first_open = DIR_N;
            else                                     first_open = DIR_E;  // cannot happen: every room has a way out
        end
    endfunction

    wire [7:0] face11 = first_open(cells, C11);
    wire [7:0] face71 = first_open(cells, C71);
    wire [7:0] face17 = first_open(cells, C17);
    wire [7:0] face77 = first_open(cells, C77);

    // Corner A / B of the chosen diagonal
    wire [6:0] cell_a = diag ? C71 : C11;
    wire [6:0] cell_b = diag ? C17 : C77;
    wire [7:0] face_a = diag ? face71 : face11;
    wire [7:0] face_b = diag ? face17 : face77;

    assign hider_cell  = swap ? cell_b : cell_a;
    assign seeker_cell = swap ? cell_a : cell_b;
    wire [7:0] hider_face  = swap ? face_b : face_a;
    wire [7:0] seeker_face = swap ? face_a : face_b;

    wire [6:0] my_cell  = is_hider ? hider_cell  : seeker_cell;
    wire [6:0] opp_cell = is_hider ? seeker_cell : hider_cell;
    wire [7:0] my_face  = is_hider ? hider_face  : seeker_face;
    wire [7:0] opp_face = is_hider ? seeker_face : hider_face;

    // Corner x and y are only ever 1 or 7: x is 7 for cells 17 and 77,
    // y is 7 for cells 71 and 77.
    function [3:0] corner_x (input [6:0] i);
        corner_x = (i == C71 || i == C77) ? 4'd7 : 4'd1;
    endfunction
    function [3:0] corner_y (input [6:0] i);
        corner_y = (i == C17 || i == C77) ? 4'd7 : 4'd1;
    endfunction

    // Q8.8 centre of cell c = (c << 8) + 128 = {4'b0, c, 8'h80}
    function signed [15:0] centre (input [3:0] c);
        centre = {4'b0000, c, 8'h80};
    endfunction

    // load_pos fires the cycle after map_gen.done.  On the done cycle the last
    // cell write has already landed in `cells` (it was registered one edge
    // earlier), so the facing logic sees the complete map.
    always @(posedge clk) begin
        if (reset) begin
            load_pos <= 1'b0;
            load_x   <= 16'sd0;  load_y <= 16'sd0;  load_dir <= DIR_E;
            opp_x    <= 16'sd0;  opp_y  <= 16'sd0;  opp_dir  <= DIR_E;
        end else begin
            load_pos <= 1'b0;                                   // default: 1-cycle pulse
            if (gen_done || (respawn && map_ready && !start)) begin
                load_pos <= 1'b1;
                load_x   <= centre(corner_x(my_cell));
                load_y   <= centre(corner_y(my_cell));
                load_dir <= my_face;
                opp_x    <= centre(corner_x(opp_cell));
                opp_y    <= centre(corner_y(opp_cell));
                opp_dir  <= opp_face;
            end
        end
    end

endmodule