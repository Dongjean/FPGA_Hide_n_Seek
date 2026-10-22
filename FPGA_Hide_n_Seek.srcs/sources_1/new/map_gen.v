`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// map_gen - 10x10 sidewinder maze generator (Andrew, world generation)
//
// Map layout (N = 10, matches Dongjin's DEFAULT_MAP size):
//   x/y = 0 and 9      : solid border, never touched
//   x/y = 1, 3, 5, 7-8 : room columns/rows 0..3 (the last one is 2 cells wide,
//                        so the spare line 8 is used instead of wasted)
//   x/y = 2, 4, 6      : wall lines between rooms (gaps 0..2); a "passage" is a
//                        gap cell that has been opened
//   gap x gap cells    : pillars, always solid
//
//   Room grid is 4 x 4 = 16 rooms.  There are 24 possible passages:
//     east_open [row*3 + gap] : 12 passages between horizontally adjacent rooms
//     north_open[gap*4 + col] : 12 passages between vertically adjacent rooms
//   A passage into a 2-wide room only opens the cell on its odd (primary) line.
//
// Algorithm:
//   1. Sidewinder: room row 0 is one long corridor (all east passages open).
//      For rows 1..3, walk left to right keeping a "run" of rooms.  At each room
//      flip a coin: carve east (extend the run) or close the run by carving north
//      from one random room in the run.  The last room in a row always closes.
//      Only run_start is remembered - no stack.  Every room ends up connected
//      to row 0 exactly once, so the result is a perfect maze (one path between
//      any two rooms, all rooms reachable).
//   2. Loops: open LOOP_WALLS randomly chosen passages that are still closed.
//      Only passage cells are opened, so the border and pillars stay solid.
//   3. Write-out: stream all 100 cells to the cell-type array, one per cycle.
//
// Randomness comes only from lfsr16 loaded with `seed` on `start`, stepped a
// fixed sequence of times, so the same seed always gives the same map.
//
// Cell index on the write port: waddr = y*10 + x (row-major, 0..99).
// The engine's map_bits index is 99 - waddr; world_top does that conversion.
// wdata: 2'b00 floor, 2'b01 wall (portals/capsules are added later by others).
//
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
// Run time: ~12 maze cycles + ~10 loop tries + 100 write cycles = ~20 us.
//////////////////////////////////////////////////////////////////////////////////
module map_gen
#(
    parameter integer LOOP_WALLS = 3    // extra passages to open (max 9: a perfect maze leaves 9 closed)
)
(
    input             clk,
    input             reset,     // synchronous, active-high
    input             start,     // 1-cycle pulse; restarts generation even if busy
    input      [15:0] seed,      // sampled on start
    output            busy,      // high from the cycle after start until done
    output reg        done,      // 1-cycle pulse after the last cell is written
    output reg        we,        // write enable to the cell-type array
    output reg [7:0]  waddr,     // y*10 + x
    output reg [1:0]  wdata      // 00 floor, 01 wall
);

    localparam [1:0] T_FLOOR = 2'b00;
    localparam [1:0] T_WALL  = 2'b01;

    // ---------------- FSM states ----------------
    localparam [2:0] S_IDLE  = 3'd0;   // wait for start
    localparam [2:0] S_ROWS  = 3'd1;   // sidewinder over room rows 1..3, one room per cycle
    localparam [2:0] S_LOOPS = 3'd2;   // open LOOP_WALLS extra passages
    localparam [2:0] S_WRITE = 3'd3;   // stream 100 cells to the array
    localparam [2:0] S_DONE  = 3'd4;   // pulse done, return to idle

    reg [2:0] state;

    // ---------------- Random source ----------------
    wire [15:0] r;                     // current random word
    wire        rnd_step = (state == S_ROWS) || (state == S_LOOPS);  // one new word per decision
    lfsr16 rng (.clk(clk), .reset(reset), .load(start), .seed(seed), .step(rnd_step), .out(r));

    // ---------------- Maze state (no stack: just these registers) ----------------
    reg [11:0] east_open;              // [row*3 + gap]  row 0..3, gap 0..2
    reg [11:0] north_open;             // [gap*4 + col]  gap 0..2, col 0..3
    reg [1:0]  ry;                     // current room row (1..3 during S_ROWS)
    reg [1:0]  rx;                     // current room column
    reg [1:0]  run_start;              // first room column of the current run
    reg [3:0]  removed;                // loop walls opened so far
    reg [5:0]  tries;                  // loop attempts so far (safety cap at 63)

    // ---------------- Write-out counters ----------------
    reg [6:0]  addr;                   // 0..99
    reg [3:0]  wx, wy;                 // x, y of addr

    assign busy = (state != S_IDLE);

    // ---------------- Sidewinder decision for this cycle ----------------
    // Coin flip: carve east unless we are at the last column.
    wire       carve_east = (rx != 2'd3) && r[0];
    // Run length 1..4.  Pick a random room in the run without a divider:
    // r[4:1] is uniform in 0..15; (r4 * len) >> 4 maps it onto 0..len-1.
    wire [2:0] run_len  = {1'b0, rx} - {1'b0, run_start} + 3'd1;
    wire [6:0] pick_mul = r[4:1] * run_len;          // max 15*4 = 60, fits 7 bits
    wire [1:0] pick_col = run_start + pick_mul[5:4]; // = run_start + floor(r4*len/16)

    // Flat indices (multiplies by constants become shifts/adds)
    wire [3:0] east_idx  = {ry, 1'b0} + ry + rx;        // ry*3 + rx  (gap east of rx)
    wire [3:0] north_idx = {ry - 2'd1, 2'b00} + pick_col; // (ry-1)*4 + pick_col

    // ---------------- Loop-wall candidate ----------------
    // r[9:5] uniform 0..31; (r5 * 24) >> 5 maps to 0..23.
    // 0..11 = east_open[k], 12..23 = north_open[k-12].
    wire [9:0] cand_mul = r[9:5] * 10'd24;
    wire [4:0] cand     = cand_mul[9:5];
    wire       cand_is_east  = (cand < 5'd12);
    wire [3:0] cand_n_idx    = cand - 5'd12;            // only used when !cand_is_east
    wire       cand_closed   = cand_is_east ? !east_open[cand[3:0]] : !north_open[cand_n_idx];

    // ---------------- Coordinate decode for write-out ----------------
    // Returns {is_room, is_gap, is_primary, idx[1:0]} for one coordinate.
    //   is_room   : coordinate lies on a room line (1,3,5,7,8)
    //   is_gap    : coordinate lies on a wall line between rooms (2,4,6)
    //   is_primary: the odd line of a room (8 is the secondary half of room 3)
    //   idx       : room index 0..3 or gap index 0..2
    function [4:0] decode (input [3:0] c);
        begin
            case (c)
                4'd1: decode = 5'b101_00;
                4'd2: decode = 5'b010_00;
                4'd3: decode = 5'b101_01;
                4'd4: decode = 5'b010_01;
                4'd5: decode = 5'b101_10;
                4'd6: decode = 5'b010_10;
                4'd7: decode = 5'b101_11;
                4'd8: decode = 5'b100_11;   // room 3, secondary line
                default: decode = 5'b000_00; // 0 and 9: border
            endcase
        end
    endfunction

    wire [4:0] dx = decode(wx);
    wire [4:0] dy = decode(wy);
    wire [3:0] e_cell_idx = {dy[1:0], 1'b0} + dy[1:0] + dx[1:0];  // row*3 + gap
    wire [3:0] n_cell_idx = {dy[1:0], 2'b00} + dx[1:0];           // gap*4 + col

    reg [1:0] cell_type;
    always @(*) begin
        if (dx[4] && dy[4])                       // room x room: always floor
            cell_type = T_FLOOR;
        else if (dx[3] && dy[4])                  // horizontal passage cell
            cell_type = (dy[2] && east_open[e_cell_idx])  ? T_FLOOR : T_WALL;
        else if (dx[4] && dy[3])                  // vertical passage cell
            cell_type = (dx[2] && north_open[n_cell_idx]) ? T_FLOOR : T_WALL;
        else                                      // border or pillar
            cell_type = T_WALL;
    end

    // ---------------- FSM ----------------
    always @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            we         <= 1'b0;
            waddr      <= 8'd0;
            wdata      <= T_WALL;
            east_open  <= 12'd0;
            north_open <= 12'd0;
            ry <= 2'd0; rx <= 2'd0; run_start <= 2'd0;
            removed <= 4'd0; tries <= 6'd0;
            addr <= 7'd0; wx <= 4'd0; wy <= 4'd0;
        end else if (start) begin
            // (lfsr16 loads the seed this same cycle via .load(start))
            state      <= S_ROWS;
            done       <= 1'b0;
            we         <= 1'b0;
            east_open  <= 12'b000_000_000_111;  // row 0: one long corridor
            north_open <= 12'd0;
            ry <= 2'd1; rx <= 2'd0; run_start <= 2'd0;
            removed <= 4'd0; tries <= 6'd0;
            addr <= 7'd0; wx <= 4'd0; wy <= 4'd0;
        end else begin
            done <= 1'b0;   // default: 1-cycle pulse
            we   <= 1'b0;   // default: no write
            case (state)
                S_IDLE: ;   // wait for start

                S_ROWS: begin
                    if (carve_east) begin
                        east_open[east_idx] <= 1'b1;         // extend the run east
                        rx <= rx + 2'd1;
                    end else begin
                        north_open[north_idx] <= 1'b1;       // close run: carve north from one room
                        if (rx == 2'd3) begin
                            rx <= 2'd0;
                            run_start <= 2'd0;
                            if (ry == 2'd3) state <= S_LOOPS; // all rows done
                            else            ry <= ry + 2'd1;
                        end else begin
                            rx        <= rx + 2'd1;
                            run_start <= rx + 2'd1;          // next run starts after this room
                        end
                    end
                end

                S_LOOPS: begin
                    if (removed == LOOP_WALLS || tries == 6'd63) begin
                        state <= S_WRITE;                    // (rng stops stepping next cycle)
                    end else begin
                        tries <= tries + 6'd1;
                        if (cand_closed) begin               // only count walls that were closed
                            if (cand_is_east) east_open[cand[3:0]] <= 1'b1;
                            else              north_open[cand_n_idx] <= 1'b1;
                            removed <= removed + 4'd1;
                        end
                    end
                end

                S_WRITE: begin
                    we    <= 1'b1;
                    waddr <= {1'b0, addr};
                    wdata <= cell_type;
                    if (addr == 7'd99) begin
                        state <= S_DONE;
                    end else begin
                        addr <= addr + 7'd1;
                        if (wx == 4'd9) begin wx <= 4'd0; wy <= wy + 4'd1; end
                        else              wx <= wx + 4'd1;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;   // seen one cycle after the last write (addr 99)
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule