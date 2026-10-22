`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// minimap_render - top-down minimap for OLED #2 (Andrew, world generation)
//
// Screen area: the left 64x64 pixels of the 96x64 OLED (x = 0..63).
//   The 10x10 map is drawn at 6x6 px per cell, offset (2,2), so it fills
//   pixels 2..61 on both axes.  Pixels 0,1,62,63 are a black margin.
//
// Layers, highest priority first:
//   1. Radio Pinger blip : red 2x2 at the Hider's position, blinking at 4 Hz,
//                          only while pinger_active
//   2. Player dot        : white 2x2 at this player's position
//   3. Direction tick    : cyan, 2 pixels just outside the dot along view_dir
//   4. Cell colour       : wall grey, floor black, portal purple,
//                          capsule yellow (blinks at 4 Hz in its last 5 s)
//   5. Margin            : black
//
// Cell-type input (owned by world_top):
//   cells[199:0], cell (x,y) at cells[2*(y*10 + x) +: 2]   (LSB-first, row-major)
//   00 floor, 01 wall, 10 portal, 11 capsule
//
// World -> pixel scale: one cell = 256 Q8.8 units = 6 px, so
//   pixel = 2 + pos * 6 / 256 = 2 + (pos * 3) >> 7      (no divider needed)
//
// Timing: pixel_data is combinational from pixel_index, exactly like
// Raycast_3D_Engine.  Oled_Display (negedge logic) changes pixel_index and samples
// pixel_data one full clock (160 ns) later, so the whole path has 160 ns.
// Everything that depends only on positions/direction (dot, tick, blip) is
// pre-computed into registers every clock, so the per-pixel path is just:
// /96 split, /6 cell lookup, a 100:1 2-bit mux and a few compares.
//
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
// The blink counter is local and display-only; it never affects game state,
// so it does not break the two-board sync rule.
//////////////////////////////////////////////////////////////////////////////////
module minimap_render
#(
    parameter integer BLINK_HALF = 781_250   // 0.125 s on, 0.125 s off = 4 Hz (small in simulation)
)
(
    input                    clk,
    input                    reset,
    input             [12:0] pixel_index,     // from the OLED #2 Oled_Display
    input            [199:0] cells,           // cell-type array from world_top

    input  signed     [15:0] player_x,        // this player, Q8.8
    input  signed     [15:0] player_y,
    input             [7:0]  view_dir,        // 0 N, 64 E, 128 S, 192 W

    input                    pinger_active,   // Seeker's Radio Pinger is showing
    input  signed     [15:0] rx_hider_x,      // Hider position from Toh's link, Q8.8
    input  signed     [15:0] rx_hider_y,

    input             [1:0]  cap_fade_valid,  // capsule 0/1 is in its last 5 s
    input             [6:0]  cap_fade_cell0,  // its cell index y*10 + x
    input             [6:0]  cap_fade_cell1,

    output reg        [15:0] pixel_data,      // RGB565
    output                   in_minimap       // 1 when this pixel is in x = 0..63
);
    `include "trig_LUT.vh"

    // ---------------- Colours (RGB565) ----------------
    localparam [15:0] C_BLACK  = 16'h0000;
    localparam [15:0] C_GREY   = 16'h630C;   // r12 g24 b12
    localparam [15:0] C_PURPLE = 16'hA018;   // r20 g0  b24
    localparam [15:0] C_YELLOW = 16'hFFE0;   // r31 g63 b0
    localparam [15:0] C_WHITE  = 16'hFFFF;
    localparam [15:0] C_CYAN   = 16'h07FF;   // r0  g63 b31
    localparam [15:0] C_RED    = 16'hF800;

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;

    // ---------------- Blink: toggles every BLINK_HALF cycles ----------------
    reg [19:0] blink_cnt;
    reg        blink_on;
    always @(posedge clk) begin
        if (reset) begin
            blink_cnt <= 20'd0;
            blink_on  <= 1'b1;
        end else if (blink_cnt == BLINK_HALF - 1) begin
            blink_cnt <= 20'd0;
            blink_on  <= ~blink_on;
        end else begin
            blink_cnt <= blink_cnt + 20'd1;
        end
    end

    // ---------------- World position -> minimap pixel ----------------
    // pos * 3 = (pos << 1) + pos; >> 7 completes * 6 / 256.  Positions inside
    // the map are 0..2559, so pos*3 <= 7677 and the result is 0..59.
    function [6:0] to_px (input signed [15:0] pos);
        reg [15:0] times3;
        begin
            times3 = {pos[14:0], 1'b0} + pos;        // pos * 3 (pos is never negative in the map)
            to_px  = 7'd2 + times3[13:7];            // 2 + (pos*3) >> 7
        end
    endfunction

    // Tick offset along one axis, in pixels, for distance k = 1.5 or 2.5 px.
    // trig value t is +-64 for 1.0, so k*t/64 rounded down = (k*t) >>> 6.
    // The dot covers c-1..c (its true centre is c-0.5), so floor() puts the
    // tick on the pixels touching the dot on both the + and - sides.
    function signed [3:0] tick_off (input signed [7:0] t, input far);
        reg signed [9:0] k_t;
        begin
            if (far) k_t = (t <<< 1) + (t >>> 1);     // 2.5 * t
            else     k_t =  t        + (t >>> 1);     // 1.5 * t
            tick_off = k_t >>> 6;                     // -3..+2
        end
    endfunction

    // Registered per-frame geometry (updates every clock; inputs change slowly)
    reg [6:0] dot_x, dot_y;        // dot covers (dot_x-1 .. dot_x, dot_y-1 .. dot_y)
    reg [6:0] t1_x, t1_y;          // tick pixel 1 (near)
    reg [6:0] t2_x, t2_y;          // tick pixel 2 (far)
    reg [6:0] blip_x, blip_y;      // Hider blip, same 2x2 shape as the dot

    wire [6:0]        dx_c  = to_px(player_x);
    wire [6:0]        dy_c  = to_px(player_y);
    wire signed [7:0] s_dir = sin_lut(view_dir);     // +x component
    wire signed [7:0] c_neg = -cos_lut(view_dir);    // +y component (north is -y)

    wire signed [3:0] o1x = tick_off(s_dir, 1'b0);   // near tick offsets
    wire signed [3:0] o1y = tick_off(c_neg, 1'b0);
    wire signed [3:0] o2x = tick_off(s_dir, 1'b1);   // far tick offsets
    wire signed [3:0] o2y = tick_off(c_neg, 1'b1);

    always @(posedge clk) begin
        if (reset) begin
            dot_x <= 7'd0; dot_y <= 7'd0;
            t1_x  <= 7'd0; t1_y  <= 7'd0;
            t2_x  <= 7'd0; t2_y  <= 7'd0;
            blip_x <= 7'd0; blip_y <= 7'd0;
        end else begin
            dot_x  <= dx_c;
            dot_y  <= dy_c;
            // {{3{o[3]}}, o} sign-extends the 4-bit offset to 7 bits, so adding
            // a negative offset wraps correctly (e.g. -2 = 7'b1111110)
            t1_x   <= dx_c + {{3{o1x[3]}}, o1x};
            t1_y   <= dy_c + {{3{o1y[3]}}, o1y};
            t2_x   <= dx_c + {{3{o2x[3]}}, o2x};
            t2_y   <= dy_c + {{3{o2y[3]}}, o2y};
            blip_x <= to_px(rx_hider_x);
            blip_y <= to_px(rx_hider_y);
        end
    end

    // ---------------- Pixel -> screen x,y (same method as the engine) ----------------
    wire [5:0]  pixel_y          = pixel_index / 13'd96;
    wire [12:0] pixel_y_times_96 = ({7'd0, pixel_y} << 6) + ({7'd0, pixel_y} << 5);
    wire [6:0]  pixel_x          = pixel_index - pixel_y_times_96;

    assign in_minimap = (pixel_x < 7'd64);

    // ---------------- Screen x,y -> map cell ----------------
    wire       in_map = (pixel_x >= 7'd2) && (pixel_x <= 7'd61) &&
                        (pixel_y >= 6'd2) && (pixel_y <= 6'd61);
    wire [5:0] rel_x  = pixel_x[5:0] - 6'd2;       // 0..59 inside the map
    wire [5:0] rel_y  = pixel_y      - 6'd2;
    wire [3:0] cell_x = rel_x / 6'd6;              // 6-bit constant divide -> small LUT
    wire [3:0] cell_y = rel_y / 6'd6;
    wire [6:0] cell_i = {cell_y, 3'b000} + {cell_y, 1'b0} + cell_x;   // y*10 + x
    wire [1:0] ctype  = cells[{cell_i, 1'b0} +: 2];                     // 100:1 mux

    // Capsule in its last 5 s: hide it during the off half of the blink
    wire cap_fading = (cap_fade_valid[0] && cap_fade_cell0 == cell_i) ||
                      (cap_fade_valid[1] && cap_fade_cell1 == cell_i);

    // ---------------- Overlay hits ----------------
    // A 2x2 marker at (mx,my) covers mx-1..mx and my-1..my
    wire on_blip = pinger_active && blink_on &&
                   (pixel_x == blip_x || pixel_x == blip_x - 7'd1) &&
                   ({1'b0, pixel_y} == blip_y || {1'b0, pixel_y} == blip_y - 7'd1);
    wire on_dot  = (pixel_x == dot_x || pixel_x == dot_x - 7'd1) &&
                   ({1'b0, pixel_y} == dot_y || {1'b0, pixel_y} == dot_y - 7'd1);
    wire on_tick = (pixel_x == t1_x && {1'b0, pixel_y} == t1_y) ||
                   (pixel_x == t2_x && {1'b0, pixel_y} == t2_y);

    // ---------------- Final colour ----------------
    always @(*) begin
        if (!in_minimap || !in_map)  pixel_data = C_BLACK;
        else if (on_blip)            pixel_data = C_RED;
        else if (on_dot)             pixel_data = C_WHITE;
        else if (on_tick)            pixel_data = C_CYAN;
        else begin
            case (ctype)
                T_WALL:    pixel_data = C_GREY;
                T_PORTAL:  pixel_data = C_PURPLE;
                T_CAPSULE: pixel_data = (cap_fading && !blink_on) ? C_BLACK : C_YELLOW;
                default:   pixel_data = C_BLACK;              // floor
            endcase
        end
    end

endmodule