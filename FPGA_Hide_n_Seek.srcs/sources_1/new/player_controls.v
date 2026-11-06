`timescale 1ns / 1ps
// All player controls in one place: Basys3 buttons and switches (board_controls)
// plus a USB mouse OR keyboard on the Basys3 USB port (usb_mouse_keyboard).
// Every control works from any input device, so the rest of the game only sees
// these outputs.
//
//                 Buttons/switches   Mouse                Keyboard
//   walk          btnU / btnD        -                    W / S or Up / Down
//   turn          btnL / btnR        move left / right    A / D or Left / Right
//   shoot         btnC press         left click           Space
//   weapon        sw[1:0]            right click (swap)   1 / 2
//   pause/resume  flip sw[15]        -                    Esc or P
//   confirm       -                  middle click         Enter
//
// Mouse turning: horizontal movement is added up, and each frame where at least
// MOUSE_STEP counts have built up turns the player one step (the same turn speed
// as holding a button). A fast flick is spread over the next few frames.

module player_controls
#(
    parameter integer CLK_HZ        = 6_250_000,
    parameter integer MOUSE_STEP    = 4,
    parameter integer POWERUP_MS    = 500
)
(
    input clk,
    input frame_tick,              // frame_begin from the OLED driver
    input btnU,
    input btnD,
    input btnL,
    input btnR,
    input btnC,
    input [15:0]sw,
    inout ps2_clk,
    inout ps2_data,

    output move_forward,
    output move_backward,
    output turn_left,
    output turn_right,
    output reg shoot = 1'b0,
    output reg [1:0]weapon_sel = 2'd0,
    output reg weapon_changed = 1'b0,
    output reg paused = 1'b0,
    output reg pause_changed = 1'b0,
    output reg confirm = 1'b0,
    output reset_game,
    output mouse_present,
    output keyboard_present,
    output [15:0]ps2_debug        // {detection state, bytes received mod 16, last byte}
);
    // ---------------- Buttons and switches ----------------
    wire btn_forward, btn_backward, btn_left, btn_right, btn_shoot;
    wire [1:0]sw_weapon;
    wire sw_weapon_changed, sw_paused, sw_pause_changed;

    board_controls #(
        .CLK_HZ        (CLK_HZ)
    ) board_controls (
        .clk            (clk),
        .btnU           (btnU),
        .btnD           (btnD),
        .btnL           (btnL),
        .btnR           (btnR),
        .btnC           (btnC),
        .sw             (sw),
        .move_forward   (btn_forward),
        .move_backward  (btn_backward),
        .turn_left      (btn_left),
        .turn_right     (btn_right),
        .shoot          (btn_shoot),
        .weapon_sel     (sw_weapon),
        .weapon_changed (sw_weapon_changed),
        .paused         (sw_paused),
        .pause_changed  (sw_pause_changed),
        .reset_game     (reset_game)
    );

    // ---------------- Mouse or keyboard ----------------
    wire mouse_event, mouse_left, mouse_right, mouse_middle;
    wire signed [8:0]mouse_dx;
    wire key_up, key_down, key_left, key_right, key_fire;
    wire key_weapon1, key_weapon2, key_pause, key_enter;

    usb_mouse_keyboard #(.CLK_HZ(CLK_HZ), .POWERUP_MS(POWERUP_MS)) usb_device (
        .clk              (clk),
        .reset            (reset_game),
        .ps2_clk          (ps2_clk),
        .ps2_data         (ps2_data),
        .mouse_present    (mouse_present),
        .keyboard_present (keyboard_present),
        .mouse_event      (mouse_event),
        .mouse_dx         (mouse_dx),
        .mouse_dy         (),
        .mouse_left       (mouse_left),
        .mouse_right      (mouse_right),
        .mouse_middle     (mouse_middle),
        .key_up           (key_up),
        .key_down         (key_down),
        .key_left         (key_left),
        .key_right        (key_right),
        .key_fire         (key_fire),
        .key_weapon1      (key_weapon1),
        .key_weapon2      (key_weapon2),
        .key_pause        (key_pause),
        .key_enter        (key_enter),
        .debug            (ps2_debug)
    );

    // ---------------- Mouse turning ----------------
    localparam signed [15:0]STEP    = MOUSE_STEP;
    localparam signed [15:0]BACKLOG = 4 * MOUSE_STEP;   // at most 4 frames of turning stored

    reg signed [15:0]turn_amount = 16'sd0;
    reg mouse_turn_left = 1'b0;
    reg mouse_turn_right = 1'b0;
    reg signed [15:0]next_amount;

    always @(posedge clk) begin
        next_amount = turn_amount;
        if (mouse_event)
            next_amount = next_amount + mouse_dx;

        if (frame_tick) begin
            mouse_turn_right <= 1'b0;
            mouse_turn_left  <= 1'b0;
            if (next_amount >= STEP) begin
                mouse_turn_right <= 1'b1;
                next_amount = next_amount - STEP;
            end else if (next_amount <= -STEP) begin
                mouse_turn_left <= 1'b1;
                next_amount = next_amount + STEP;
            end
        end

        if (next_amount > BACKLOG)
            next_amount = BACKLOG;
        else if (next_amount < -BACKLOG)
            next_amount = -BACKLOG;

        if (reset_game || !mouse_present)
            turn_amount <= 16'sd0;
        else
            turn_amount <= next_amount;
    end

    assign move_forward  = btn_forward  || key_up;
    assign move_backward = btn_backward || key_down;
    assign turn_left     = btn_left     || key_left  || mouse_turn_left;
    assign turn_right    = btn_right    || key_right || mouse_turn_right;

    // ---------------- Shoot, weapon, pause, confirm ----------------
    // For 50 ms after a reset the switch debouncers are still settling, so switch
    // changes are ignored (otherwise sw[15] up at power-on would toggle pause).
    localparam integer SETTLE_CLKS = CLK_HZ / 20;
    reg [31:0]settle_count = 32'd0;
    wire settled = (settle_count == SETTLE_CLKS);

    reg mouse_left_prev = 1'b0;
    reg mouse_right_prev = 1'b0;
    reg mouse_middle_prev = 1'b0;
    reg key_fire_prev = 1'b0;

    always @(posedge clk) begin
        mouse_left_prev   <= mouse_left;
        mouse_right_prev  <= mouse_right;
        mouse_middle_prev <= mouse_middle;
        key_fire_prev     <= key_fire;

        shoot          <= btn_shoot || (mouse_left && !mouse_left_prev) || (key_fire && !key_fire_prev);
        confirm        <= key_enter || (mouse_middle && !mouse_middle_prev);
        weapon_changed <= 1'b0;
        pause_changed  <= 1'b0;

        if (reset_game)
            settle_count <= 32'd0;
        else if (!settled)
            settle_count <= settle_count + 32'd1;

        if (reset_game || !settled) begin
            weapon_sel <= sw_weapon;
            paused     <= 1'b0;
        end else begin
            // Whichever device changed the weapon last wins
            if (sw_weapon_changed) begin
                weapon_sel     <= sw_weapon;
                weapon_changed <= 1'b1;
            end else if (key_weapon1 && weapon_sel != 2'd0) begin
                weapon_sel     <= 2'd0;
                weapon_changed <= 1'b1;
            end else if (key_weapon2 && weapon_sel != 2'd1) begin
                weapon_sel     <= 2'd1;
                weapon_changed <= 1'b1;
            end else if (mouse_right && !mouse_right_prev) begin
                weapon_sel     <= {1'b0, ~weapon_sel[0]};
                weapon_changed <= 1'b1;
            end

            // Flipping sw[15] either way, or Esc/P, toggles pause
            if (sw_pause_changed || key_pause) begin
                paused        <= ~paused;
                pause_changed <= 1'b1;
            end
        end
    end
endmodule
