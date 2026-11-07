`timescale 1ns / 1ps

//hud_render - draws the hud on the left side of oled 2

module hud_render
(
    input             clk,
    input             reset,
    input      [12:0] pixel_index,     //from oled 2

    input             is_hider,        //1 = hider, 0 = seeker
    input      [1:0]  weapon_sel,      
    input      [3:0]  ammo,            //bullets left
    input      [2:0]  uses,            //item uses left (0-5)
    input      [7:0]  health,          
    input      [8:0]  seconds_left,   

    output reg [15:0] pixel_data,      
    output            in_hud           
);
    //colours, rgb565
    localparam [15:0] C_BLACK  = 16'h0000;
    localparam [15:0] C_WHITE  = 16'hFFFF;
    localparam [15:0] C_RED    = 16'hF800;
    localparam [15:0] C_ICE    = 16'h5D1F;   //light blue for freeze
    localparam [15:0] C_DGREY  = 16'h2104;   //for used up stuff
    localparam [15:0] C_RADAR  = 16'h7FEA;   //radar green
    localparam [15:0] C_RADARD = 16'h1A83;   //darker radar green

    //registered game state
    reg  [1:0]  icon;          
    reg         hider_r;       
    reg  [3:0]  count;         
    reg         cnt_ten;       //1 = show "10"
    reg  [1:0]  hearts;        
    reg  [3:0]  pips;         
    reg         pip_item;      
    reg  [3:0]  t_min, t_ten, t_one;   
    reg         t_low;         //under 30s, goes red


    wire [8:0] min_w = seconds_left / 9'd60;
    wire [8:0] rem_w = seconds_left - min_w * 9'd60;

    //uses if item picked, ammo if gun picked
    wire [3:0] cnt_w = weapon_sel[0] ? {1'b0, uses} : ammo;

    always @(posedge clk) begin
        if (reset) begin
            icon <= 2'd0; hider_r <= 1'b0; count <= 4'd0; cnt_ten <= 1'b0;
            hearts <= 2'd0; pips <= 4'd0; pip_item <= 1'b0;
            t_min <= 4'd0; t_ten <= 4'd0; t_one <= 4'd0; t_low <= 1'b0;
        end else begin
            icon    <= {is_hider, weapon_sel[0]};
            hider_r <= is_hider;
            count   <= (cnt_w > 4'd10) ? 4'd10 : cnt_w;
            cnt_ten <= (cnt_w >= 4'd10);
            hearts  <= (health <= 8'd3)  ? health[1:0] :
                       (health <= 8'd34) ? 2'd1 :
                       (health <= 8'd67) ? 2'd2 : 2'd3;
            pip_item <= weapon_sel[0];
            //pips follow whatever the number shows, ammo caps at 10, uses at 5
            pips    <= weapon_sel[0] ? ((uses > 3'd5) ? 4'd5 : {1'b0, uses})
                                     : ((ammo > 4'd10) ? 4'd10 : ammo);
            t_min   <= min_w[3:0];
            t_ten   <= rem_w / 9'd10;
            t_one   <= rem_w % 9'd10;
            t_low   <= (seconds_left < 9'd30);
        end
    end

    //ones digit
    wire [3:0] cnt_one = cnt_ten ? 4'd0 : count;

    //icons, 16x16, 2 bits each pixel
    //gun
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
        32'b00000000000000000000000000000000    // row 15
    };
    //radar 
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
        32'b00000000000101010101010000000000    // row 15       ######
    };
    //freeze gun
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
        32'b00000000000000000000000000000000    // row 15
    };
    //flashbang 
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
        32'b00000000000000000000000000000000    // row 15
    };

    //heart 
    localparam [47:0] HEART = {
        8'b01100110,    //  .##..##.
        8'b11111111,    //  ########
        8'b11111111,    //  ########
        8'b01111110,    //  .######.
        8'b00111100,    //  ..####..
        8'b00011000     //  ...##...
    };

    //grab the 2 bits at (row, col) of icon i
    function [1:0] icon_px (input [1:0] i, input [3:0] row, input [3:0] col);
        reg [511:0] bits;
        reg [8:0]   pos;                 
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

    //icon pixel colour
    function [15:0] icon_colour (input [1:0] i, input [1:0] v);
        case (i)
            2'd0:    icon_colour = C_RED;
            2'd1:    icon_colour = (v == 2'b10) ? C_RADARD : C_RADAR;
            2'd2:    icon_colour = C_ICE;
            default: icon_colour = C_WHITE;
        endcase
    endfunction

    //3x5 digits
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

    function digit_px (input [3:0] d, input [1:0] col, input [2:0] row);
        reg [14:0] f;
        begin
            f        = font(d);
            digit_px = f[14 - (row * 3 + col)];
        end
    endfunction

    //index to x y
    wire [5:0]  pixel_y          = pixel_index / 13'd96;
    wire [12:0] pixel_y_times_96 = ({7'd0, pixel_y} << 6) + ({7'd0, pixel_y} << 5);
    wire [6:0]  pixel_x          = pixel_index - pixel_y_times_96;

    assign in_hud = (pixel_x >= 7'd64);
    wire [4:0] rx = pixel_x[4:0];        
    wire [5:0] ry = pixel_y;

    //icon
    wire       in_icon = (rx >= 5'd8) && (rx <= 5'd23) && (ry >= 6'd2) && (ry <= 6'd17);
    wire [4:0] ic_c5   = rx - 5'd8;               
    wire [5:0] ic_r6   = ry - 6'd2;               
    wire [1:0] ic_v    = icon_px(icon, ic_r6[3:0], ic_c5[3:0]);
    wire       icon_on = in_icon && (ic_v != 2'b00);

    //count number
    wire       in_crow = (ry >= 6'd21) && (ry <= 6'd30);
    wire [2:0] c_row   = (ry - 6'd21) >> 1;       
    wire       c1_on   = in_crow && !cnt_ten && (rx >= 5'd13) && (rx <= 5'd18) &&
                         digit_px(cnt_one, (rx - 5'd13) >> 1, c_row);
    wire       c10a_on = in_crow &&  cnt_ten && (rx >= 5'd9)  && (rx <= 5'd14) &&
                         digit_px(4'd1,    (rx - 5'd9)  >> 1, c_row);
    wire       c10b_on = in_crow &&  cnt_ten && (rx >= 5'd17) && (rx <= 5'd22) &&
                         digit_px(4'd0,    (rx - 5'd17) >> 1, c_row);
    wire       cnt_on  = c1_on || c10a_on || c10b_on;

    //hearts / pips row
    wire       in_srow = (ry >= 6'd35) && (ry <= 6'd40) && (rx >= 5'd2);
    wire [4:0] s_rel   = rx - 5'd2;                
    wire [2:0] s_r     = ry - 6'd35;               

    //hider hearts
    wire [1:0] h_idx   = (s_rel >= 5'd20) ? 2'd2 : (s_rel >= 5'd10) ? 2'd1 : 2'd0;   
    wire [4:0] h_col   = s_rel - {h_idx, 3'b000} - {h_idx, 1'b0};    
    wire       h_on    = in_srow && (s_rel <= 5'd27) && (h_col <= 5'd7) &&
                         HEART[47 - ({s_r, 3'b000} + h_col[2:0])];   
    wire       h_lit   = (h_idx < hearts);        //1 = still have this heart

    //seeker gun pips
    wire [3:0] g_idx   = s_rel / 5'd3;             //which pip
    wire [4:0] g_col   = s_rel - g_idx * 5'd3;
    //seeker radar pips
    wire [3:0] i_idx   = s_rel / 5'd6;
    wire [4:0] i_col   = s_rel - i_idx * 5'd6;
    wire [3:0] p_idx   = pip_item ? i_idx : g_idx;
    wire       p_on    = in_srow && (s_rel <= 5'd28) &&
                         (pip_item ? (i_col <= 5'd4) : (g_col <= 5'd1));
    wire       p_lit   = (p_idx < pips);         //1 = not used yet
    wire [15:0] p_colour = pip_item ? C_RADAR : C_RED;

    //timer M:SS
    wire       in_trow = (ry >= 6'd47) && (ry <= 6'd56);
    wire [2:0] t_row   = (ry - 6'd47) >> 1;        //>>1 cos digits are drawn 2x
    wire       tm_on   = in_trow && (rx >= 5'd3)  && (rx <= 5'd8)  && digit_px(t_min, (rx - 5'd3)  >> 1, t_row);
    wire       tt_on   = in_trow && (rx >= 5'd15) && (rx <= 5'd20) && digit_px(t_ten, (rx - 5'd15) >> 1, t_row);
    wire       to_on   = in_trow && (rx >= 5'd23) && (rx <= 5'd28) && digit_px(t_one, (rx - 5'd23) >> 1, t_row);
  
    //colon
    wire       col_on  = (rx >= 5'd11) && (rx <= 5'd12) &&
                         ((ry >= 6'd49 && ry <= 6'd50) || (ry >= 6'd53 && ry <= 6'd54));
    wire       time_on = tm_on || tt_on || to_on || col_on;

    //pick the colour
    always @(*) begin
        if (!in_hud)                pixel_data = C_BLACK;
        else if (icon_on)           pixel_data = icon_colour(icon, ic_v);
        else if (cnt_on)            pixel_data = (count == 4'd0) ? C_RED : C_WHITE;
        else if (hider_r && h_on)   pixel_data = h_lit ? C_RED : C_DGREY;
        else if (!hider_r && p_on)  pixel_data = p_lit ? p_colour : C_DGREY;
        else if (time_on)           pixel_data = t_low ? C_RED : C_WHITE;
        else                        pixel_data = C_BLACK;
    end

endmodule