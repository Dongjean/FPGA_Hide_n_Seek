`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// flashbang_ctrl - Hider's Flashbang on the Seeker's minimap (Andrew)
//
// When the Hider uses a Flashbang, the Hider's dot on the SEEKER's minimap
// first blinks for BLINK_MS, then disappears for HIDE_MS, then comes back.
//
//   flash   1-cycle: a Flashbang was used against this board's player.
//           Team top: flash = peer_stim_used && !is_hider (the Stim event of
//           Jian Bin's link is reused for the Flashbang).
//   opp_visible  1 = draw the Hider (opponent dot and Pinger blip) as normal.
//
// Timeline after flash:  |-- blink BLINK_MS --|------ hidden HIDE_MS ------| visible
// The blink starts with the dot OFF and toggles every BLINK_HALF_MS (125 ms = 4 Hz).
// A new flash restarts the timeline.  game_paused freezes it; a new match clears it.
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high.
//////////////////////////////////////////////////////////////////////////////////
module flashbang_ctrl
#(
    parameter integer CLK_HZ        = 6_250_000,
    parameter integer BLINK_MS      = 1000,   // blinking part
    parameter integer HIDE_MS       = 5000,   // fully hidden part
    parameter integer BLINK_HALF_MS = 125     // on/off time while blinking
)
(
    input      clk,
    input      reset,
    input      start,          // 1-cycle: new match -> visible
    input      game_paused,    // freezes the timeline
    input      flash,          // 1-cycle: Flashbang used on me
    output     opp_visible,    // 1 = draw the Hider's dot / blip
    output     flash_active    // 1 = blinking or hidden (for an LED)
);
    // Clock counts (CLK_HZ/1000 first, so the products stay inside 32 bits)
    localparam integer CLK_MS     = CLK_HZ / 1000;
    localparam integer HIDE_CLKS  = HIDE_MS * CLK_MS;
    localparam integer TOTAL_CLKS = (BLINK_MS + HIDE_MS) * CLK_MS;   // 37_500_000 at 6.25 MHz
    localparam integer HALF_CLKS  = BLINK_HALF_MS * CLK_MS;          // 781_250

    reg [25:0] left;       // clocks left in the timeline (26 bits > 37.5 M)
    reg [19:0] half_cnt;   // clocks into the current blink half-period (20 bits > 781_250)
    reg        blink_on;   // dot shown in this half-period

    wire blinking = (left > HIDE_CLKS);          // first BLINK_MS of the timeline
    assign flash_active = (left != 26'd0);
    assign opp_visible  = !flash_active || (blinking && blink_on);

    always @(posedge clk) begin
        if (reset || start) begin
            left     <= 26'd0;
            half_cnt <= 20'd0;
            blink_on <= 1'b0;
        end else if (flash) begin
            left     <= TOTAL_CLKS;              // (re)start the timeline
            half_cnt <= 20'd0;
            blink_on <= 1'b0;                    // blink starts with the dot OFF
        end else if (flash_active && !game_paused) begin
            left <= left - 26'd1;
            if (half_cnt == HALF_CLKS - 1) begin
                half_cnt <= 20'd0;
                blink_on <= ~blink_on;           // 4 Hz blink
            end else begin
                half_cnt <= half_cnt + 20'd1;
            end
        end
    end
endmodule