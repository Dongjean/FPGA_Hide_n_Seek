`timescale 1ns / 1ps

// Menu and end screens on OLED #1.
//
// The main menu (state == S_MENU) has two pages, chosen by game_mode:
//   game_mode == 0  Mode page:  MULTIPLAYER / SINGLEPLAYER (mode_cursor picks the
//                   highlighted one). MULTIPLAYER is greyed out when it cannot be
//                   picked (no link, or the other board is in singleplayer), and
//                   the bottom line says why.
//   game_mode != 0  Role page:  HIDER / SEEKER (role_pick picks the highlighted one),
//                   with the chosen mode as the title.
module game_screens
(
    input  clk,
    input  frame_begin,
    input  [1:0]  state,
    input  [1:0]  game_mode,        // 0 = mode page, 1 = singleplayer, 2 = multiplayer
    input         mode_cursor,      // mode page: 0 = Multiplayer, 1 = Singleplayer highlighted
    input         mp_available,     // Multiplayer can be picked
    input         link_up,
    input         peer_in_solo,     // the other board chose Singleplayer
    input  [1:0]  role_pick,        // role page: 1 = Hider, 2 = Seeker highlighted
    input         role_confirmed,   // role page: confirmed, waiting for the match to start
    input  [12:0] pixel_index,
    output reg [15:0] pixel_data
);
    localparam [1:0] S_MENU    = 2'd0;
    localparam [1:0] S_PLAYING = 2'd1;
    localparam [1:0] S_END     = 2'd2;
    
    localparam [15:0] COL_WHITE  = 16'hFFFF;
    localparam [15:0] COL_YELLOW = 16'hFFE0;
    localparam [15:0] COL_GREEN  = 16'h07E0;
    localparam [15:0] COL_CYAN    = 16'h07FF;
    localparam [15:0] COL_GREY    = 16'h8410;
    localparam [15:0] COL_RED     = 16'hF800;
    localparam [15:0] COL_MENU_BG = 16'h0005; // Dark blue
    localparam [15:0] COL_END_BG  = 16'h0140; // Dark green
    localparam [15:0] COL_HIGHLIGHTED_TEXT  = 16'hFFE0; // Neon Yellow
    localparam [15:0] COL_BAR     = 16'hFFE0; // selection bar behind the highlighted option

    // pixel_index coordinate mapping
    wire [5:0] py = pixel_index / 13'd96;
    wire [6:0] px = pixel_index - ({7'd0, py} << 6) - ({7'd0, py} << 5);

    // Blinking prompt (toggles about every half second)
    reg [5:0] blink = 6'd0;
    always @(posedge clk)
        if (frame_begin) blink <= blink + 6'd1;

    // Start Menu
    wire mode_page = (game_mode == 2'd0);
    wire multi     = (game_mode == 2'd2);
    wire [1:0] t_title, t_multi, t_single, t_nolink, t_p2solo, t_select;
    text_line #(.N(11), .SCALE(1)) title   (.px(px), .py(py), .x0(7'd10), .y0(6'd5),  .str("HIDE N SEEK"),  .highlighted(1'b0), .on(t_title));
    text_line #(.N(11), .SCALE(1)) mp_txt  (.px(px), .py(py), .x0(7'd10), .y0(6'd22), .str("MULTIPLAYER"),  .highlighted(1'b0), .on(t_multi));
    text_line #(.N(12), .SCALE(1)) sp_txt  (.px(px), .py(py), .x0(7'd6),  .y0(6'd34), .str("SINGLEPLAYER"), .highlighted(1'b0), .on(t_single));
    text_line #(.N(7),  .SCALE(1)) nolink  (.px(px), .py(py), .x0(7'd24), .y0(6'd50), .str("NO LINK"),      .highlighted(1'b0), .on(t_nolink));
    text_line #(.N(10), .SCALE(1)) p2solo  (.px(px), .py(py), .x0(7'd13), .y0(6'd50), .str("P2 IN SOLO"),   .highlighted(1'b0), .on(t_p2solo));
    text_line #(.N(11), .SCALE(1)) select  (.px(px), .py(py), .x0(7'd10), .y0(6'd50), .str("C TO SELECT"),  .highlighted(1'b0), .on(t_select));

    // Selection bars: 2 px of padding around each option row
    wire row_mp = (py >= 6'd20) && (py <= 6'd30);
    wire row_sp = (py >= 6'd32) && (py <= 6'd42);
    wire bar_x  = (px >= 7'd4) && (px <= 7'd91);
    wire bar_mp = bar_x && row_mp && !mode_cursor && mp_available;
    wire bar_sp = bar_x && row_sp &&  mode_cursor;

    // ---------------- Role page ----------------
    wire [1:0] t_rt_mp, t_rt_sp, t_choose, t_hider, t_seeker, t_back, t_starting;
    text_line #(.N(11), .SCALE(1)) rt_mp    (.px(px), .py(py), .x0(7'd10), .y0(6'd5),  .str("MULTIPLAYER"),  .highlighted(1'b0), .on(t_rt_mp));
    text_line #(.N(12), .SCALE(1)) rt_sp    (.px(px), .py(py), .x0(7'd6),  .y0(6'd5),  .str("SINGLEPLAYER"), .highlighted(1'b0), .on(t_rt_sp));
    text_line #(.N(11), .SCALE(1)) choose   (.px(px), .py(py), .x0(7'd10), .y0(6'd18), .str("CHOOSE ROLE"),  .highlighted(1'b0), .on(t_choose));
    text_line #(.N(5),  .SCALE(1)) hider    (.px(px), .py(py), .x0(7'd8),  .y0(6'd34), .str("HIDER"),        .highlighted(1'b0), .on(t_hider));
    text_line #(.N(6),  .SCALE(1)) seeker   (.px(px), .py(py), .x0(7'd48), .y0(6'd34), .str("SEEKER"),       .highlighted(1'b0), .on(t_seeker));
    text_line #(.N(11), .SCALE(1)) back     (.px(px), .py(py), .x0(7'd10), .y0(6'd50), .str("D BACK C GO"),  .highlighted(1'b0), .on(t_back));
    text_line #(.N(8),  .SCALE(1)) starting (.px(px), .py(py), .x0(7'd20), .y0(6'd50), .str("STARTING"),     .highlighted(1'b0), .on(t_starting));

    wire row_role = (py >= 6'd32) && (py <= 6'd42);
    wire bar_h = row_role && (px >= 7'd5)  && (px <= 7'd44) && (role_pick == 2'd1);
    wire bar_s = row_role && (px >= 7'd46) && (px <= 7'd91) && (role_pick == 2'd2);

    // End text
    wire [1:0]t_win;
    wire [1:0]t_menu;
    text_line #(.N(7), .SCALE(2)) youwin  (.px(px), .py(py), .x0(7'd6),  .y0(6'd14), .str("YOU WIN"),     .highlighted(0), .on(t_win));
    text_line #(.N(10),.SCALE(1)) cformenu (.px(px), .py(py), .x0(7'd18), .y0(6'd44), .str("C FOR MENU"), .highlighted(1), .on(t_menu));

    wire border = (px < 7'd2) || (px > 7'd93) || (py < 6'd2) || (py > 6'd61);

    always @(*) begin
        if (state == S_END) begin
            // END screen
            if (border)              pixel_data = COL_GREEN;
            else if (t_win == 2'd1)  pixel_data = COL_YELLOW;
            else if (t_menu == 2'd1) pixel_data = COL_WHITE;
            else if (t_menu == 2'd2) pixel_data = COL_HIGHLIGHTED_TEXT;
            else                     pixel_data = COL_END_BG;
        end else if (mode_page) begin
            // MENU: mode page
            // (When state == S_PLAYING, pixel_data wont even display this)
            if (border)                       pixel_data = COL_YELLOW;
            else if (t_title == 2'd1)         pixel_data = COL_YELLOW;
            else if (t_multi == 2'd1)         pixel_data = !mp_available ? COL_GREY :
                                                           bar_mp ? COL_MENU_BG : COL_WHITE;
            else if (t_single == 2'd1)        pixel_data = bar_sp ? COL_MENU_BG : COL_WHITE;
            else if (bar_mp || bar_sp)        pixel_data = COL_BAR;
            else if (!link_up) begin
                if (t_nolink == 2'd1)         pixel_data = COL_RED;
                else                          pixel_data = COL_MENU_BG;
            end else if (peer_in_solo) begin
                if (t_p2solo == 2'd1)         pixel_data = COL_GREY;
                else                          pixel_data = COL_MENU_BG;
            end else if (t_select == 2'd1 && blink[5]) pixel_data = COL_WHITE;
            else                              pixel_data = COL_MENU_BG;
        end else begin
            // MENU: role page
            if (border)                              pixel_data = COL_YELLOW;
            else if (multi  && t_rt_mp == 2'd1)      pixel_data = COL_CYAN;
            else if (!multi && t_rt_sp == 2'd1)      pixel_data = COL_CYAN;
            else if (t_choose == 2'd1)               pixel_data = COL_WHITE;
            else if (t_hider == 2'd1)                pixel_data = bar_h ? COL_MENU_BG : COL_WHITE;
            else if (t_seeker == 2'd1)               pixel_data = bar_s ? COL_MENU_BG : COL_WHITE;
            else if (bar_h || bar_s)                 pixel_data = COL_BAR;
            else if (role_confirmed) begin
                if (t_starting == 2'd1 && blink[4])  pixel_data = COL_YELLOW;
                else                                 pixel_data = COL_MENU_BG;
            end else if (t_back == 2'd1)             pixel_data = COL_GREY;
            else                                     pixel_data = COL_MENU_BG;
        end
    end
endmodule