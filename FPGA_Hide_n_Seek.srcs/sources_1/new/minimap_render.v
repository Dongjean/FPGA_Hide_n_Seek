`timescale 1ns / 1ps

//minimap_render - top down minimap on OLED #2


module minimap_render
#(
    parameter integer BLINK_HALF = 781_250  // 4Hz
)
(
    input                    clk,
    input                    reset,
    input             [12:0] pixel_index, // from the OLED #2 Oled_Display
    input            [199:0] cells, // cell type array from world_top

    input  signed     [15:0] player_x, // this player
    input  signed     [15:0] player_y,
    input             [7:0]  view_dir, // 0 N, 64 E, 128 S, 192 W

    input                    pinger_active, // Seeker's Radio Pinger is on
    input  signed     [15:0] rx_hider_x,// Hider position
    input  signed     [15:0] rx_hider_y,

    input                    opp_show,        
    input  signed     [15:0] opp_x,           
    input  signed     [15:0] opp_y,

    input             [1:0]  cap_fade_valid, // capsule 0/1 is in its last 5 s
    input             [6:0]  cap_fade_cell0, // its cell index y*10 + x
    input             [6:0]  cap_fade_cell1,

    output reg        [15:0] pixel_data,
    output                   in_minimap
);
    `include "trig_LUT.vh"

    //colours
    localparam [15:0] C_BLACK  = 16'h0000;
    localparam [15:0] C_GREY   = 16'h630C;   
    localparam [15:0] C_PURPLE = 16'hA018;  
    localparam [15:0] C_YELLOW = 16'hFFE0;   
    localparam [15:0] C_WHITE  = 16'hFFFF;
    localparam [15:0] C_CYAN   = 16'h07FF;   
    localparam [15:0] C_RED    = 16'hF800;
    localparam [15:0] C_ORANGE = 16'hFC00;   

    localparam [1:0] T_FLOOR = 2'b00, T_WALL = 2'b01, T_PORTAL = 2'b10, T_CAPSULE = 2'b11;

    //blink: flips blink_on every time it wraps
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

    //world position -> minimap pixel
    function [6:0] to_px (input signed [15:0] pos);
        reg [15:0] times3;
        begin
            times3 = {pos[14:0], 1'b0} + pos; 
            to_px  = 7'd2 + times3[13:7]; 
        end
    endfunction

    function signed [3:0] tick_off (input signed [7:0] t, input far);
        reg signed [9:0] k_t;
        begin
            if (far) k_t = (t <<< 1) + (t >>> 1); // 2.5 * t
            else     k_t =  t        + (t >>> 1); // 1.5 * t
            tick_off = k_t >>> 6;// -3..+2
        end
    endfunction

    //registered positions (update every clock; inputs change slowly)
    reg [6:0] dot_x, dot_y;        
    reg [6:0] t1_x, t1_y;          
    reg [6:0] t2_x, t2_y;          
    reg [6:0] blip_x, blip_y; // Hider blip, same 2x2 shape as the dot
    reg [6:0] opp_px, opp_py; // opponent dot, same 2x2 shape
    reg       opp_on;              

    wire [6:0]        dx_c  = to_px(player_x);
    wire [6:0]        dy_c  = to_px(player_y);
    wire signed [7:0] s_dir = sin_lut(view_dir);     
    wire signed [7:0] c_neg = -cos_lut(view_dir);    

    wire signed [3:0] o1x = tick_off(s_dir, 1'b0);   
    wire signed [3:0] o1y = tick_off(c_neg, 1'b0);
    wire signed [3:0] o2x = tick_off(s_dir, 1'b1);   
    wire signed [3:0] o2y = tick_off(c_neg, 1'b1);

    always @(posedge clk) begin
        if (reset) begin
            dot_x <= 7'd0; dot_y <= 7'd0;
            t1_x  <= 7'd0; t1_y  <= 7'd0;
            t2_x  <= 7'd0; t2_y  <= 7'd0;
            blip_x <= 7'd0; blip_y <= 7'd0;
            opp_px <= 7'd0; opp_py <= 7'd0;
            opp_on <= 1'b0;
        end else begin
            dot_x  <= dx_c;
            dot_y  <= dy_c;
            t1_x   <= dx_c + {{3{o1x[3]}}, o1x};
            t1_y   <= dy_c + {{3{o1y[3]}}, o1y};
            t2_x   <= dx_c + {{3{o2x[3]}}, o2x};
            t2_y   <= dy_c + {{3{o2y[3]}}, o2y};
            blip_x <= to_px(rx_hider_x);
            blip_y <= to_px(rx_hider_y);
            opp_px <= to_px(opp_x);
            opp_py <= to_px(opp_y);
            opp_on <= opp_show;
        end
    end

    wire [5:0]  pixel_y          = pixel_index / 13'd96;
    wire [12:0] pixel_y_times_96 = ({7'd0, pixel_y} << 6) + ({7'd0, pixel_y} << 5);
    wire [6:0]  pixel_x          = pixel_index - pixel_y_times_96;

    assign in_minimap = (pixel_x < 7'd64);

    //screen x,y -> map cell
    wire       in_map = (pixel_x >= 7'd2) && (pixel_x <= 7'd61) &&
                        (pixel_y >= 6'd2) && (pixel_y <= 6'd61);
    wire [5:0] rel_x  = pixel_x[5:0] - 6'd2;  // 0..59 inside the map
    wire [5:0] rel_y  = pixel_y      - 6'd2;
    wire [3:0] cell_x = rel_x / 6'd6; // divide by constant on 6 bits
    wire [3:0] cell_y = rel_y / 6'd6;
    wire [6:0] cell_i = {cell_y, 3'b000} + {cell_y, 1'b0} + cell_x; // y*10 + x
    wire [1:0] ctype  = cells[{cell_i, 1'b0} +: 2]; // 100:1 mux

    //capsule in its last 5 s: hide it when blink is off
    wire cap_fading = (cap_fade_valid[0] && cap_fade_cell0 == cell_i) ||
                      (cap_fade_valid[1] && cap_fade_cell1 == cell_i);

    //check if the pixel is on a marker 
    //2x2 marker at (mx,my) covers mx-1..mx and my-1..my
    wire on_blip = pinger_active && blink_on &&
                   (pixel_x == blip_x || pixel_x == blip_x - 7'd1) &&
                   ({1'b0, pixel_y} == blip_y || {1'b0, pixel_y} == blip_y - 7'd1);
    wire on_dot  = (pixel_x == dot_x || pixel_x == dot_x - 7'd1) &&
                   ({1'b0, pixel_y} == dot_y || {1'b0, pixel_y} == dot_y - 7'd1);
    wire on_opp  = opp_on &&
                   (pixel_x == opp_px || pixel_x == opp_px - 7'd1) &&
                   ({1'b0, pixel_y} == opp_py || {1'b0, pixel_y} == opp_py - 7'd1);
    wire on_tick = (pixel_x == t1_x && {1'b0, pixel_y} == t1_y) ||
                   (pixel_x == t2_x && {1'b0, pixel_y} == t2_y);

    //final colour 
    //if-else order = what gets drawn on top
    always @(*) begin
        if (!in_minimap || !in_map)  pixel_data = C_BLACK;
        else if (on_blip)            pixel_data = C_RED;
        else if (on_dot)             pixel_data = C_WHITE;
        else if (on_opp)             pixel_data = C_ORANGE; // drawn over the tick and cells
        else if (on_tick)            pixel_data = C_CYAN;
        else begin
            case (ctype)
                T_WALL:    pixel_data = C_GREY;
                T_PORTAL:  pixel_data = C_PURPLE;
                T_CAPSULE: pixel_data = (cap_fading && !blink_on) ? C_BLACK : C_YELLOW;
                default:   pixel_data = C_BLACK; // floor
            endcase
        end
    end

endmodule