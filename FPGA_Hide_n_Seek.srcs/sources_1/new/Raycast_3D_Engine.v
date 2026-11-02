`timescale 1ns / 1ps
// 3D Rendering Engine

module Raycast_3D_Engine
#(
    parameter [7:0]DIR_NORTH = 8'd0,
    parameter [7:0]DIR_EAST = 8'd64,
    parameter [7:0]DIR_SOUTH = 8'd128,
    parameter [7:0]DIR_WEST = 8'd192
)
(
    input clk,
    input reset,
    input signed [15:0]player_x,
    input signed [15:0]player_y,
    input [7:0]view_dir,
    input frame_begin,
    input [12:0]pixel_index,
    input [99:0]map_bits,
    
    output reg [15:0]pixel_data
);

    `include "trig_LUT.vh"
    `include "ray_helpers.vh"
    `include "wall_helpers.vh"

    localparam integer SCREEN_WIDTH  = 96;
    localparam integer SCREEN_HEIGHT = 64;
    localparam integer RAY_COLUMNS   = 96;
    localparam integer COLUMN_WIDTH  = 1;

    localparam [2:0]RC_IDLE  = 3'd0;
    localparam [2:0]RC_SETUP = 3'd1;
    localparam [2:0]RC_MARCH = 3'd2;
    localparam [2:0]RC_STORE = 3'd3;
    localparam [2:0]RC_DONE  = 3'd4;

    // Two wall-column buffers prevent partially calculated rays from appearing
    // on the OLED.  One buffer is displayed while the other is calculated.
    reg [5:0]wall_top_a    [0:RAY_COLUMNS-1];
    reg [5:0]wall_bottom_a [0:RAY_COLUMNS-1];
    reg [4:0]wall_shade_a  [0:RAY_COLUMNS-1];
    reg [5:0]wall_top_b    [0:RAY_COLUMNS-1];
    reg [5:0]wall_bottom_b [0:RAY_COLUMNS-1];
    reg [4:0]wall_shade_b  [0:RAY_COLUMNS-1];
    reg [3:0]wall_u_a      [0:RAY_COLUMNS-1];
    reg      wall_ew_a     [0:RAY_COLUMNS-1];
    reg [3:0]wall_u_b      [0:RAY_COLUMNS-1];
    reg      wall_ew_b     [0:RAY_COLUMNS-1];
    reg      valid_a;
    reg      valid_b;
    reg      front_select;   // 0: display A, 1: display B
    reg      render_target;  // buffer currently being built

    reg [1:0]move_phase;

    // Ray marcher state.  A ray takes at most 128 clocks, so all 24 rays are
    // ready long before the next 60 Hz frame begins.
    reg [2:0]          render_state;
    reg [6:0]          ray_column;
    reg signed [17:0] ray_x;
    reg signed [17:0] ray_y;
    reg [7:0]         ray_dir = 8'd0;
    reg [7:0]          ray_steps;
    reg [9:0]          hit_distance;
    reg [3:0]          hit_u;     // texture column of the wall hit
    reg                hit_ew;    // 1: east/west facing wall, 0: north/south

    integer i;
    
    reg signed [17:0]next_ray_x;
    reg signed [17:0]next_ray_y;
    reg next_ray_outside_map;
    reg next_ray_hits_wall;

    reg       tex_x_crossed;
    reg [3:0] tex_u;
    reg       tex_flip;
    reg [3:0] tex_u_oriented;

    // Sequential fixed-point ray marcher
    // Every time it reaches a wall, it stores one projected vertical slice in the buffer that is not displayed
    always @(posedge clk) begin
    
        // Update the ray states
        {next_ray_x, next_ray_y} = move_ray(ray_x, ray_y, ray_dir);
        next_ray_outside_map = (
            (next_ray_x < 18'sd0) ||
            (next_ray_y < 18'sd0) ||
            (next_ray_x >= 18'sd10240) ||
            (next_ray_y >= 18'sd10240)
        );
        next_ray_hits_wall = (
            next_ray_outside_map ||
            map_is_wall(next_ray_x[13:10], next_ray_y[13:10], map_bits)
        );
        
        // Saving the current x or y coordinate within each wall cell
        // To know whether to save the x or y coordinate (walls are horizontal or vertical only),
        // We check if the ray's x value when it hit a new wall cell
        // If it changed, that means that the wall is north/south, otherwise east/west
        // Then, check if the ray was travelling north/south, or east/west 
        tex_x_crossed = (ray_x[13:10] != next_ray_x[13:10]);
        if (tex_x_crossed) begin
            tex_u    = next_ray_y[9:6];
            tex_flip = (next_ray_x < ray_x); // travelling west, default east
        end else begin
            tex_u    = next_ray_x[9:6];
            tex_flip = (next_ray_y > ray_y); // travelling south, default north
        end
        tex_u_oriented = tex_flip ? ~tex_u : tex_u;

        if (reset) begin
            render_state  <= RC_IDLE;
            ray_column    <= 5'd0;
            ray_x         <= 16'sd0;
            ray_y         <= 16'sd0;
            ray_steps     <= 8'd0;
            hit_distance  <= 10'd0;
            hit_u         <= 4'd0;
            hit_ew        <= 1'b0;
            valid_a       <= 1'b0;
            valid_b       <= 1'b0;
            front_select  <= 1'b0;
            render_target <= 1'b1;
            for (i = 0; i < RAY_COLUMNS; i = i + 1) begin
                wall_top_a[i]    <= 6'd0;
                wall_bottom_a[i] <= 6'd0;
                wall_shade_a[i]  <= 5'd0;
                wall_top_b[i]    <= 6'd0;
                wall_bottom_b[i] <= 6'd0;
                wall_shade_b[i]  <= 5'd0;
                wall_u_a[i]      <= 4'd0;
                wall_ew_a[i]     <= 1'b0;
                wall_u_b[i]      <= 4'd0;
                wall_ew_b[i]     <= 1'b0;
            end
        end else begin
            case (render_state)
                RC_IDLE: begin
                    if (frame_begin) begin
                        render_target     <= ~front_select;
                        ray_column        <= 7'd0;
                        render_state      <= RC_SETUP;
                    end
                end

                RC_SETUP: begin
                    ray_x        <= player_x <<< 2;
                    ray_y        <= player_y <<< 2;
                    ray_dir      <= view_dir + ray_angle_offset(ray_column);
                    ray_steps    <= 8'd0;
                    render_state <= RC_MARCH;
                end

                RC_MARCH: begin
                    if (next_ray_hits_wall || (ray_steps == 8'd127)) begin
                        hit_distance <= {2'd0, ray_steps} + 10'd1;
                        hit_u        <= tex_u_oriented;
                        hit_ew       <= tex_x_crossed;
                        render_state <= RC_STORE;
                    end else begin
                        ray_x     <= next_ray_x;
                        ray_y     <= next_ray_y;
                        ray_steps <= ray_steps + 8'd1;
                    end
                end

                RC_STORE: begin
                    if (render_target == 1'b0) begin
                        wall_top_a[ray_column]    <= 6'd32 - wall_half_height(hit_distance);
                        wall_bottom_a[ray_column] <= 6'd31 + wall_half_height(hit_distance);
                        wall_shade_a[ray_column]  <= wall_shade_for_distance(hit_distance);
                        wall_u_a[ray_column]      <= hit_u;
                        wall_ew_a[ray_column]     <= hit_ew;
                    end else begin
                        wall_top_b[ray_column]    <= 6'd32 - wall_half_height(hit_distance);
                        wall_bottom_b[ray_column] <= 6'd31 + wall_half_height(hit_distance);
                        wall_shade_b[ray_column]  <= wall_shade_for_distance(hit_distance);
                        wall_u_b[ray_column]      <= hit_u;
                        wall_ew_b[ray_column]     <= hit_ew;
                    end

                    if (ray_column == RAY_COLUMNS-1) begin
                        if (render_target == 1'b0)
                            valid_a <= 1'b1;
                        else
                            valid_b <= 1'b1;
                        render_state <= RC_DONE;
                    end else begin
                        ray_column    <= ray_column + 5'd1;
                        render_state      <= RC_SETUP;
                    end
                end

                // At the next frame boundary, show the complete buffer and
                // immediately start calculating the other one.
                RC_DONE: begin
                    if (frame_begin) begin
                        front_select      <= render_target;
                        render_target     <= ~render_target;
                        ray_column        <= 5'd0;
                        render_state      <= RC_SETUP;
                    end
                end

                default: render_state <= RC_IDLE;
            endcase
        end
    end

    // Pixel lookup for the OLED's linear index
    wire [5:0] pixel_y = pixel_index / 13'd96;
    wire [12:0] pixel_y_times_96 = ({7'd0, pixel_y} << 6) +
                                   ({7'd0, pixel_y} << 5);
    wire [6:0] pixel_x = pixel_index - pixel_y_times_96;
    wire [6:0] display_column = pixel_x;

    reg [5:0] selected_top;
    reg [5:0] selected_bottom;
    reg [4:0] selected_shade;
    reg       selected_valid;
    reg [3:0] selected_u;
    reg       selected_ew;

    // A texel is a vertical texture coordinate
    // It is how far down the wall the current pixel is, in terms of the preset wall texture
    // Each pixel step (64 steps) might land at some texel coordinate depending on how far away it is
    // This pixel --> texel coordinate conversion is texel = (pixel_y - selected_top) * 16 / wall_height
    // LUT for 256 * 16 / wall_height is wall_text_step(wall_hh)
    // We scale the output by 256 to prevent floating point approximation errors
    // tex_scaled is the texel coordinate scaled by 256
    // tex_v is the texel coordinate scaled back to normal
    wire [5:0]  wall_hh    = 6'd32 - selected_top;
    wire [8:0]  tex_step   = wall_tex_step(wall_hh);
    wire [5:0]  tex_rows   = pixel_y - selected_top;      // row inside the wall
    wire [14:0] tex_scaled = tex_rows * tex_step;
    wire [3:0]  tex_v      = tex_scaled[11:8];

    always @(*) begin
        if (front_select == 1'b0) begin
            selected_top    = wall_top_a[display_column];
            selected_bottom = wall_bottom_a[display_column];
            selected_shade  = wall_shade_a[display_column];
            selected_valid  = valid_a;
            selected_u      = wall_u_a[display_column];
            selected_ew     = wall_ew_a[display_column];
        end else begin
            selected_top    = wall_top_b[display_column];
            selected_bottom = wall_bottom_b[display_column];
            selected_shade  = wall_shade_b[display_column];
            selected_valid  = valid_b;
            selected_u      = wall_u_b[display_column];
            selected_ew     = wall_ew_b[display_column];
        end

        if (!selected_valid)
            pixel_data = 16'h0000;
        else if (pixel_y < selected_top)
            pixel_data = 16'h0005; // Dark blue ceiling
        else if (pixel_y > selected_bottom)
            pixel_data = 16'h2104; // Dark grey floor
        else
            pixel_data = wall_texture_colour(selected_u, tex_v, selected_shade, selected_ew);
    end

endmodule

