`timescale 1ns / 1ps

module game_screens
(
    input  clk,
    input  frame_begin,
    input  [1:0]  state,
    input  [12:0] pixel_index,
    output reg [15:0] pixel_data
);
    localparam [1:0] S_MENU    = 2'd0;
    localparam [1:0] S_PLAYING = 2'd1;
    localparam [1:0] S_END     = 2'd2;
    
    localparam [15:0] COL_WHITE  = 16'hFFFF;
    localparam [15:0] COL_YELLOW = 16'hFFE0;
    localparam [15:0] COL_GREEN  = 16'h07E0;
    localparam [15:0] COL_MENU_BG = 16'h0005; // Dark blue
    localparam [15:0] COL_END_BG  = 16'h0140; // Dark green

    // pixel_index coordinate mapping
    wire [5:0] py = pixel_index / 13'd96;
    wire [6:0] px = pixel_index - ({7'd0, py} << 6) - ({7'd0, py} << 5);

    // Blinking prompt (toggles about every half second)
    reg [5:0] blink = 6'd0;
    always @(posedge clk)
        if (frame_begin) blink <= blink + 6'd1;

    // Menu text
    wire t_hide, t_nseek, t_start;
    text_line #(.N(4), .SCALE(2)) hide  (.px(px), .py(py), .x0(7'd24), .y0(6'd6),  .str("HIDE"),       .on(t_hide));
    text_line #(.N(6), .SCALE(2)) nseek (.px(px), .py(py), .x0(7'd12), .y0(6'd22), .str("N SEEK"),     .on(t_nseek));
    text_line #(.N(10),.SCALE(1)) start (.px(px), .py(py), .x0(7'd18), .y0(6'd48), .str("C TO START"), .on(t_start));

    // End text
    wire t_win, t_menu;
    text_line #(.N(7), .SCALE(2)) youwin  (.px(px), .py(py), .x0(7'd6),  .y0(6'd14), .str("YOU WIN"),     .on(t_win));
    text_line #(.N(10),.SCALE(1)) cformenu (.px(px), .py(py), .x0(7'd18), .y0(6'd44), .str("C FOR MENU"), .on(t_menu));

    wire border = (px < 7'd2) || (px > 7'd93) || (py < 6'd2) || (py > 6'd61);

    always @(*) begin
        if (state == S_END) begin
            // END screen
            if (border)      pixel_data = COL_GREEN;
            else if (t_win)  pixel_data = COL_YELLOW;
            else if (t_menu) pixel_data = COL_WHITE;
            else             pixel_data = COL_END_BG;
        end else begin
            // state == S_MENU
            // When state == S_PLAYING, pixel_data wont even display this
            // MENU screen
            if (border)                   pixel_data = COL_YELLOW;
            else if (t_hide || t_nseek)   pixel_data = COL_YELLOW;
            else if (t_start && blink[5]) pixel_data = COL_WHITE;
            else                          pixel_data = COL_MENU_BG;
        end
    end
endmodule