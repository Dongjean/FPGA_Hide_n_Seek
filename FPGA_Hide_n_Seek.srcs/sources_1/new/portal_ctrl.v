`timescale 1ns / 1ps

//portal_ctrl - warp portals

module portal_ctrl
#(
    parameter integer NUM_PAIRS      = 1,          
    parameter integer ALLOW_THROUGH  = 1,          //1 = allow 2 sided portals in the middle of a wall
    parameter integer COOLDOWN       = 18_750_000, 
    parameter integer MAX_TRIES      = 1023,       //random tries before we just scan in order
    parameter integer MIN_SPAWN_DIST = 4,          
    parameter integer MIN_PAIR_DIST  = 4,         
    parameter [15:0]  SEED_XOR       = 16'h5A3C    //so the randoms aren't the same as map_gen's
)
(
    input                    clk,
    input                    reset,

    //from world_top
    input                    start,          
    input             [15:0] seed,           
    input                    map_done,       
    input            [199:0] cells,         
    input             [6:0]  hider_cell,    
    input             [6:0]  seeker_cell,

    //write port to world_top
    output reg               portal_we,
    output reg        [7:0]  portal_waddr,   
    output            [1:0]  portal_wdata,   
    input                    portal_wgrant,

    //from player_movement
    input                    bump,           
    input             [3:0]  bump_cx,        //the cell we bumped
    input             [3:0]  bump_cy,
    input                    game_paused,    //cooldown freezes when paused

    //teleport
    output reg               tp_load,      
    output reg signed [15:0] tp_x,           
    output reg signed [15:0] tp_y,
    output reg        [7:0]  tp_dir,         

    //status, also for capsule_ctrl
    output reg               portals_ready,  
    output reg        [1:0]  pair_valid,     
    output            [27:0] portal_cells,   
    output            [27:0] exit_cells     
);

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;
    localparam [7:0] DIR_N = 8'd0, DIR_E = 8'd64, DIR_S = 8'd128, DIR_W = 8'd192;
    localparam [2:0] LAST  = 2*NUM_PAIRS - 1;   //last portal index we need

    //states
    localparam [2:0] S_IDLE   = 3'd0,   //wait for map_done
                     S_RANDOM = 3'd1,   //try random cells from the lfsr
                     S_SCAN   = 3'd2,   //backup, go through every cell in order
                     S_WRITE  = 3'd3,   //write portals into world_top
                     S_READY  = 3'd4;   //teleports on

    assign portal_wdata = T_PORTAL;

    //randoms
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

    //portals we found (0-3)
    reg [6:0] p_cell [0:3];     //portal cell
    reg [6:0] e_cell [0:3];     //where it spits you out
    reg [3:0] e_x    [0:3];     //exit x y, saved so we don't need /10 later
    reg [3:0] e_y    [0:3];
    reg [7:0] e_dir  [0:3];     //portal -> exit direction, so you face away
    reg [3:0] o_x    [0:3];     //other side, the entry side for a through portal
    reg [3:0] o_y    [0:3];
    reg [6:0] o_cell [0:3];
    reg [2:0] n_found;          

    assign portal_cells = {p_cell[3], p_cell[2], p_cell[1], p_cell[0]};
    assign exit_cells   = {e_cell[3], e_cell[2], e_cell[1], e_cell[0]};

    reg [2:0]  state;
    reg [9:0]  tries;
    reg [3:0]  scan_x, scan_y;
    reg [2:0]  wr_i;            //portal being written, 3 bits so it can hit 4

    //cell being checked
    wire [3:0] cx = (state == S_SCAN) ? scan_x : rnd[3:0];
    wire [3:0] cy = (state == S_SCAN) ? scan_y : rnd[7:4];

 
    function [1:0] type_at (input [199:0] c, input [4:0] x, input [4:0] y);
        reg [6:0] i;
        begin
            i = {y[3:0], 3'b000} + {y[3:0], 1'b0} + x[3:0];   //y*10 + x
            if (x > 5'd9 || y > 5'd9) type_at = T_WALL;
            else                      type_at = c[{i, 1'b0} +: 2];
        end
    endfunction

    function is_open (input [1:0] t);
        is_open = (t == T_FLOOR) || (t == T_CAPSULE);
    endfunction

    //|a - b|
    function [3:0] absdiff (input [3:0] a, input [3:0] b);
        absdiff = (a > b) ? (a - b) : (b - a);
    endfunction

    //get x y from cell index without dividing
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
            idx_x = i - ({y, 3'b000} + {y, 1'b0});
        end
    endfunction

    wire [3:0] hx = idx_x(hider_cell),  hy = idx_y(hider_cell);
    wire [3:0] sx = idx_x(seeker_cell), sy = idx_y(seeker_cell);

    //neighbours, E S W N
    wire [4:0] xe = {1'b0, cx} + 5'd1, xw = {1'b0, cx} - 5'd1;
    wire [4:0] ys = {1'b0, cy} + 5'd1, yn = {1'b0, cy} - 5'd1;
    wire open_e = is_open(type_at(cells, xe, {1'b0, cy}));
    wire open_s = is_open(type_at(cells, {1'b0, cx}, ys));
    wire open_w = is_open(type_at(cells, xw, {1'b0, cy}));
    wire open_n = is_open(type_at(cells, {1'b0, cx}, yn));
    wire [2:0] n_open = open_e + open_s + open_w + open_n;

    //what kind of wall is it
    wire one_side = (n_open == 3'd1);                              //dead end wall
    wire thru_ew  = open_e && open_w && !open_n && !open_s;        //corridor | wall | corridor
    wire thru_ns  = open_n && open_s && !open_e && !open_w;
    wire through  = (ALLOW_THROUGH != 0) && (thru_ew || thru_ns);
    wire side     = rnd[8];        
    //for through portals, 1 = exit E (or S), 0 = exit W (or N)
    //seeded so both boards pick the same
    
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

    wire [4:0] d_hider  = absdiff(ex, hx) + absdiff(ey, hy);
    wire [4:0] d_seeker = absdiff(ex, sx) + absdiff(ey, sy);
    wire far_from_spawns = (e_idx != hider_cell) && (e_idx != seeker_cell) &&
                           (d_hider  >= MIN_SPAWN_DIST) && (d_seeker >= MIN_SPAWN_DIST);

    //no if it overlaps a portal we already have
    function clash (input [6:0] pc, input [6:0] ec, input [6:0] oc,     //one we already have
                    input [6:0] c,  input [6:0] e,  input [6:0] o);     //the new one
        clash = (pc == c) || (ec == e) || (ec == o) || (oc == e) || (oc == o);
    endfunction
    wire used0 = (n_found > 3'd0) && clash(p_cell[0], e_cell[0], o_cell[0], c_idx, e_idx, o_idx);
    wire used1 = (n_found > 3'd1) && clash(p_cell[1], e_cell[1], o_cell[1], c_idx, e_idx, o_idx);
    wire used2 = (n_found > 3'd2) && clash(p_cell[2], e_cell[2], o_cell[2], c_idx, e_idx, o_idx);
    wire not_used = !(used0 || used1 || used2);

    //2nd portal in a pair can't be too close to the 1st
    wire [2:0] partner = n_found - 3'd1;
    wire [1:0] pt      = partner[1:0];
    wire [4:0] d_ee = absdiff(ex, e_x[pt]) + absdiff(ey, e_y[pt]);
    wire [4:0] d_eo = absdiff(ex, o_x[pt]) + absdiff(ey, o_y[pt]);
    wire [4:0] d_oe = absdiff(ox, e_x[pt]) + absdiff(oy, e_y[pt]);
    wire pair_ok = !n_found[0] || (state == S_SCAN) ||
                   (d_ee >= MIN_PAIR_DIST && d_eo >= MIN_PAIR_DIST && d_oe >= MIN_PAIR_DIST);

    wire good = in_map && !is_corner && is_wall && (one_side || through) &&
                far_from_spawns && not_used && pair_ok;

    //which portal did we walk into
    wire [6:0] b_idx = {bump_cy, 3'b000} + {bump_cy, 1'b0} + bump_cx;
    wire hit0 = pair_valid[0] && (b_idx == p_cell[0]);
    wire hit1 = pair_valid[0] && (b_idx == p_cell[1]);
    wire hit2 = pair_valid[1] && (b_idx == p_cell[2]);
    wire hit3 = pair_valid[1] && (b_idx == p_cell[3]);
    wire [1:0] dest = hit0 ? 2'd1 : hit1 ? 2'd0 : hit2 ? 2'd3 : 2'd2;

    reg [24:0] cooldown;        //counts down, 0 = can teleport

    integer k;

    //main fsm
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
            //new match, drop the old portals
            state         <= S_IDLE;
            rnd_step      <= 1'b0;
            portal_we     <= 1'b0;
            portals_ready <= 1'b0;
            pair_valid    <= 2'b00;
            tp_load       <= 1'b0;
            cooldown      <= 25'd0;
        end else begin
            tp_load  <= 1'b0;                
            rnd_step <= 1'b0;

            //cooldown ticks in every state, except when paused
            if (cooldown != 25'd0 && !game_paused)
                cooldown <= cooldown - 25'd1;

            case (state)
                S_IDLE: begin
                    if (map_done) begin
                        n_found  <= 3'd0;
                        tries    <= 10'd0;
                        rnd_step <= 1'b1;           //skip the raw seed
                        state    <= S_RANDOM;
                    end
                end

                //one random cell per try
                S_RANDOM: begin
                    rnd_step <= ~rnd_step;
                    tries    <= tries + 10'd1;
                    if (good && rnd_step == 1'b0) begin   //fresh value only
                        p_cell[n_found[1:0]] <= c_idx;
                        e_cell[n_found[1:0]] <= e_idx;
                        e_x[n_found[1:0]]    <= ex;
                        e_y[n_found[1:0]]    <= ey;
                        e_dir[n_found[1:0]]  <= edir;
                        o_x[n_found[1:0]]    <= ox;
                        o_y[n_found[1:0]]    <= oy;
                        o_cell[n_found[1:0]] <= o_idx;
                        n_found              <= n_found + 3'd1;
                        if (n_found == LAST) begin       //got the last one
                            wr_i  <= 3'd0;
                            state <= S_WRITE;
                        end
                    end else if (tries == MAX_TRIES) begin
                        scan_x <= 4'd0;
                        scan_y <= 4'd0;
                        state  <= S_SCAN;
                    end
                end

                //go through every cell, pair distance doesn't matter here
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

                //write portals into world_top one by one
                S_WRITE: begin
                    //full pairs only, 4 found = 2 pairs, 2 or 3 = 1 pair
                    
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
                        portal_we <= 1'b0;          //written on this edge, next one
                        wr_i      <= wr_i + 3'd1;
                    end
                end

                //teleporting
                S_READY: begin
                    if (bump && cooldown == 25'd0 && !game_paused &&
                        (hit0 || hit1 || hit2 || hit3)) begin
                        tp_load  <= 1'b1;
                        tp_x     <= {4'b0000, e_x[dest], 8'h80};   //centre = (c << 8) + 128
                        tp_y     <= {4'b0000, e_y[dest], 8'h80};
                        tp_dir   <= e_dir[dest];                   //face away from the portal
                        cooldown <= COOLDOWN;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule