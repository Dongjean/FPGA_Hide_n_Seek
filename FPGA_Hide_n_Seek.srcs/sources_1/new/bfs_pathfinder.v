`timescale 1ns / 1ps

//BFS pathfinder
//Fills a table with the number of steps from a source cell to every open cell (255 = unreachable).
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
    output reg done = 1'b0,

    input [3:0]query_x,
    input [3:0]query_y,
    output [7:0]query_dist
);

    //Constants and states
    localparam integer CELLS = MAP_W * MAP_H;
    localparam [7:0]FAR = 8'd255;

    localparam [1:0]S_IDLE  = 2'd0;
    localparam [1:0]S_CLEAR = 2'd1;
    localparam [1:0]S_POP   = 2'd2;
    localparam [1:0]S_NEIGH = 2'd3;

    //Distance table, queue and registers
    reg [7:0]distance [0:CELLS-1];
    reg [7:0]queue [0:CELLS-1];
    reg [7:0]q_head;
    reg [7:0]q_tail;

    reg [1:0]state = S_IDLE;
    reg [7:0]clear_index;
    reg [3:0]sx, sy;
    reg [3:0]cx, cy;
    reg [7:0]cd;
    reg [1:0]neighbour;

    assign busy = (state != S_IDLE);

    //Wall lookup
    function is_wall(input [CELLS-1:0]map, input [3:0]x, input [3:0]y);
        begin
            if (x >= MAP_W || y >= MAP_H)
                is_wall = 1'b1;
            else
                is_wall = map[CELLS - 1 - (y * MAP_W + x)];
        end
    endfunction

    //Neighbour of the current cell
    //0 up, 1 right, 2 down, 3 left; n_new is high for an open cell not reached yet.
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

    //Read port for the bot
    wire query_inside = (query_x < MAP_W) && (query_y < MAP_H);
    wire [7:0]query_index = query_y * MAP_W + query_x;
    assign query_dist = query_inside ? distance[query_index] : FAR;

    //Search FSM
    //IDLE -> CLEAR (all cells unreached) -> POP (take a cell from the queue) <-> NEIGH (check 4 neighbours).
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

                S_CLEAR: begin
                    distance[clear_index] <= FAR;
                    if (clear_index == CELLS - 1) begin
                        if (sx < MAP_W && sy < MAP_H && !is_wall(map_bits, sx, sy)) begin
                            distance[sy * MAP_W + sx] <= 8'd0;
                            queue[0] <= {sy, sx};
                            q_tail   <= 8'd1;
                        end else begin
                            q_tail   <= 8'd0;
                        end
                        q_head <= 8'd0;
                        state  <= S_POP;
                    end else begin
                        clear_index <= clear_index + 8'd1;
                    end
                end

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
