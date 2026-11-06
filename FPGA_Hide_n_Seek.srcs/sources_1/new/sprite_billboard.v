`timescale 1ns / 1ps
// Billboard sprite with 8 facing directions, 48x48 per frame
// spr_obj: 0 hunter, 1 armchair, 2 candelabra, 3 phonograph
// Frames per object: S, SE, E, NE, N, NW, W, SW, palette index 0 = transparent
module sprite_billboard (
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

    input        [6:0]  pixel_x,
    input        [5:0]  pixel_y,
    input        [7:0]  wall_dist,   // wall distance in this column
    input               lit,         // use the +40 % palette
    input        [7:0]  centre_wall_dist,   // wall distance in column 48

    output              hit,         // draw colour instead of the wall
    output       [15:0] colour,
    output              crosshair_hit
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

    // Held for the whole frame
    reg                visible;
    reg signed [10:0]  box_left;
    reg [5:0]          box_top;
    reg [6:0]          box_size;
    reg [10:0]         box_step;
    reg [4:0]          box_frame;     // {obj, dir}
    reg [7:0]          box_dist;

    always @(posedge clk) begin
        if (reset) begin
            state    <= 4'd0;
            visible  <= 1'b0;
            box_left <= 11'sd0;
            box_top  <= 6'd0;
            box_size <= 7'd0;
            box_step <= 11'd0;
            box_frame <= 5'd0;
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
                    box_frame <= {spr_obj, dir_index};
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
    wire [16:0] v_scaled = dy[5:0] * box_step + {7'd0, box_step[10:1]};
    wire [5:0]  tex_u = u_scaled[13:8];
    wire [5:0]  tex_v = v_scaled[13:8];

    // frame * 2304 + v * 48 + u
    wire [16:0] frame_base = ({12'd0, box_frame} << 11) + ({12'd0, box_frame} << 8);
    wire [16:0] row_base   = ({11'd0, tex_v} << 5) + ({11'd0, tex_v} << 4);
    wire [16:0] sprite_addr = in_box ? (frame_base + row_base + {11'd0, tex_u}) : 17'd0;

    (* rom_style = "block" *) reg [3:0] sprite_texel [0:73727];   // 32 frames * 48 * 48
    reg [15:0] sprite_palette     [0:63];
    reg [15:0] sprite_palette_lit [0:63];
    initial begin
        $readmemh("sprite_idx.mem",     sprite_texel);
        $readmemh("sprite_pal.mem",     sprite_palette);
        $readmemh("sprite_pal_lit.mem", sprite_palette_lit);
    end

    // Synchronous read for block RAM, the OLED pixel index holds for 16 clocks
    reg [3:0] texel;
    always @(posedge clk)
        texel <= sprite_texel[sprite_addr];

    wire [5:0] palette_addr = {box_frame[4:3], texel};
    wire [4:0] shade = wall_shade_for_distance({2'b00, box_dist});

    // Crosshair hit logic
    // Crosshair is column 48, hits the middle half of the box, in front of the wall, within 4 cells
    localparam [7:0] SHOT_RANGE = 8'd64;
    wire signed [10:0] cross_rel  = 11'sd48 - box_left;
    wire signed [10:0] body_start = $signed({6'b000000, box_size[6:2]});
    wire signed [10:0] body_end   = size_signed - body_start;
    assign crosshair_hit = visible && !cross_rel[10] &&
                           (cross_rel >= body_start) && (cross_rel < body_end) &&
                           (box_dist < centre_wall_dist) && (box_dist <= SHOT_RANGE);

    assign hit    = in_box && (texel != 4'd0) && (box_dist < wall_dist);
    wire [15:0] base_colour = lit ? sprite_palette_lit[palette_addr] : sprite_palette[palette_addr];
    assign colour = shade_rgb565(base_colour, shade);

endmodule