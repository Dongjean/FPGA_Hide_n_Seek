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
//   Pause (state == S_PLAYING while game_paused): "PAUSED", then
//       - I paused:               "C TO RESUME" (blinking) and "HOLD D: QUIT"
//       - the other player did:   "WAITING FOR" / "OTHER PLAYER"
//       - the link is down:       "LINK LOST" / "CHECK CABLE"
//   End (state == S_END): the same on both boards: "GAME OVER", the winner
//       ("HIDER" or "SEEKER", then "WON") and "C FOR MENU".
module game_screens
(
    input  clk,
    input  frame_begin,
    input  [1:0]  state,
    input  [1:0]  winner,         // end screen: 1 = Hider won, 2 = Seeker won
    input         game_paused,    // either player paused, or the link is down
    input         i_paused,       // I am the one who paused
    input         link_up,
    input  [1:0]  game_mode,        // 0 = mode page, 1 = singleplayer, 2 = multiplayer
    input         mode_cursor,      // mode page: 0 = Multiplayer, 1 = Singleplayer highlighted
    input         mp_available,     // Multiplayer can be picked
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
    localparam [15:0] COL_PAUSE_BG = 16'h2104; // Dark grey
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

    // End text: "GAME OVER", winner, "WON", "C FOR MENU"
    wire [1:0]t_over;
    wire [1:0]t_hider;
    wire [1:0]t_seeker;
    wire [1:0]t_won;
    wire [1:0]t_menu;
    text_line #(.N(9), .SCALE(1)) gameover (.px(px), .py(py), .x0(7'd16), .y0(6'd6),  .str("GAME OVER"),  .highlighted(1'b0), .on(t_over));
    text_line #(.N(5), .SCALE(2)) hiderw   (.px(px), .py(py), .x0(7'd13), .y0(6'd17), .str("HIDER"),      .highlighted(1'b0), .on(t_hider));
    text_line #(.N(6), .SCALE(2)) seekerw  (.px(px), .py(py), .x0(7'd6),  .y0(6'd17), .str("SEEKER"),     .highlighted(1'b0), .on(t_seeker));
    text_line #(.N(3), .SCALE(2)) wonw     (.px(px), .py(py), .x0(7'd27), .y0(6'd33), .str("WON"),        .highlighted(1'b0), .on(t_won));
    text_line #(.N(10),.SCALE(1)) cformenu (.px(px), .py(py), .x0(7'd13), .y0(6'd51), .str("C FOR MENU"), .highlighted(1'b0), .on(t_menu));
    wire [1:0]t_winner = (winner == 2'd2) ? t_seeker : t_hider;

    // Pause text
    wire [1:0]t_paused;
    wire [1:0]t_resume;
    wire [1:0]t_quit;
    wire [1:0]t_waiting;
    wire [1:0]t_other;
    wire [1:0]t_lost;
    wire [1:0]t_cable;
    text_line #(.N(6), .SCALE(2)) pausedw  (.px(px), .py(py), .x0(7'd6),  .y0(6'd8),  .str("PAUSED"),       .highlighted(1'b0), .on(t_paused));
    text_line #(.N(11),.SCALE(1)) resume   (.px(px), .py(py), .x0(7'd10), .y0(6'd32), .str("C TO RESUME"),  .highlighted(1'b0), .on(t_resume));
    text_line #(.N(12),.SCALE(1)) quit     (.px(px), .py(py), .x0(7'd6),  .y0(6'd46), .str("HOLD D: QUIT"), .highlighted(1'b0), .on(t_quit));
    text_line #(.N(11),.SCALE(1)) waiting  (.px(px), .py(py), .x0(7'd10), .y0(6'd32), .str("WAITING FOR"),  .highlighted(1'b0), .on(t_waiting));
    text_line #(.N(12),.SCALE(1)) otherp   (.px(px), .py(py), .x0(7'd6),  .y0(6'd44), .str("OTHER PLAYER"), .highlighted(1'b0), .on(t_other));
    text_line #(.N(9), .SCALE(1)) lost     (.px(px), .py(py), .x0(7'd16), .y0(6'd32), .str("LINK LOST"),    .highlighted(1'b0), .on(t_lost));
    text_line #(.N(11),.SCALE(1)) cable    (.px(px), .py(py), .x0(7'd10), .y0(6'd44), .str("CHECK CABLE"),  .highlighted(1'b0), .on(t_cable));

    wire border = (px < 7'd2) || (px > 7'd93) || (py < 6'd2) || (py > 6'd61);

    always @(*) begin
        if (state == S_END) begin
            // END screen
            if (border)              pixel_data = COL_GREEN;
            else if (t_win == 2'd1)  pixel_data = COL_YELLOW;
            else if (t_menu == 2'd1) pixel_data = COL_WHITE;
            else if (t_menu == 2'd2) pixel_data = COL_HIGHLIGHTED_TEXT;
            else                     pixel_data = COL_END_BG;
        end else if (state == S_PLAYING) begin
            // PAUSE screen (the top module only shows it while game_paused)
            if (border)                      pixel_data = COL_YELLOW;
            else if (t_paused == 2'd1)       pixel_data = COL_YELLOW;
            else if (!link_up) begin
                if (t_lost == 2'd1)          pixel_data = COL_RED;
                else if (t_cable == 2'd1)    pixel_data = COL_WHITE;
                else                         pixel_data = COL_PAUSE_BG;
            end else if (i_paused) begin
                if (t_resume == 2'd1 && blink[5]) pixel_data = COL_YELLOW;   // blinking prompt
                else if (t_quit == 2'd1)     pixel_data = COL_WHITE;
                else                         pixel_data = COL_PAUSE_BG;
            end else begin
                if (t_waiting == 2'd1 || t_other == 2'd1) pixel_data = COL_WHITE;
                else                         pixel_data = COL_PAUSE_BG;
            end
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
