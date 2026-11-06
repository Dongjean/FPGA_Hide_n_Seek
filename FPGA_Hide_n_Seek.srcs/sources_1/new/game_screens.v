`timescale 1ns / 1ps

// Menu, pause and end screens on OLED #1 (96 x 64).
//
// The main menu (state == S_MENU) has two pages, chosen by game_mode:
//   game_mode == 0  Mode page:  MULTIPLAYER / SINGLEPLAYER (mode_cursor picks the
//                   highlighted one). MULTIPLAYER is greyed out when it cannot be
//                   picked (no link, or the other board is in singleplayer), and
//                   the bottom line says why.
//   game_mode != 0  Role page:  HIDER / SEEKER (role_pick picks the highlighted one),
//                   with the chosen mode as the title.
//   Pause (state == S_PLAYING while game_paused): "PAUSED", then
//       - I paused:               "C TO RESUME" (blinking) and "HOLD D: QUIT"
//       - the other player did:   "WAITING FOR" / "OTHER PLAYER"
//       - the link is down:       "LINK LOST" / "CHECK CABLE"
//   End (state == S_END): the same on both boards: "GAME OVER", the winner
//       ("HIDER" or "SEEKER", then "WON") and "C FOR MENU".
//
// One shared text engine draws every screen. Only one screen is shown at a time
// and no two lines of text share a pixel row, so for each pixel a small table
// (line_select) picks the line of text on that row: its string (12 characters,
// padded with spaces), position, size and an id. Then a single divide-by-7 and a
// single font lookup decide whether the pixel is part of a letter. (Before, each
// of the 25 lines had its own text_line with its own divider and font lookup.)
module game_screens
(
    input  clk,
    input  frame_begin,
    input  [1:0]  state,
    input  [1:0]  winner,         // end screen: 1 = Hider won, 2 = Seeker won
    input         game_paused,    // either player paused, or the link is down
    input         i_paused,       // I am the one who paused
    input         link_up,
    input  [1:0]  game_mode,      // 0 = mode page, 1 = singleplayer, 2 = multiplayer
    input         mode_cursor,    // mode page: 0 = Multiplayer, 1 = Singleplayer highlighted
    input         mp_available,   // Multiplayer can be picked
    input         peer_in_solo,   // the other board chose Singleplayer
    input  [1:0]  role_pick,      // role page: 1 = Hider, 2 = Seeker highlighted
    input         role_confirmed, // role page: confirmed, waiting for the match to start
    input  [12:0] pixel_index,
    output reg [15:0] pixel_data
);
    `include "font.vh"

    localparam [1:0] S_MENU    = 2'd0;
    localparam [1:0] S_PLAYING = 2'd1;
    localparam [1:0] S_END     = 2'd2;

    localparam [15:0] COL_WHITE    = 16'hFFFF;
    localparam [15:0] COL_YELLOW   = 16'hFFE0;
    localparam [15:0] COL_GREEN    = 16'h07E0;
    localparam [15:0] COL_CYAN     = 16'h07FF;
    localparam [15:0] COL_GREY     = 16'h8410;
    localparam [15:0] COL_RED      = 16'hF800;
    localparam [15:0] COL_MENU_BG  = 16'h0005; // Dark blue
    localparam [15:0] COL_END_BG   = 16'h0140; // Dark green
    localparam [15:0] COL_PAUSE_BG = 16'h2104; // Dark grey
    localparam [15:0] COL_BAR      = 16'hFFE0; // selection bar behind the highlighted option

    // Line ids (which line of text the current pixel row belongs to)
    localparam [3:0] L_NONE     = 4'd0;
    localparam [3:0] L_TITLE    = 4'd1;   // mode page: HIDE N SEEK
    localparam [3:0] L_MULTI    = 4'd2;   // mode page: MULTIPLAYER
    localparam [3:0] L_SINGLE   = 4'd3;   // mode page: SINGLEPLAYER
    localparam [3:0] L_MODE_MSG = 4'd4;   // mode page: NO LINK / P2 IN SOLO / C TO SELECT
    localparam [3:0] L_RT       = 4'd5;   // role page: MULTIPLAYER / SINGLEPLAYER title
    localparam [3:0] L_CHOOSE   = 4'd6;   // role page: CHOOSE ROLE
    localparam [3:0] L_ROLES    = 4'd7;   // role page: HIDER and SEEKER
    localparam [3:0] L_ROLE_MSG = 4'd8;   // role page: STARTING / D BACK C GO
    localparam [3:0] L_OVER     = 4'd9;   // end: GAME OVER
    localparam [3:0] L_WINNER   = 4'd10;  // end: HIDER / SEEKER (double size)
    localparam [3:0] L_WON      = 4'd11;  // end: WON (double size)
    localparam [3:0] L_MENU     = 4'd12;  // end: C FOR MENU
    localparam [3:0] L_PAUSED   = 4'd13;  // pause: PAUSED (double size)
    localparam [3:0] L_PAUSE1   = 4'd14;  // pause: LINK LOST / C TO RESUME / WAITING FOR
    localparam [3:0] L_PAUSE2   = 4'd15;  // pause: CHECK CABLE / HOLD D: QUIT / OTHER PLAYER

    // pixel_index coordinate mapping
    wire [5:0] py = pixel_index / 13'd96;
    wire [6:0] px = pixel_index - ({7'd0, py} << 6) - ({7'd0, py} << 5);

    // Blinking prompt (toggles about every half second)
    reg [5:0] blink = 6'd0;
    always @(posedge clk)
        if (frame_begin) blink <= blink + 6'd1;

    wire mode_page = (game_mode == 2'd0);
    wire multi     = (game_mode == 2'd2);

    // ---------------- Which line of text is on this pixel row ----------------
    reg [95:0] l_str;     // 12 characters, left aligned, padded with spaces
    reg [6:0]  l_x0;
    reg [5:0]  l_y0;
    reg        l_big;     // 1 = double size (14 x 14 pixel characters)
    reg [3:0]  l_id;

    always @(*) begin
        l_str = "            ";
        l_x0  = 7'd0;
        l_y0  = 6'd0;
        l_big = 1'b0;
        l_id  = L_NONE;
        if (state == S_END) begin
            if (py >= 6'd6 && py < 6'd13) begin
                l_id = L_OVER;   l_x0 = 7'd16; l_y0 = 6'd6;  l_str = "GAME OVER   ";
            end else if (py >= 6'd17 && py < 6'd31) begin
                l_id = L_WINNER; l_y0 = 6'd17; l_big = 1'b1;
                if (winner == 2'd2) begin l_x0 = 7'd6;  l_str = "SEEKER      "; end
                else                begin l_x0 = 7'd13; l_str = "HIDER       "; end
            end else if (py >= 6'd33 && py < 6'd47) begin
                l_id = L_WON;    l_x0 = 7'd27; l_y0 = 6'd33; l_big = 1'b1; l_str = "WON         ";
            end else if (py >= 6'd51 && py < 6'd58) begin
                l_id = L_MENU;   l_x0 = 7'd13; l_y0 = 6'd51; l_str = "C FOR MENU  ";
            end
        end else if (state == S_PLAYING) begin
            if (py >= 6'd8 && py < 6'd22) begin
                l_id = L_PAUSED; l_x0 = 7'd6;  l_y0 = 6'd8;  l_big = 1'b1; l_str = "PAUSED      ";
            end else if (py >= 6'd32 && py < 6'd39) begin
                l_id = L_PAUSE1; l_y0 = 6'd32;
                if (!link_up)      begin l_x0 = 7'd16; l_str = "LINK LOST   "; end
                else if (i_paused) begin l_x0 = 7'd10; l_str = "C TO RESUME "; end
                else               begin l_x0 = 7'd10; l_str = "WAITING FOR "; end
            end else if (link_up && i_paused) begin
                if (py >= 6'd46 && py < 6'd53) begin
                    l_id = L_PAUSE2; l_x0 = 7'd6; l_y0 = 6'd46; l_str = "HOLD D: QUIT";
                end
            end else if (py >= 6'd44 && py < 6'd51) begin
                l_id = L_PAUSE2; l_y0 = 6'd44;
                if (!link_up) begin l_x0 = 7'd10; l_str = "CHECK CABLE "; end
                else          begin l_x0 = 7'd6;  l_str = "OTHER PLAYER"; end
            end
        end else if (mode_page) begin
            if (py >= 6'd5 && py < 6'd12) begin
                l_id = L_TITLE;  l_x0 = 7'd10; l_y0 = 6'd5;  l_str = "HIDE N SEEK ";
            end else if (py >= 6'd22 && py < 6'd29) begin
                l_id = L_MULTI;  l_x0 = 7'd10; l_y0 = 6'd22; l_str = "MULTIPLAYER ";
            end else if (py >= 6'd34 && py < 6'd41) begin
                l_id = L_SINGLE; l_x0 = 7'd6;  l_y0 = 6'd34; l_str = "SINGLEPLAYER";
            end else if (py >= 6'd50 && py < 6'd57) begin
                l_id = L_MODE_MSG; l_y0 = 6'd50;
                if (!link_up)          begin l_x0 = 7'd24; l_str = "NO LINK     "; end
                else if (peer_in_solo) begin l_x0 = 7'd13; l_str = "P2 IN SOLO  "; end
                else                   begin l_x0 = 7'd10; l_str = "C TO SELECT "; end
            end
        end else begin
            if (py >= 6'd5 && py < 6'd12) begin
                l_id = L_RT; l_y0 = 6'd5;
                if (multi) begin l_x0 = 7'd10; l_str = "MULTIPLAYER "; end
                else       begin l_x0 = 7'd6;  l_str = "SINGLEPLAYER"; end
            end else if (py >= 6'd18 && py < 6'd25) begin
                l_id = L_CHOOSE; l_x0 = 7'd10; l_y0 = 6'd18; l_str = "CHOOSE ROLE ";
            end else if (py >= 6'd34 && py < 6'd41) begin
                // HIDER at x = 6 and SEEKER at x = 48 share one line
                l_id = L_ROLES;  l_x0 = 7'd6;  l_y0 = 6'd34; l_str = "HIDER SEEKER";
            end else if (py >= 6'd50 && py < 6'd57) begin
                l_id = L_ROLE_MSG; l_y0 = 6'd50;
                if (role_confirmed) begin l_x0 = 7'd20; l_str = "STARTING    "; end
                else                begin l_x0 = 7'd10; l_str = "D BACK C GO "; end
            end
        end
    end

    // ---------------- The shared text engine ----------------
    wire [6:0] dx  = px - l_x0;                          // used only when px >= l_x0
    wire [5:0] dy  = py - l_y0;
    wire [6:0] dxs = l_big ? {1'b0, dx[6:1]} : dx;       // undo the double size
    wire [2:0] row = l_big ? dy[3:1] : dy[2:0];          // 0..6 inside the line
    wire [3:0] idx = dxs / 7'd7;                         // character number
    wire [2:0] col = dxs - idx * 7'd7;                   // 0 = gap, 1..5 = glyph, 6 = gap

    reg [7:0]  ch;
    reg [34:0] bits;
    reg        txt;                                      // this pixel is part of a letter
    always @(*) begin
        ch   = (idx < 4'd12) ? l_str[8*(11-idx) +: 8] : " ";
        bits = glyph_bits(ch);
        txt  = (l_id != L_NONE) && (px >= l_x0) && (idx < 4'd12) &&
               (col != 3'd0) && (col != 3'd6) && bits[34 - (row * 5) + 1 - col];
    end

    // ---------------- Bars, border and colours ----------------
    wire row_mp = (py >= 6'd20) && (py <= 6'd30);
    wire row_sp = (py >= 6'd32) && (py <= 6'd42);
    wire bar_x  = (px >= 7'd4) && (px <= 7'd91);
    wire bar_mp = bar_x && row_mp && !mode_cursor && mp_available;
    wire bar_sp = bar_x && row_sp &&  mode_cursor;

    wire row_role = (py >= 6'd32) && (py <= 6'd42);
    wire bar_h = row_role && (px >= 7'd5)  && (px <= 7'd44) && (role_pick == 2'd1);
    wire bar_s = row_role && (px >= 7'd46) && (px <= 7'd91) && (role_pick == 2'd2);
    wire on_hider_word = (px < 7'd46);                   // HIDER half of the role line

    wire border = (px < 7'd2) || (px > 7'd93) || (py < 6'd2) || (py > 6'd61);

    always @(*) begin
        if (state == S_END) begin
            // END screen (same on both boards)
            if (border)                                   pixel_data = COL_GREEN;
            else if (txt && l_id == L_OVER)               pixel_data = COL_WHITE;
            else if (txt && (l_id == L_WINNER || l_id == L_WON)) pixel_data = COL_YELLOW;
            else if (txt && l_id == L_MENU)               pixel_data = COL_WHITE;
            else                                          pixel_data = COL_END_BG;
        end else if (state == S_PLAYING) begin
            // PAUSE screen (the top module only shows it while game_paused)
            if (border)                                   pixel_data = COL_YELLOW;
            else if (txt && l_id == L_PAUSED)             pixel_data = COL_YELLOW;
            else if (txt && l_id == L_PAUSE1)             pixel_data = !link_up ? COL_RED :
                                                                       i_paused ? (blink[5] ? COL_YELLOW : COL_PAUSE_BG) :
                                                                       COL_WHITE;
            else if (txt && l_id == L_PAUSE2)             pixel_data = COL_WHITE;
            else                                          pixel_data = COL_PAUSE_BG;
        end else if (mode_page) begin
            // MENU: mode page
            if (border)                                   pixel_data = COL_YELLOW;
            else if (txt && l_id == L_TITLE)              pixel_data = COL_YELLOW;
            else if (txt && l_id == L_MULTI)              pixel_data = !mp_available ? COL_GREY :
                                                                       bar_mp ? COL_MENU_BG : COL_WHITE;
            else if (txt && l_id == L_SINGLE)             pixel_data = bar_sp ? COL_MENU_BG : COL_WHITE;
            else if (bar_mp || bar_sp)                    pixel_data = COL_BAR;
            else if (txt && l_id == L_MODE_MSG)           pixel_data = !link_up ? COL_RED :
                                                                       peer_in_solo ? COL_GREY :
                                                                       (blink[5] ? COL_WHITE : COL_MENU_BG);
            else                                          pixel_data = COL_MENU_BG;
        end else begin
            // MENU: role page
            if (border)                                   pixel_data = COL_YELLOW;
            else if (txt && l_id == L_RT)                 pixel_data = COL_CYAN;
            else if (txt && l_id == L_CHOOSE)             pixel_data = COL_WHITE;
            else if (txt && l_id == L_ROLES)              pixel_data = (on_hider_word ? bar_h : bar_s) ? COL_MENU_BG : COL_WHITE;
            else if (bar_h || bar_s)                      pixel_data = COL_BAR;
            else if (txt && l_id == L_ROLE_MSG)           pixel_data = role_confirmed ? (blink[4] ? COL_YELLOW : COL_MENU_BG) :
                                                                       COL_GREY;
            else                                          pixel_data = COL_MENU_BG;
        end
    end
endmodule
