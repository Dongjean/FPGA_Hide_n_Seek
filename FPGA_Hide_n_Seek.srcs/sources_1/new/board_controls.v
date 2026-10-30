`timescale 1ns / 1ps
// Turns the Basys3 buttons and switches into clean game controls.
//
//   btnU / btnD       walk forward / backward      (held = keep moving)
//   btnL / btnR       turn left / right            (held = keep turning)
//   btnC press        shoot                        (one pulse per press)
//   btnC held 2 s     reset the game               (reset_game high until released)
//   sw[1:0]           weapon select                (rightmost switches)
//   sw[15]            pause                        (leftmost switch)
//
// Because btnC is now the shoot button, the game reset comes from holding it down
// instead. reset_game is also high for the first 16 clocks after the FPGA is
// programmed, so everything starts from a known state.
//
// Every output is in the clk domain, so run this on the same clock as the game
// logic (oled_clk in My_Top_Module) and set CLK_HZ to match.

module board_controls
#(
    parameter integer CLK_HZ        = 6_250_000,
    parameter integer DEBOUNCE_MS   = 10,
    parameter integer HOLD_RESET_MS = 2000
)
(
    input clk,
    input btnU,
    input btnD,
    input btnL,
    input btnR,
    input btnC,
    input [15:0]sw,

    output move_forward,
    output move_backward,
    output turn_left,
    output turn_right,
    output reg shoot = 1'b0,
    output [1:0]weapon_sel,
    output reg weapon_changed = 1'b0,
    output paused,
    output reg pause_changed = 1'b0,
    output reg reset_game = 1'b1
);
    localparam integer HOLD_CLKS = CLK_HZ / 1000 * HOLD_RESET_MS;
    localparam integer HOLD_W    = $clog2(HOLD_CLKS + 1);

    wire btnC_clean;
    wire [1:0]weapon_clean;
    wire pause_clean;

    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_up    (.clk(clk), .raw(btnU),   .clean(move_forward));
    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_down  (.clk(clk), .raw(btnD),   .clean(move_backward));
    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_left  (.clk(clk), .raw(btnL),   .clean(turn_left));
    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_right (.clk(clk), .raw(btnR),   .clean(turn_right));
    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_centre(.clk(clk), .raw(btnC),   .clean(btnC_clean));
    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_sw0   (.clk(clk), .raw(sw[0]),  .clean(weapon_clean[0]));
    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_sw1   (.clk(clk), .raw(sw[1]),  .clean(weapon_clean[1]));
    button_debouncer #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) db_sw15  (.clk(clk), .raw(sw[15]), .clean(pause_clean));

    assign weapon_sel = weapon_clean;
    assign paused     = pause_clean;

    reg btnC_prev = 1'b0;
    reg [1:0]weapon_prev = 2'b00;
    reg pause_prev = 1'b0;
    reg [HOLD_W-1:0]hold_count = 0;
    reg [3:0]power_on_count = 4'd0;

    always @(posedge clk) begin
        btnC_prev   <= btnC_clean;
        weapon_prev <= weapon_clean;
        pause_prev  <= pause_clean;

        // One-clock pulses on changes
        shoot          <= btnC_clean && !btnC_prev;
        weapon_changed <= (weapon_clean != weapon_prev);
        pause_changed  <= (pause_clean != pause_prev);

        // Long press on btnC resets the game
        if (!btnC_clean)
            hold_count <= 0;
        else if (hold_count != HOLD_CLKS)
            hold_count <= hold_count + 1'b1;

        // Power-on reset for the first 16 clocks
        if (power_on_count != 4'd15)
            power_on_count <= power_on_count + 4'd1;

        reset_game <= (power_on_count != 4'd15) || (hold_count == HOLD_CLKS);
    end
endmodule
