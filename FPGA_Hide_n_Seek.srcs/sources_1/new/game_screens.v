`timescale 1ns / 1ps

// Menu, pause and end screens for OLED #1 (96 x 64).
//   Menu (state 0):  title and the blinking start prompt.
//   Pause (state 1 while game_paused): "PAUSED", then
//       - I paused:               "C TO RESUME" (blinking) and "HOLD D: QUIT"
//       - the other player did:   "WAITING FOR" / "OTHER PLAYER"
//       - the link is down:       "LINK LOST" / "CHECK CABLE"
//   End (state 2): the same on both boards: "GAME OVER", the winner
//       ("HIDER" or "SEEKER", then "WON") and "C FOR MENU".
// In state 1 without a pause the top module shows the 3D view instead.
module game_screens
(
    input  clk,
    input  frame_begin,
    input  [1:0]  state,
    input  [1:0]  winner,         // end screen: 1 = Hider won, 2 = Seeker won
    input         game_paused,    // either player paused, or the link is down
    input         i_paused,       // I am the one who paused
    input         link_up,
    input  [12:0] pixel_index,
    output reg [15:0] pixel_data
);
    localparam [1:0] S_MENU    = 2'd0;
    localparam [1:0] S_PLAYING = 2'd1;
    localparam [1:0] S_END     = 2'd2;
    
    localparam [15:0] COL_WHITE  = 16'hFFFF;
    localparam [15:0] COL_YELLOW = 16'hFFE0;
    localparam [15:0] COL_GREEN  = 16'h07E0;
    localparam [15:0] COL_RED    = 16'hF800;
    localparam [15:0] COL_MENU_BG = 16'h0005; // Dark blue
    localparam [15:0] COL_END_BG  = 16'h0140; // Dark green
    localparam [15:0] COL_PAUSE_BG = 16'h2104; // Dark grey
    localparam [15:0] COL_HIGHLIGHTED_TEXT  = 16'hFFE0; // Neon Yellow

    // pixel_index coordinate mapping
    wire [5:0] py = pixel_index / 13'd96;
    wire [6:0] px = pixel_index - ({7'd0, py} << 6) - ({7'd0, py} << 5);

    // Blinking prompt (toggles about every half second)
    reg [5:0] blink = 6'd0;
    always @(posedge clk)
        if (frame_begin) blink <= blink + 6'd1;

    // Menu text
    wire [1:0]t_hide;
    wire [1:0]t_nseek;
    wire [1:0]t_start;
    text_line #(.N(4), .SCALE(2)) hide  (.px(px), .py(py), .x0(7'd24), .y0(6'd6),  .str("HIDE"),       .highlighted(1'b0), .on(t_hide));
    text_line #(.N(6), .SCALE(2)) nseek (.px(px), .py(py), .x0(7'd12), .y0(6'd22), .str("N SEEK"),     .highlighted(1'b0), .on(t_nseek));
    text_line #(.N(10),.SCALE(1)) start (.px(px), .py(py), .x0(7'd18), .y0(6'd48), .str("C TO START"), .highlighted(1'b1), .on(t_start));

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
            // END screen (same on both boards)
            if (border)                      pixel_data = COL_GREEN;
            else if (t_over == 2'd1)         pixel_data = COL_WHITE;
            else if (t_winner == 2'd1)       pixel_data = COL_YELLOW;
            else if (t_won == 2'd1)          pixel_data = COL_YELLOW;
            else if (t_menu == 2'd1)         pixel_data = COL_WHITE;
            else                             pixel_data = COL_END_BG;
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
        end else begin
            // MENU screen
            if (border)                           pixel_data = COL_YELLOW;
            else if (t_hide || t_nseek)           pixel_data = COL_YELLOW;
            else if (t_start == 2'd1 && blink[5]) pixel_data = COL_WHITE;
            else if (t_start == 2'd2) pixel_data = COL_HIGHLIGHTED_TEXT;
            else                                  pixel_data = COL_MENU_BG;
        end
    end
endmodule
