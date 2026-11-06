`timescale 1ns / 1ps

//world_top - holds the cell type array for the match 


module world_top
#(
    parameter integer LOOP_WALLS = 3
)
(
    input                 clk,
    input                 reset,

    // match start
    input                 start,         
    input          [15:0] seed,
    input                 is_hider, // role of THIS board's player (from game logic)
    input                 respawn, //send the spawn to player_movement 

    // lower priority write ports 
    input                 portal_we,
    input          [7:0]  portal_waddr,  
    input          [1:0]  portal_wdata,
    output                portal_wgrant,
    input                 cap_we,
    input          [7:0]  cap_waddr,
    input          [1:0]  cap_wdata,
    output                cap_wgrant,

    // read port for the AI bot (combinational)
    input          [3:0]  rd_x,
    input          [3:0]  rd_y,
    output         [1:0]  rd_type, // 01 (wall) if (rd_x, rd_y) is outside the map

    // map outputs
    output reg    [199:0] cells, // to minimap_render, portal/capsule ctrl
    output        [99:0]  map_bits, // to Raycast_3D_Engine and player_movement
    output                gen_busy,
    output reg            map_ready,  // stays 1 while map is done (writes allowed)
    output                map_done,   //  map done (same cycle as map_gen.done)

    // spawn for this board's player (to player_movement)
    output reg            load_pos,       
    output reg signed [15:0] load_x,      
    output reg signed [15:0] load_y,
    output reg     [7:0]  load_dir,  

    // spawn for the other player (for the AI bot), same timing as load_pos
    output reg signed [15:0] opp_x,
    output reg signed [15:0] opp_y,
    output reg     [7:0]  opp_dir,

    // other player's spawn corner, ready from 1 cycle after start
    // (only depends on seed + roles, doesn't wait for the maze)
    output signed  [15:0] opp_spawn_x,
    output signed  [15:0] opp_spawn_y,

    // spawn cells (y*10 + x) for portal_ctrl / capsule_ctrl
    output         [6:0]  hider_cell,
    output         [6:0]  seeker_cell
);

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;
    localparam [7:0] DIR_N = 8'd0, DIR_E = 8'd64, DIR_S = 8'd128, DIR_W = 8'd192;

    //corner cell index (y*10 + x)
    localparam [6:0] C11 = 7'd11;   
    localparam [6:0] C71 = 7'd17;   
    localparam [6:0] C17 = 7'd71;   
    localparam [6:0] C77 = 7'd77;  

    //maze generator (submachine)
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

    //map_ready: 1 from the cycle after done until the next start
    always @(posedge clk) begin
        if (reset)         map_ready <= 1'b0;
        else if (start)    map_ready <= 1'b0;   // start wins if done comes in the same cycle
        else if (gen_done) map_ready <= 1'b1;
    end

    
    //writes only allowed after map is done, not on start cycle
    wire wr_open = map_ready && !start;

    assign portal_wgrant = portal_we && wr_open && (portal_waddr < 8'd100);
    assign cap_wgrant    = cap_we    && wr_open && (cap_waddr    < 8'd100) && !portal_we;

    always @(posedge clk) begin
        if (reset)
            cells <= {100{T_WALL}};// all wall until the first map
        else if (gen_we)
            cells[{gen_waddr[6:0], 1'b0} +: 2] <= gen_wdata; 
        else if (portal_wgrant)
            cells[{portal_waddr[6:0], 1'b0} +: 2] <= portal_wdata;
        else if (cap_wgrant)
            cells[{cap_waddr[6:0], 1'b0} +: 2] <= cap_wdata;
    end

    //engine format: bit (99 - i) = 1 when cell i is solid
    genvar gi;
    generate
        for (gi = 0; gi < 100; gi = gi + 1) begin : g_map_bits
            assign map_bits[99 - gi] = (cells[2*gi +: 2] == T_WALL) ||
                                       (cells[2*gi +: 2] == T_PORTAL);
        end
    endgenerate

    //read port for the AI bot
    wire       rd_in  = (rd_x <= 4'd9) && (rd_y <= 4'd9);
    wire [6:0] rd_idx = {rd_y, 3'b000} + {rd_y, 1'b0} + rd_x;
    assign rd_type = rd_in ? cells[{rd_idx, 1'b0} +: 2] : T_WALL;

    //spawn selection
    //2 random bits from the seed
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

    //facing: first open neighbour, checks E, S, W, N
    function is_open (input [1:0] t);
        is_open = (t == T_FLOOR) || (t == T_CAPSULE);
    endfunction

    function [7:0] first_open (input [199:0] c, input [6:0] i);
        begin
            if      (is_open(c[2*(i + 7'd1)  +: 2])) first_open = DIR_E;
            else if (is_open(c[2*(i + 7'd10) +: 2])) first_open = DIR_S;
            else if (is_open(c[2*(i - 7'd1)  +: 2])) first_open = DIR_W;
            else if (is_open(c[2*(i - 7'd10) +: 2])) first_open = DIR_N;
            else                                     first_open = DIR_E;  // can't happen: every room has a way out
        end
    endfunction

    wire [7:0] face11 = first_open(cells, C11);
    wire [7:0] face71 = first_open(cells, C71);
    wire [7:0] face17 = first_open(cells, C17);
    wire [7:0] face77 = first_open(cells, C77);

    //corner A / B of the chosen diagonal
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

    //corner x and y are only ever 1 or 7
    //x = 7 for cells 17 and 77, y = 7 for cells 71 and 77
    function [3:0] corner_x (input [6:0] i);
        corner_x = (i == C71 || i == C77) ? 4'd7 : 4'd1;
    endfunction
    function [3:0] corner_y (input [6:0] i);
        corner_y = (i == C17 || i == C77) ? 4'd7 : 4'd1;
    endfunction

    
    function signed [15:0] centre (input [3:0] c);
        centre = {4'b0000, c, 8'h80};
    endfunction

    //other player's corner, available early
    assign opp_spawn_x = centre(corner_x(opp_cell));
    assign opp_spawn_y = centre(corner_y(opp_cell));

    //load spawn the cycle after map_gen done
    always @(posedge clk) begin
        if (reset) begin
            load_pos <= 1'b0;
            load_x   <= 16'sd0;  load_y <= 16'sd0;  load_dir <= DIR_E;
            opp_x    <= 16'sd0;  opp_y  <= 16'sd0;  opp_dir  <= DIR_E;
        end else begin
            load_pos <= 1'b0;// default 0, so it's a 1 cycle pulse
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