`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// hud_render - HUD strip on OLED #2 (Andrew)
//
// Screen area: x = 64..95 (32 px wide), y = 0..63, black background.
// Layout (rx = x - 64):
//   y  2..17  weapon icon, 16x16 ROM (2 bits per pixel, 2 colours) at rx 8..23
//             Seeker gun = red pistol      Seeker item = green radar (Radio Pinger)
//             Hider gun  = blue snowflake  Hider item  = white crossed-out eye (Flashbang)
//   y 21..30  count for that weapon (bullets 0..5, or item uses 0..3),
//             3x5 font at 2x (6x10) at rx 13..18; white, red at 0
//   y 35..40  HP bar: 5 segments (rx 2..30), one per 20 HP (rounded up);
//             green 3-5, yellow 2, red 1; unlit segments dark grey
//   y 47..56  time left as M:SS (max 5:00) at 2x; white, red under 30 s
//
// Timing: like minimap_render, pixel_data is combinational from pixel_index
// (160 ns budget).  Everything that depends only on the game state (digits of
// the time, segment count, which icon) is registered first, so the per-pixel
// path is just the /96 split, a few range compares and a small ROM lookup.
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
//////////////////////////////////////////////////////////////////////////////////
module hud_render
(
    input             clk,
    input             reset,
    input      [12:0] pixel_index,     // from the OLED #2 Oled_Display

    input             is_hider,        // role of this player
    input      [1:0]  weapon_sel,      // [0]: 0 = gun, 1 = item (Jian Bin's sw0)
    input      [2:0]  ammo,            // gun bullets 0..5
    input      [1:0]  uses,            // item uses 0..3
    input      [7:0]  health,          // 0..100 (my_health)
    input      [8:0]  seconds_left,    // 0..300 (game_seconds_left)

    output reg [15:0] pixel_data,      // RGB565
    output            in_hud           // 1 when this pixel is in x = 64..95
);
    // ---------------- Colours (RGB565) ----------------
    localparam [15:0] C_BLACK  = 16'h0000;
    localparam [15:0] C_WHITE  = 16'hFFFF;
    localparam [15:0] C_RED    = 16'hF800;
    localparam [15:0] C_GREEN  = 16'h07E0;
    localparam [15:0] C_YELLOW = 16'hFFE0;
    localparam [15:0] C_CYAN   = 16'h07FF;
    localparam [15:0] C_ICE    = 16'h5D1F;   // r11 g40 b31, light blue
    localparam [15:0] C_DGREY  = 16'h2104;   // r4 g8 b4, unlit HP segment
    localparam [15:0] C_RADAR  = 16'h7FEA;   // r15 g63 b10, bright radar green
    localparam [15:0] C_RADARD = 16'h1A83;   // r3 g20 b3, dark radar disc

    // =====================================================================
    // Registered game-state values (change slowly, so 1 clock late is fine)
    // =====================================================================
    reg  [1:0]  icon;          // {is_hider, item}: 0 seeker gun, 1 pinger, 2 freeze gun, 3 flashbang
    reg  [3:0]  count;         // digit shown under the icon
    reg  [2:0]  hp_segs;       // lit HP segments 0..5
    reg  [3:0]  t_min, t_ten, t_one;
    reg         t_low;         // under 30 s

    // seconds -> M, S tens, S ones (constant dividers on 9 bits: small LUTs,
    // and only in this registered path, never in the per-pixel path)
    wire [8:0] min_w = seconds_left / 9'd60;
    wire [8:0] rem_w = seconds_left - min_w * 9'd60;

    always @(posedge clk) begin
        if (reset) begin
            icon <= 2'd0; count <= 4'd0; hp_segs <= 3'd0;
            t_min <= 4'd0; t_ten <= 4'd0; t_one <= 4'd0; t_low <= 1'b0;
        end else begin
            icon  <= {is_hider, weapon_sel[0]};
            count <= weapon_sel[0] ? {2'b00, uses} : {1'b0, ammo};
            // segments = ceil(health / 20)
            hp_segs <= (health == 8'd0) ? 3'd0 : (health <= 8'd20) ? 3'd1 :
                       (health <= 8'd40) ? 3'd2 : (health <= 8'd60) ? 3'd3 :
                       (health <= 8'd80) ? 3'd4 : 3'd5;
            t_min <= min_w[3:0];
            t_ten <= rem_w / 9'd10;
            t_one <= rem_w % 9'd10;
            t_low <= (seconds_left < 9'd30);
        end
    end

    // =====================================================================
    // ROMs
    // =====================================================================
    // 16x16 icons, 2 bits per pixel: 00 off, 01 main colour, 10 second colour.
    // Row 0 is the top 32 bits; in a row, the leftmost pixel is the top 2 bits.
    // 0: Seeking Gun: red pistol (8x8 drawn doubled)
    localparam [511:0] ICON0 = {
        32'b00000000000000000000000000000000,   // row  0                  
        32'b00000000000000000000000000000000,   // row  1                  
        32'b01010101010101010101010101010000,   // row  2  ##############  
        32'b01010101010101010101010101010000,   // row  3  ##############  
        32'b01010101010101010101010101010101,   // row  4  ################
        32'b01010101010101010101010101010101,   // row  5  ################
        32'b01010101010101010000000000000000,   // row  6  ########        
        32'b01010101010101010000000000000000,   // row  7  ########        
        32'b01010101010100000000000000000000,   // row  8  ######          
        32'b01010101010100000000000000000000,   // row  9  ######          
        32'b01010101000000000000000000000000,   // row 10  ####            
        32'b01010101000000000000000000000000,   // row 11  ####            
        32'b01010101000000000000000000000000,   // row 12  ####            
        32'b01010101000000000000000000000000,   // row 13  ####            
        32'b00000000000000000000000000000000,   // row 14                  
        32'b00000000000000000000000000000000   // row 15                  
    };
    // 1: Radio Pinger: radar (1 = bright green line, 2 = dark green disc)
    localparam [511:0] ICON1 = {
        32'b00000000000101010101010000000000,   // row  0       ######     
        32'b00000001011010011010100101000000,   // row  1     ##++#+++##   
        32'b00000110101010011010100110010000,   // row  2    #++++#+++#+#  
        32'b00011010101010011010010101010100,   // row  3   #+++++#++##### 
        32'b00010101101001010101010101010100,   // row  4   ###++######### 
        32'b01100101100110011001010101101001,   // row  5  #+##+#+#+####++#
        32'b01101010011010011001010110101001,   // row  6  #+++#++#+###+++#
        32'b01101010011010010110100110101001,   // row  7  #+++#++##++#+++#
        32'b01010101010101010101010101010101,   // row  8  ################
        32'b01101010011010011010100110101001,   // row  9  #+++#++#+++#+++#
        32'b01101010100110011010010110101001,   // row 10  #++++#+#++##+++#
        32'b00011010101001010101010110100100,   // row 11   #++++######++# 
        32'b00011010101010011010101010100100,   // row 12   #+++++#++++++# 
        32'b00000110101010011010101010010000,   // row 13    #++++#+++++#  
        32'b00000001011010011010100101000000,   // row 14     ##++#+++##   
        32'b00000000000101010101010000000000   // row 15       ######     
    };
    // 2: Freeze Gun: light-blue snowflake (8x8 drawn doubled)
    localparam [511:0] ICON2 = {
        32'b00000000000001010000000000000000,   // row  0        ##        
        32'b00000000000001010000000000000000,   // row  1        ##        
        32'b00000101000001010000010100000000,   // row  2    ##  ##  ##    
        32'b00000101000001010000010100000000,   // row  3    ##  ##  ##    
        32'b00000000010101010101000000000000,   // row  4      ######      
        32'b00000000010101010101000000000000,   // row  5      ######      
        32'b01010101010101010101010101010000,   // row  6  ##############  
        32'b01010101010101010101010101010000,   // row  7  ##############  
        32'b00000000010101010101000000000000,   // row  8      ######      
        32'b00000000010101010101000000000000,   // row  9      ######      
        32'b00000101000001010000010100000000,   // row 10    ##  ##  ##    
        32'b00000101000001010000010100000000,   // row 11    ##  ##  ##    
        32'b00000000000001010000000000000000,   // row 12        ##        
        32'b00000000000001010000000000000000,   // row 13        ##        
        32'b00000000000000000000000000000000,   // row 14                  
        32'b00000000000000000000000000000000   // row 15                  
    };
    // 3: Flashbang: white crossed-out eye
    localparam [511:0] ICON3 = {
        32'b00000000000000000000000000000000,   // row  0                  
        32'b00010100000000000000000000000000,   // row  1   ##             
        32'b00000101000000000000000000000000,   // row  2    ##            
        32'b00000001010101010101010000000000,   // row  3     ########     
        32'b00000000010100000000000101000000,   // row  4      ##     ##   
        32'b00000100000101010101000000010000,   // row  5    #  #####   #  
        32'b00010000000001010101010000000100,   // row  6   #    #####   # 
        32'b01000000010100010101010100000001,   // row  7  #   ## #####   #
        32'b01000000010101000101010100000001,   // row  8  #   ### ####   #
        32'b00010000000101010001010000000100,   // row  9   #   ### ##   # 
        32'b00000100000001010100010100010000,   // row 10    #   ### ## #  
        32'b00000001010000000000000101000000,   // row 11     ##      ##   
        32'b00000000000101010101010001010000,   // row 12       ###### ##  
        32'b00000000000000000000000000010100,   // row 13               ## 
        32'b00000000000000000000000000000100,   // row 14                # 
        32'b00000000000000000000000000000000   // row 15                  
    };

    // Pixel (row, col) of icon i: bits [511 - 2*(16*row + col) -: 2]
    function [1:0] icon_px (input [1:0] i, input [3:0] row, input [3:0] col);
        reg [511:0] bits;
        reg [8:0]   pos;                 // 2 * (16*row + col)
        begin
            case (i)
                2'd0:    bits = ICON0;
                2'd1:    bits = ICON1;
                2'd2:    bits = ICON2;
                default: bits = ICON3;
            endcase
            pos     = {row, col, 1'b0};
            icon_px = bits[511 - pos -: 2];
        end
    endfunction

    // Colour of a lit icon pixel: v = 01 main, 10 second (only the radar uses it)
    function [15:0] icon_colour (input [1:0] i, input [1:0] v);
        case (i)
            2'd0:    icon_colour = C_RED;
            2'd1:    icon_colour = (v == 2'b10) ? C_RADARD : C_RADAR;
            2'd2:    icon_colour = C_ICE;
            default: icon_colour = C_WHITE;
        endcase
    endfunction

    // 3x5 digits: 15 bits, row 0 first, bit 14 = row 0 left
    function [14:0] font (input [3:0] d);
        case (d)
            4'd0: font = 15'b111_101_101_101_111;
            4'd1: font = 15'b010_110_010_010_111;
            4'd2: font = 15'b111_001_111_100_111;
            4'd3: font = 15'b111_001_111_001_111;
            4'd4: font = 15'b101_101_111_001_001;
            4'd5: font = 15'b111_100_111_001_111;
            4'd6: font = 15'b111_100_111_101_111;
            4'd7: font = 15'b111_001_001_001_001;
            4'd8: font = 15'b111_101_111_101_111;
            4'd9: font = 15'b111_101_111_001_111;
            default: font = 15'd0;
        endcase
    endfunction

    // Is (col, row) of digit d lit?  col 0..2, row 0..4
    function digit_px (input [3:0] d, input [1:0] col, input [2:0] row);
        reg [14:0] f;
        begin
            f        = font(d);
            digit_px = f[14 - (row * 3 + col)];
        end
    endfunction

    // =====================================================================
    // Pixel position (same method as the engine and the minimap)
    // =====================================================================
    wire [5:0]  pixel_y          = pixel_index / 13'd96;
    wire [12:0] pixel_y_times_96 = ({7'd0, pixel_y} << 6) + ({7'd0, pixel_y} << 5);
    wire [6:0]  pixel_x          = pixel_index - pixel_y_times_96;

    assign in_hud = (pixel_x >= 7'd64);
    wire [4:0] rx = pixel_x[4:0];          // 0..31 inside the HUD (pixel_x - 64)
    wire [5:0] ry = pixel_y;

    // ---- Icon: rx 8..23, ry 2..17, 1x scale (16x16) ----
    wire       in_icon = (rx >= 5'd8) && (rx <= 5'd23) && (ry >= 6'd2) && (ry <= 6'd17);
    wire [4:0] ic_c5   = rx - 5'd8;                // 0..15 inside the icon
    wire [5:0] ic_r6   = ry - 6'd2;
    wire [1:0] ic_v    = icon_px(icon, ic_r6[3:0], ic_c5[3:0]);
    wire       icon_on = in_icon && (ic_v != 2'b00);

    // ---- Count digit: rx 13..18, ry 21..30 ----
    wire       in_cnt  = (rx >= 5'd13) && (rx <= 5'd18) && (ry >= 6'd21) && (ry <= 6'd30);
    wire       cnt_on  = in_cnt && digit_px(count, (rx - 5'd13) >> 1, (ry - 6'd21) >> 1);

    // ---- HP bar: ry 35..40, segment i at rx 2+6i .. 6+6i ----
    wire       in_hp_row = (ry >= 6'd35) && (ry <= 6'd40) && (rx >= 5'd2) && (rx <= 5'd30);
    wire [4:0] hp_rel    = rx - 5'd2;              // 0..28
    wire [2:0] hp_seg    = hp_rel / 5'd6;          // segment 0..4 (constant divide, 5 bits)
    wire       hp_gap    = (hp_rel - hp_seg * 5'd6) == 5'd5;   // 1-px gap after each segment
    wire       in_hp     = in_hp_row && !hp_gap;
    wire       hp_lit    = (hp_seg < hp_segs);
    wire [15:0] hp_colour = (hp_segs >= 3'd3) ? C_GREEN : (hp_segs == 3'd2) ? C_YELLOW : C_RED;

    // ---- Time M:SS: ry 47..56; M rx 3..8, colon rx 11..12, tens 15..20, ones 23..28 ----
    wire       in_trow = (ry >= 6'd47) && (ry <= 6'd56);
    wire [2:0] t_row   = (ry - 6'd47) >> 1;        // font row 0..4
    wire       tm_on   = in_trow && (rx >= 5'd3)  && (rx <= 5'd8)  && digit_px(t_min, (rx - 5'd3)  >> 1, t_row);
    wire       tt_on   = in_trow && (rx >= 5'd15) && (rx <= 5'd20) && digit_px(t_ten, (rx - 5'd15) >> 1, t_row);
    wire       to_on   = in_trow && (rx >= 5'd23) && (rx <= 5'd28) && digit_px(t_one, (rx - 5'd23) >> 1, t_row);
    // colon: two 2x2 dots at rows 1 and 3 of the font (ry 49..50 and 53..54)
    wire       col_on  = (rx >= 5'd11) && (rx <= 5'd12) &&
                         ((ry >= 6'd49 && ry <= 6'd50) || (ry >= 6'd53 && ry <= 6'd54));
    wire       time_on = tm_on || tt_on || to_on || col_on;

    // =====================================================================
    // Final colour
    // =====================================================================
    always @(*) begin
        if (!in_hud)       pixel_data = C_BLACK;
        else if (icon_on)  pixel_data = icon_colour(icon, ic_v);
        else if (cnt_on)   pixel_data = (count == 4'd0) ? C_RED : C_WHITE;
        else if (in_hp)    pixel_data = hp_lit ? hp_colour : C_DGREY;
        else if (time_on)  pixel_data = t_low ? C_RED : C_WHITE;
        else               pixel_data = C_BLACK;
    end

endmodule