`timescale 1ns / 1ps
// Hardware breadth-first search over the grid map.
//
// Pulse start with a source cell. The engine fills a distance table: for every
// open cell, the number of steps to reach it from the source moving up, down,
// left or right around walls. Walls and unreachable cells read as 255.
//
// A bot uses it in two ways:
//   chase: search from the target; step to the neighbouring cell with a SMALLER
//          distance and you follow the shortest path to the target.
//   flee:  search from the threat; step to a neighbour with a LARGER distance.
//
// How it works: a queue holds cells waiting to be explored. Each cell taken from
// the front looks at its 4 neighbours, one per clock; any open neighbour not yet
// reached gets distance + 1 and joins the back of the queue. Each cell enters the
// queue at most once, so a 10x10 map finishes in about 600 clocks (0.1 ms).
//
// Map format matches the team's map_is_wall(): cell (x, y) is wall when
// map_bits[MAP_W*MAP_H - 1 - (y*MAP_W + x)] is 1.

module bfs_pathfinder
#(
    parameter integer MAP_W = 10,
    parameter integer MAP_H = 10
)
(
    input clk,
    input reset,
    input [MAP_W*MAP_H-1:0]map_bits,

    input start,
    input [3:0]src_x,
    input [3:0]src_y,
    output busy,
    output reg done = 1'b0,          // pulse when the table is complete

    input [3:0]query_x,
    input [3:0]query_y,
    output [7:0]query_dist           // 255 = wall, outside the map, or unreachable
);
    localparam integer CELLS = MAP_W * MAP_H;
    localparam [7:0]FAR = 8'd255;

    localparam [1:0]S_IDLE  = 2'd0;
    localparam [1:0]S_CLEAR = 2'd1;
    localparam [1:0]S_POP   = 2'd2;
    localparam [1:0]S_NEIGH = 2'd3;

    reg [7:0]distance [0:CELLS-1];
    reg [7:0]queue [0:CELLS-1];          // {y, x}
    reg [7:0]q_head;
    reg [7:0]q_tail;

    reg [1:0]state = S_IDLE;
    reg [7:0]clear_index;
    reg [3:0]sx, sy;                     // source cell
    reg [3:0]cx, cy;                     // cell being explored
    reg [7:0]cd;                         // its distance
    reg [1:0]neighbour;                  // 0 up, 1 right, 2 down, 3 left

    assign busy = (state != S_IDLE);

    // The map is passed in as an argument (not read directly) so that a combinational
    // assign using this function is re-evaluated when the map changes.
    function is_wall(input [CELLS-1:0]map, input [3:0]x, input [3:0]y);
        begin
            if (x >= MAP_W || y >= MAP_H)
                is_wall = 1'b1;
            else
                is_wall = map[CELLS - 1 - (y * MAP_W + x)];
        end
    endfunction

    // Current neighbour
    reg [3:0]nx, ny;
    reg n_inside;
    always @(*) begin
        nx = cx; ny = cy; n_inside = 1'b1;
        case (neighbour)
            2'd0: begin ny = cy - 4'd1; n_inside = (cy != 4'd0); end
            2'd1: begin nx = cx + 4'd1; n_inside = (cx != MAP_W - 1); end
            2'd2: begin ny = cy + 4'd1; n_inside = (cy != MAP_H - 1); end
            default: begin nx = cx - 4'd1; n_inside = (cx != 4'd0); end
        endcase
    end
    wire [7:0]n_index = ny * MAP_W + nx;
    wire n_new = n_inside && !is_wall(map_bits, nx, ny) && (distance[n_index] == FAR);

    // Read port for the bot
    wire query_inside = (query_x < MAP_W) && (query_y < MAP_H);
    wire [7:0]query_index = query_y * MAP_W + query_x;
    assign query_dist = query_inside ? distance[query_index] : FAR;

    always @(posedge clk) begin
        done <= 1'b0;

        if (reset) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        sx <= src_x;
                        sy <= src_y;
                        clear_index <= 8'd0;
                        state <= S_CLEAR;
                    end
                end

                // Mark every cell unreached, then put the source in the queue
                S_CLEAR: begin
                    distance[clear_index] <= FAR;
                    if (clear_index == CELLS - 1) begin
                        if (sx < MAP_W && sy < MAP_H && !is_wall(map_bits, sx, sy)) begin
                            distance[sy * MAP_W + sx] <= 8'd0;
                            queue[0] <= {sy, sx};
                            q_tail   <= 8'd1;
                        end else begin
                            q_tail   <= 8'd0;     // source is a wall: nothing reachable
                        end
                        q_head <= 8'd0;
                        state  <= S_POP;
                    end else begin
                        clear_index <= clear_index + 8'd1;
                    end
                end

                // Take the next cell from the front of the queue
                S_POP: begin
                    if (q_head == q_tail) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        {cy, cx}  <= queue[q_head];
                        cd        <= distance[queue[q_head][7:4] * MAP_W + queue[q_head][3:0]];
                        q_head    <= q_head + 8'd1;
                        neighbour <= 2'd0;
                        state     <= S_NEIGH;
                    end
                end

                // One neighbour per clock
                S_NEIGH: begin
                    if (n_new) begin
                        distance[n_index]  <= cd + 8'd1;
                        queue[q_tail]  <= {ny, nx};
                        q_tail         <= q_tail + 8'd1;
                    end
                    if (neighbour == 2'd3)
                        state <= S_POP;
                    neighbour <= neighbour + 2'd1;
                end
            endcase
        end
    end
endmodule
