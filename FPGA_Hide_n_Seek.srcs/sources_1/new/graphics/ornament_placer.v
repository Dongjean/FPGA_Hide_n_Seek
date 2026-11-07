`timescale 1ns / 1ps
// Places wall ornaments once per map
// A face is a wall cell + the side touching open floor, index = cell*4 + side
// side: 0 south, 1 north, 2 west, 3 east
// Door goes on the border behind the Seeker spawn, windows only on the border,
// other kinds at most once, no two decorated faces side by side along a wall
// Portal cells get the mirror in the engine, so nothing is placed on them
module ornament_placer (
    input              clk,
    input              reset,
    input              start,          // 1-cycle pulse when map_bits is ready
    input      [15:0]  seed,
    input      [99:0]  map_bits,       // 1 = solid, bit [99 - (y*10 + x)]
    input      [6:0]   spawn_cell,     // Seeker spawn, y*10 + x
    input      [7:0]   spawn_dir,      // 0 N, 64 E, 128 S, 192 W
    input      [99:0]  portal_bits,    // 1 = portal, bit [y*10 + x]
    output reg         busy,
    output reg [155:0] entries         // 12 x {kind[3:0], face[8:0]}, kind 0 = empty
);

    // kind: 1 bookcase, 2 door, 3 window, 4 clock, 5 fireplace, 6 mirror (portals only),
    //       7 painting, 8 skull, 9 small stand

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_COUNT  = 3'd1;
    localparam [2:0] S_SETUP  = 3'd2;
    localparam [2:0] S_DOOR   = 3'd3;
    localparam [2:0] S_CHOOSE = 3'd4;
    localparam [2:0] S_NEXT   = 3'd5;
    localparam [2:0] S_PROBE  = 3'd6;
    localparam [2:0] S_DONE   = 3'd7;

    localparam [15:0] SEED_MIX = 16'h3C5A;     // keeps it apart from the maze generator's numbers

    function [6:0] times10 (input [3:0] v);
        times10 = ({3'b000, v} << 3) + ({3'b000, v} << 1);
    endfunction

    // cell 0..99 to row, cell * 205 >> 11 is exact here
    function [3:0] cell_row (input [6:0] c);
        reg [14:0] m;
        begin
            m = c * 15'd205;
            cell_row = m[14:11];
        end
    endfunction

    // Wall face that touches open floor
    function face_exposed (input [3:0] x, input [3:0] y, input [1:0] c, input [99:0] mb);
        reg [6:0] c_idx;      // 'cell' is a Verilog keyword
        reg [6:0] n_idx;
        reg       inb;
        begin
            c_idx = times10(y) + {3'b000, x};
            case (c)
                2'd0:    begin inb = (y < 4'd9);   n_idx = c_idx + 7'd10; end
                2'd1:    begin inb = (y != 4'd0);  n_idx = c_idx - 7'd10; end
                2'd2:    begin inb = (x != 4'd0);  n_idx = c_idx - 7'd1;  end
                default: begin inb = (x < 4'd9);   n_idx = c_idx + 7'd1;  end
            endcase
            if (!inb)
                n_idx = c_idx;
            face_exposed = mb[7'd99 - c_idx] && inb && !mb[7'd99 - n_idx];
        end
    endfunction

    function is_border (input [3:0] x, input [3:0] y);
        is_border = (x == 4'd0) || (x == 4'd9) || (y == 4'd0) || (y == 4'd9);
    endfunction

    // Pool slot 1..6 to kind (slot 0 is the window, slot 7 is unused)
    function [3:0] kind_of (input [3:0] slot);
        case (slot)
            4'd1:    kind_of = 4'd1;
            4'd2:    kind_of = 4'd4;
            4'd3:    kind_of = 4'd5;
            4'd4:    kind_of = 4'd7;
            4'd5:    kind_of = 4'd8;
            default: kind_of = 4'd9;
        endcase
    endfunction

    reg [2:0]   state;
    reg [155:0] work;                 // entries being placed, new ones shift in at the bottom

    reg [3:0]   cx, cy;
    reg [1:0]   cc;
    reg [8:0]   f_count;              // exposed faces

    reg [3:0]   sp_x, sp_y;
    reg [7:0]   sp_dir;

    reg [3:0]   k_total;              // kinds to draw from the pool
    reg [2:0]   e_extra;              // extra windows
    reg [3:0]   got;
    reg [7:0]   chosen;               // pool slots drawn, slot 0 = window
    reg [2:0]   w_left;
    reg [3:0]   ki;
    reg [3:0]   cur_kind;
    reg [7:0]   tries;
    reg [3:0]   scan;                 // entries compared so far (work rotates one entry per clock)
    reg         clash;                // candidate face or its neighbour along the wall is used

    reg [3:0]   d_off;                // door slide offset
    reg         d_neg;

    // Random numbers, stepped only when a draw is used
    wire [15:0] lfsr_out;
    wire        lfsr_step = ((state == S_CHOOSE) && (got != k_total)) || ((state == S_PROBE) && (scan == 4'd11));
    lfsr16 rng (.clk(clk), .reset(reset), .load(start), .seed(seed ^ SEED_MIX),
                .step(lfsr_step), .out(lfsr_out));

    // Candidate face for a draw
    wire [8:0]  cand_idx   = lfsr_out[8:0];
    wire        cand_valid = (cand_idx < 9'd400);
    wire [6:0]  cand_cell  = cand_valid ? cand_idx[8:2] : 7'd0;
    wire [1:0]  cand_code  = cand_idx[1:0];
    wire [3:0]  cand_y     = cell_row(cand_cell);
    wire [6:0]  cand_x7    = cand_cell - times10(cand_y);
    wire [3:0]  cand_x     = cand_x7[3:0];
    wire [8:0]  cand_face  = {cand_cell, cand_code};

    // Placed entries are compared one per clock as work rotates past slot 0: the face itself,
    // and the faces either side along the same wall (south / north run along x, west / east along y)
    // At most 11 entries are placed, so the top slot is always empty when one shifts in
    wire [155:0] work_rot  = {work[12:0], work[155:13]};
    wire [12:0] scan_entry = work[12:0];
    wire [8:0]  scan_face  = scan_entry[8:0];
    wire        scan_clash = (scan_entry[12:9] != 4'd0) &&
                             ((scan_face == cand_face) ||
                              (!cand_code[1] && (cand_x != 4'd0) && (scan_face == cand_face - 9'd4))  ||
                              (!cand_code[1] && (cand_x <  4'd9) && (scan_face == cand_face + 9'd4))  ||
                              ( cand_code[1] && (cand_y != 4'd0) && (scan_face == cand_face - 9'd40)) ||
                              ( cand_code[1] && (cand_y <  4'd9) && (scan_face == cand_face + 9'd40)));

    // Door candidate, slides along the border until a face is exposed
    wire [3:0] door_base  = sp_dir[6] ? sp_y : sp_x;
    wire [4:0] door_plus  = {1'b0, door_base} + {1'b0, d_off};
    wire [4:0] door_minus = {1'b0, door_base} - {1'b0, d_off};
    wire       door_inrange = d_neg ? !door_minus[4] : (door_plus <= 5'd9);
    wire [3:0] door_t     = d_neg ? door_minus[3:0] : door_plus[3:0];

    reg [3:0] door_x, door_y;
    reg [1:0] door_c;
    always @(*) begin
        case (sp_dir[7:6])
            2'd1:    begin door_x = 4'd0;   door_y = door_t; door_c = 2'd3; end   // facing E, west border
            2'd3:    begin door_x = 4'd9;   door_y = door_t; door_c = 2'd2; end   // facing W, east border
            2'd2:    begin door_x = door_t; door_y = 4'd0;   door_c = 2'd0; end   // facing S, north border
            default: begin door_x = door_t; door_y = 4'd9;   door_c = 2'd1; end   // facing N, south border
        endcase
    end
    // One exposed-face test, shared by the count, the door and the probe
    wire [3:0] fe_x = (state == S_COUNT) ? cx : ((state == S_DOOR) ? door_x : cand_x);
    wire [3:0] fe_y = (state == S_COUNT) ? cy : ((state == S_DOOR) ? door_y : cand_y);
    wire [1:0] fe_c = (state == S_COUNT) ? cc : ((state == S_DOOR) ? door_c : cand_code);
    wire       exposed = face_exposed(fe_x, fe_y, fe_c, map_bits);

    wire cand_ok = cand_valid && exposed && !clash && !scan_clash && !portal_bits[cand_cell] &&
                   ((cur_kind != 4'd3) || is_border(cand_x, cand_y));

    wire door_ok = door_inrange && exposed &&
                   !portal_bits[times10(door_y) + {3'b000, door_x}];
    wire [8:0] door_face = {times10(door_y) + {3'b000, door_x}, door_c};

    // Ornament count = clamp(faces / 8, 3, 12)
    wire [5:0] f_div8 = f_count[8:3];
    wire [3:0] t_total = (f_div8 < 6'd3) ? 4'd3 : ((f_div8 > 6'd12) ? 4'd12 : f_div8[3:0]);

    always @(posedge clk) begin
        if (reset) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            entries  <= 156'd0;
            work     <= 156'd0;
            cx <= 4'd0; cy <= 4'd0; cc <= 2'd0; f_count <= 9'd0;
            sp_x <= 4'd1; sp_y <= 4'd1; sp_dir <= 8'd64;
            k_total <= 4'd0; e_extra <= 3'd0; got <= 4'd0; chosen <= 8'd0;
            w_left <= 3'd0; ki <= 4'd1; cur_kind <= 4'd0; tries <= 8'd0;
            scan <= 4'd0; clash <= 1'b0;
            d_off <= 4'd0; d_neg <= 1'b0;
        end else if (start) begin
            state    <= S_COUNT;
            busy     <= 1'b1;
            work     <= 156'd0;
            cx <= 4'd0; cy <= 4'd0; cc <= 2'd0; f_count <= 9'd0;
            sp_y     <= cell_row(spawn_cell);
            sp_x     <= spawn_cell[3:0] - times10(cell_row(spawn_cell));
            sp_dir   <= spawn_dir;
            got <= 4'd0; chosen <= 8'd0; w_left <= 3'd0; ki <= 4'd1; tries <= 8'd0;
            scan <= 4'd0; clash <= 1'b0;
            d_off <= 4'd0; d_neg <= 1'b0;
        end else begin
            case (state)
                S_IDLE: ;

                S_COUNT: begin
                    if (exposed)
                        f_count <= f_count + 9'd1;
                    if (cc != 2'd3) begin
                        cc <= cc + 2'd1;
                    end else begin
                        cc <= 2'd0;
                        if (cx == 4'd9) begin
                            cx <= 4'd0;
                            if (cy == 4'd9) state <= S_SETUP;
                            else            cy <= cy + 4'd1;
                        end else begin
                            cx <= cx + 4'd1;
                        end
                    end
                end

                S_SETUP: begin
                    k_total <= (t_total > 4'd8) ? 4'd7 : (t_total - 4'd1);
                    e_extra <= (t_total > 4'd9) ? (t_total - 4'd9) : 4'd0;   // portals take the mirror's place
                    state   <= S_DOOR;
                end

                S_DOOR: begin
                    if (door_ok) begin
                        work[0 +: 13] <= {4'd2, door_face};
                        state  <= S_CHOOSE;
                    end else if (!d_neg && d_off != 4'd0) begin
                        d_neg <= 1'b1;
                    end else if (d_off == 4'd9) begin
                        state <= S_CHOOSE;                       // no door
                    end else begin
                        d_neg <= 1'b0;
                        d_off <= d_off + 4'd1;
                    end
                end

                S_CHOOSE: begin
                    if (got == k_total) begin
                        w_left <= {2'b00, chosen[0]} + e_extra;
                        ki     <= 4'd1;
                        state  <= S_NEXT;
                    end else if ((lfsr_out[2:0] != 3'd7) && !chosen[lfsr_out[2:0]]) begin
                        chosen <= chosen | (8'd1 << lfsr_out[2:0]);
                        got    <= got + 4'd1;
                    end
                end

                S_NEXT: begin
                    if (w_left != 3'd0) begin
                        cur_kind <= 4'd3;
                        w_left   <= w_left - 3'd1;
                        tries    <= 8'd0;
                        state    <= S_PROBE;
                    end else if (ki <= 4'd6) begin
                        if (chosen[ki[2:0]]) begin
                            cur_kind <= kind_of(ki);
                            tries    <= 8'd0;
                            state    <= S_PROBE;
                        end
                        ki <= ki + 4'd1;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_PROBE: begin
                    if (scan != 4'd11) begin
                        clash <= clash | scan_clash;
                        scan  <= scan + 4'd1;
                        work  <= work_rot;
                    end else begin
                        // all 12 entries seen (work is back in place): decide on this candidate
                        clash <= 1'b0;
                        scan  <= 4'd0;
                        if (cand_ok) begin
                            work  <= {work_rot[142:0], cur_kind, cand_idx};
                            state <= S_NEXT;
                        end else begin
                            work  <= work_rot;
                            if (tries == 8'd255)
                                state <= S_NEXT;                 // gave up on this one
                            else
                                tries <= tries + 8'd1;
                        end
                    end
                end

                S_DONE: begin
                    entries <= work;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


// Ornament kind on a face, 0 = none
module ornament_lookup (
    input  [155:0] entries,
    input  [8:0]   face,          // cell * 4 + side
    output [3:0]   tex
);
    wire [47:0] picked;
    genvar i;
    generate
        for (i = 0; i < 12; i = i + 1) begin : slot
            wire [3:0] kind  = entries[13 * i + 9 +: 4];
            wire [8:0] where = entries[13 * i +: 9];
            assign picked[4 * i +: 4] = ((kind != 4'd0) && (where == face)) ? kind : 4'd0;
        end
    endgenerate

    assign tex = picked[3:0]   | picked[7:4]   | picked[11:8]  | picked[15:12] |
                 picked[19:16] | picked[23:20] | picked[27:24] | picked[31:28] |
                 picked[35:32] | picked[39:36] | picked[43:40] | picked[47:44];
endmodule
