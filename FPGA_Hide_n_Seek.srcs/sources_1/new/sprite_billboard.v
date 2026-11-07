`timescale 1ns / 1ps
// Billboard sprite with 8 facing directions, 48x48 per frame
// spr_obj: 0 hunter, 1 armchair, 2 candelabra, 3 phonograph
// Frames per object: S, SE, E, NE, N, NW, W, SW, palette index 0 = transparent
// Frames 32..47: hunter walk A then walk B, same direction order
// Frames 48..63: held-item layer for the hunter (48..55 empty, the shotgun is in his frames; then detector) per direction,
// 64..65: hider layer (snowflake, flashbang), drawn over the frame with palettes 4 and 5
// Hunter walks while it is moving, hiders float up and down
// SINGLE_VIEW = 1: one floating frame for every direction (time capsule)
module sprite_billboard #(
    parameter integer CLK_HZ      = 6_250_000,
    parameter integer SINGLE_VIEW = 0,
    parameter integer ROM_DEPTH   = 152064,         // frames * 48 * 48
    parameter         IDX_MEM     = "sprite_idx.mem",
    parameter         PAL_MEM     = "sprite_pal.mem",
    parameter         PAL_LIT_MEM = "sprite_pal_lit.mem"
)(
    input clk,
    input reset,

    // pose of the frame on screen
    input signed [15:0] cam_x,       // Q8.8
    input signed [15:0] cam_y,
    input        [7:0]  cam_dir,

    input               spr_enable,
    input        [1:0]  spr_obj,
    input signed [15:0] spr_x,       // Q8.8
    input signed [15:0] spr_y,
    input        [7:0]  spr_facing,  // 0 north, 64 east
    input        [1:0]  spr_hand,    // 0 empty, 1 gun ready, 2 item ready

    input        [6:0]  pixel_x,
    input        [5:0]  pixel_y,
    input               frame_begin,
    input        [7:0]  wall_dist,   // wall distance in this column
    input               lit,         // use the +40 % palette
    input        [7:0]  centre_wall_dist,   // wall distance in column 48

    output              hit,         // draw colour instead of the wall
    output       [7:0]  dist,        // for ordering sprites
    output       [15:0] colour,
    output              crosshair_hit,
    output reg          sprite_visible // at least one sprite texel was drawn in the last OLED frame
);

    `include "trig_LUT.vh"
    `include "wall_helpers.vh"
    `include "gfx_helpers.vh"

    // Get the distance between the camera and sprite
    wire signed [15:0] rel_x = spr_x - cam_x;
    wire signed [15:0] rel_y = spr_y - cam_y;

    // Get the distance between the camera and sprite, accounting for the direction the camera is facing
    wire signed [7:0]  sin_d = sin_lut(cam_dir);
    wire signed [7:0]  cos_d = cos_lut(cam_dir);
    wire signed [23:0] rel_fwd   = rel_x * sin_d - rel_y * cos_d;
    wire signed [23:0] rel_right = rel_x * cos_d + rel_y * sin_d;

    // Binary search for the sprite's screen column
    reg [3:0]          state;        // 0 load, 1..8 search, 9 publish
    reg signed [23:0]  fwd;
    reg signed [23:0]  right;
    reg signed [9:0]   lo;
    reg signed [9:0]   hi;

    wire signed [9:0]  mid = (lo + hi) >>> 1;
    wire        [7:0]  mid_angle = col_to_angle(mid);
    wire signed [7:0]  sin_m = sin_lut(mid_angle);
    wire signed [7:0]  cos_m = cos_lut(mid_angle);
    wire signed [31:0] cross = right * cos_m - fwd * sin_m;
    wire sprite_right_of_mid = ~cross[31];

    // Distance, long leg + 3/8 short leg
    wire [23:0] abs_fwd   = fwd[23]   ? (~fwd   + 24'd1) : fwd;
    wire [23:0] abs_right = right[23] ? (~right + 24'd1) : right;
    wire        fwd_bigger = (abs_fwd > abs_right);
    wire [23:0] long_leg  = fwd_bigger ? abs_fwd   : abs_right;
    wire [23:0] short_leg = fwd_bigger ? abs_right : abs_fwd;
    wire [23:0] length_x64 = long_leg + (short_leg >> 2) + (short_leg >> 3);
    wire [13:0] dist_full  = length_x64[23:10];     // to 1/16 cell steps
    wire        dist_ok    = (dist_full[13:7] == 7'd0);
    wire [7:0]  dist_steps = (dist_full[6:0] == 7'd0) ? 8'd1 : {1'b0, dist_full[6:0]};

    wire [5:0]  half_height = wall_half_height({2'b00, dist_steps});
    wire [6:0]  size   = {1'b0, half_height} + {2'b00, half_height[5:1]};   // 1.5 x
    wire [5:0]  top_row = 6'd32 - {1'b0, half_height[5:1]};
    wire signed [9:0]  centre_col = lo - 10'sd1;    // search ends on the last column of an angle step
    wire signed [10:0] left_col = centre_col - $signed({4'b0000, size[6:1]});
    wire signed [10:0] right_edge = left_col + $signed({4'b0000, size});

    wire        in_view = ~fwd[23] && (fwd != 24'sd0) && dist_ok &&
                          (left_col <= 11'sd95) && (right_edge > 11'sd0);

    // Frame from the sprite's facing against the direction back to the camera
    wire [7:0]  bearing   = cam_dir + col_to_angle(lo);
    wire [7:0]  turn      = bearing + 8'd128 - spr_facing + 8'd16;
    wire [2:0]  dir_index = turn[7:5];

    // Hunter moving: position changed within the last 4 samples (1/4 s)
    localparam integer SAMPLE_CLKS = CLK_HZ / 16;
    localparam integer STEP_CLKS   = CLK_HZ / 4;        // one step per walk frame
    localparam integer BOB_CLKS    = CLK_HZ * 3 / 40;   // 32 steps = 2.4 s float period

    reg [31:0]        sample_count = 32'd0;
    reg [31:0]        step_count   = 32'd0;
    reg [31:0]        bob_count    = 32'd0;
    reg signed [15:0] last_x = 16'sd0;
    reg signed [15:0] last_y = 16'sd0;
    reg [2:0]         move_hold = 3'd0;
    reg               walk_phase = 1'b0;
    reg [4:0]         bob_step = 5'd0;

    wire moving = (move_hold != 3'd0);

    always @(posedge clk) begin
        if (sample_count == SAMPLE_CLKS - 1) begin
            sample_count <= 32'd0;
            last_x <= spr_x;
            last_y <= spr_y;
            if ((spr_x != last_x) || (spr_y != last_y))
                move_hold <= 3'd4;
            else if (move_hold != 3'd0)
                move_hold <= move_hold - 3'd1;
        end else begin
            sample_count <= sample_count + 32'd1;
        end

        if (!moving) begin
            step_count <= 32'd0;
            walk_phase <= 1'b0;
        end else if (step_count == STEP_CLKS - 1) begin
            step_count <= 32'd0;
            walk_phase <= ~walk_phase;
        end else begin
            step_count <= step_count + 32'd1;
        end

        if (bob_count == BOB_CLKS - 1) begin
            bob_count <= 32'd0;
            bob_step  <= bob_step + 5'd1;
        end else begin
            bob_count <= bob_count + 32'd1;
        end
    end

    // Float height in 1/256 texel, 0..4 texels, (1 - cos) / 2 shape
    function [10:0] bob_height (input [4:0] k);
        reg [4:0] q;
        begin
            q = k[4] ? (5'd0 - k) : k;      // mirror the second half
            case (q)
                5'd0:  bob_height = 11'd0;
                5'd1:  bob_height = 11'd10;
                5'd2:  bob_height = 11'd39;
                5'd3:  bob_height = 11'd86;
                5'd4:  bob_height = 11'd150;
                5'd5:  bob_height = 11'd228;
                5'd6:  bob_height = 11'd316;
                5'd7:  bob_height = 11'd412;
                5'd8:  bob_height = 11'd512;
                5'd9:  bob_height = 11'd612;
                5'd10: bob_height = 11'd708;
                5'd11: bob_height = 11'd796;
                5'd12: bob_height = 11'd874;
                5'd13: bob_height = 11'd938;
                5'd14: bob_height = 11'd985;
                5'd15: bob_height = 11'd1014;
                default: bob_height = 11'd1024;
            endcase
        end
    endfunction

    // Held for the whole frame
    reg                visible;
    reg signed [10:0]  box_left;
    reg [5:0]          box_top;
    reg [6:0]          box_size;
    reg [10:0]         box_step;
    reg [6:0]          box_frame;     // ROM frame 0..47
    reg [1:0]          box_obj;
    reg [6:0]          box_item;      // item layer frame
    reg                box_item_on;
    reg [7:0]          box_dist;

    always @(posedge clk) begin
        if (reset) begin
            state    <= 4'd0;
            visible  <= 1'b0;
            box_left <= 11'sd0;
            box_top  <= 6'd0;
            box_size <= 7'd0;
            box_step <= 11'd0;
            box_frame <= 7'd0;
            box_obj  <= 2'd0;
            box_item <= 7'd0;
            box_item_on <= 1'b0;
            box_dist <= 8'd0;
        end else begin
            case (state)
            
                // Binary Search Start
                4'd0: begin
                    fwd   <= rel_fwd;
                    right <= rel_right;
                    lo    <= -10'sd64;
                    hi    <= 10'sd192;
                    state <= 4'd1;
                end

                // Binary Search Over
                4'd9: begin
                    visible   <= spr_enable && in_view;
                    box_left  <= left_col;
                    box_top   <= top_row;
                    box_size  <= size;
                    box_step  <= sprite_tex_step(half_height);
                    box_frame <= (SINGLE_VIEW != 0)            ? 7'd0 :
                                 ((spr_obj == 2'd0) && moving) ? {3'b010, walk_phase, dir_index}
                                                               : {2'b00, spr_obj, dir_index};
                    box_item  <= (spr_obj == 2'd0) ? {3'b011, spr_hand[1], dir_index}
                                                   : {6'b100000, spr_hand[1]};
                    box_item_on <= (SINGLE_VIEW == 0) && (spr_hand != 2'd0);
                    box_obj   <= (SINGLE_VIEW != 0) ? 2'd0 : spr_obj;
                    box_dist  <= dist_steps;
                    state     <= 4'd0;
                end

                // Continue Binary Search
                default: begin
                    if (sprite_right_of_mid)
                        lo <= mid;
                    else
                        hi <= mid;
                    state <= state + 4'd1;
                end
            endcase
        end
    end

    wire signed [10:0] dx = $signed({4'b0000, pixel_x}) - box_left;
    wire signed [10:0] dy = $signed({5'b00000, pixel_y}) - $signed({5'b00000, box_top});
    wire signed [10:0] size_signed = $signed({4'b0000, box_size});
    wire in_box = visible && !dx[10] && !dy[10] && (dx < size_signed) && (dy < size_signed);

    wire [16:0] u_scaled = dx[5:0] * box_step + {7'd0, box_step[10:1]};
    // Hiders sample lower texel rows to float up, the box itself does not move
    wire [10:0] bob = ((SINGLE_VIEW != 0) || (box_obj != 2'd0)) ? bob_height(bob_step) : 11'd0;
    wire [16:0] v_scaled = dy[5:0] * box_step + {7'd0, box_step[10:1]} + {6'd0, bob};
    wire [5:0]  tex_u = u_scaled[13:8];
    wire [5:0]  tex_v = v_scaled[13:8];
    wire        v_in  = (tex_v < 6'd48);

    // frame * 2304 + v * 48 + u
    wire [17:0] frame_base = ({11'd0, box_frame} << 11) + ({11'd0, box_frame} << 8);
    wire [17:0] item_base  = ({11'd0, box_item}  << 11) + ({11'd0, box_item}  << 8);
    wire [17:0] row_base   = ({12'd0, tex_v} << 5) + ({12'd0, tex_v} << 4);
    wire        draw_px    = in_box && v_in;
    wire [17:0] sprite_addr = draw_px ? (frame_base + row_base + {12'd0, tex_u}) : 18'd0;
    wire [17:0] item_addr   = (draw_px && box_item_on) ? (item_base + row_base + {12'd0, tex_u}) : 18'd0;

    (* rom_style = "block" *) reg [3:0] sprite_texel [0:ROM_DEPTH-1];
    reg [15:0] sprite_palette     [0:127];
    reg [15:0] sprite_palette_lit [0:127];
    initial begin
        $readmemh(IDX_MEM,     sprite_texel);
        $readmemh(PAL_MEM,     sprite_palette);
        $readmemh(PAL_LIT_MEM, sprite_palette_lit);
    end

    // Synchronous read for block RAM, the OLED pixel index holds for 16 clocks
    // Second read port for the item layer
    reg [3:0] texel;
    reg [3:0] item_texel;
    always @(posedge clk) begin
        texel      <= sprite_texel[sprite_addr];
        item_texel <= sprite_texel[item_addr];
    end

    // `visible` only means that the sprite's box is inside the camera's view;
    // it can still be completely hidden by a wall.  Accumulate hit over
    // one OLED scan instead, so sprite_visible says that an opaque texel really
    // passed the wall-depth test and appeared in the rendered 3-D view.
    // At a new frame boundary, publish the complete previous scan and start the
    // next one.  Gameplay therefore uses a stable, one-frame-delayed result.
    reg sprite_seen_this_frame;
    always @(posedge clk) begin
        if (reset) begin
            sprite_seen_this_frame <= 1'b0;
            sprite_visible         <= 1'b0;
        end else if (frame_begin) begin
            sprite_visible         <= sprite_seen_this_frame;
            sprite_seen_this_frame <= hit;
        end else if (hit) begin
            sprite_seen_this_frame <= 1'b1;
        end
    end

    wire       item_px      = box_item_on && (item_texel != 4'd0);
    wire [6:0] palette_addr = item_px ? {2'b10, (box_obj != 2'd0), item_texel}       // palette 4 hunter, 5 hider
                                      : {1'b0, box_obj, texel};
    wire [4:0] shade = wall_shade_for_distance({2'b00, box_dist});

    // Crosshair hit logic
    // Crosshair is column 48, row 32, in front of the wall, within 4 cells
    // Hitbox in sprite pixels so it scales with distance, centred on the 48x48 frame:
    // hiders 24x24 (texels 12..35), hunter 50x50 (texels -1..48)
    localparam [7:0] SHOT_RANGE = 8'd64;
    wire signed [10:0] cross_rel = 11'sd48 - box_left;
    wire signed [10:0] cross_row = 11'sd32 - $signed({5'b00000, box_top});
    wire signed [11:0] step_s    = $signed({1'b0, box_step});
    wire signed [23:0] cross_us  = cross_rel * step_s + $signed({14'd0, box_step[10:1]});
    wire signed [23:0] cross_vs  = cross_row * step_s + $signed({14'd0, box_step[10:1]});
    wire signed [15:0] cross_u   = cross_us >>> 8;     // crosshair in sprite texels
    wire signed [15:0] cross_v   = cross_vs >>> 8;
    wire signed [15:0] hb_lo     = (box_obj == 2'd0) ? -16'sd1 : 16'sd12;
    wire signed [15:0] hb_hi     = (box_obj == 2'd0) ?  16'sd49 : 16'sd36;
    assign crosshair_hit = visible &&
                           (cross_u >= hb_lo) && (cross_u < hb_hi) &&
                           (cross_v >= hb_lo) && (cross_v < hb_hi) &&
                           (box_dist < centre_wall_dist) && (box_dist <= SHOT_RANGE);

    assign dist   = box_dist;
    assign hit    = draw_px && ((texel != 4'd0) || item_px) && (box_dist < wall_dist);
    wire [15:0] base_colour = lit ? sprite_palette_lit[palette_addr] : sprite_palette[palette_addr];
    assign colour = shade_rgb565(base_colour, shade);

endmodule