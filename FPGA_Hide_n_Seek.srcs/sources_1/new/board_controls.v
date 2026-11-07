`timescale 1ns / 1ps

//Board controls
//Debounced buttons and switches, with one-clock pulses for shoot, weapon and pause changes.
module board_controls
#(
    parameter integer CLK_HZ        = 6_250_000,
    parameter integer DEBOUNCE_MS   = 10
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

    //Debouncers
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

    //Levels passed straight through
    assign weapon_sel = weapon_clean;
    assign paused     = pause_clean;

    //Edge detection and power-on reset
    reg btnC_prev = 1'b0;
    reg [1:0]weapon_prev = 2'b00;
    reg pause_prev = 1'b0;
    reg [3:0]power_on_count = 4'd0;

    always @(posedge clk) begin
        btnC_prev   <= btnC_clean;
        weapon_prev <= weapon_clean;
        pause_prev  <= pause_clean;

        shoot          <= btnC_clean && !btnC_prev;
        weapon_changed <= (weapon_clean != weapon_prev);
        pause_changed  <= (pause_clean != pause_prev);

        if (power_on_count != 4'd15)
            power_on_count <= power_on_count + 4'd1;

        reset_game <= (power_on_count != 4'd15);
    end
endmodule
