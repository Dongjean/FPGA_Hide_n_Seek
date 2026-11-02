`timescale 1ns / 1ps
// Checks board_controls with a bouncy button:
//  - one btnC press with 5 bounces gives exactly one shoot pulse
//  - a short glitch on btnU does not register as movement
//  - holding btnC for 2 s raises reset_game until it is released
//  - weapon and pause switches give one change pulse each
// The clock is scaled down (10 kHz = 10 clocks per ms) so 2 s simulates quickly.

module tb_board_controls;
    localparam integer CLK_HZ = 10_000;

    reg clk = 1'b0;
    always #50_000 clk = ~clk;   // 10 kHz, 100 us period

    reg btnU = 0, btnD = 0, btnL = 0, btnR = 0, btnC = 0;
    reg [15:0]sw = 16'd0;

    wire move_forward, move_backward, turn_left, turn_right;
    wire shoot, weapon_changed, paused, pause_changed, reset_game;
    wire [1:0]weapon_sel;

    board_controls #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(10), .HOLD_RESET_MS(2000)) dut (
        .clk(clk), .btnU(btnU), .btnD(btnD), .btnL(btnL), .btnR(btnR), .btnC(btnC), .sw(sw),
        .move_forward(move_forward), .move_backward(move_backward),
        .turn_left(turn_left), .turn_right(turn_right), .shoot(shoot),
        .weapon_sel(weapon_sel), .weapon_changed(weapon_changed),
        .paused(paused), .pause_changed(pause_changed), .reset_game(reset_game)
    );

    integer shoots = 0, weapon_pulses = 0, pause_pulses = 0, forward_seen = 0;
    integer errors = 0;
    always @(posedge clk) begin
        if (shoot) shoots = shoots + 1;
        if (weapon_changed) weapon_pulses = weapon_pulses + 1;
        if (pause_changed) pause_pulses = pause_pulses + 1;
        if (move_forward) forward_seen = forward_seen + 1;
    end

    localparam integer MS = 1_000_000;   // 1 ms in ns

    integer i;
    initial begin
        // Power-on reset lasts 16 clocks (1.6 ms at 10 kHz)
        #(3 * MS);
        if (reset_game) begin $display("FAIL power-on reset never ended"); errors = errors + 1; end

        // Bouncy press: 5 bounces of 0.5 ms, then held for 50 ms
        for (i = 0; i < 5; i = i + 1) begin
            btnC = 1; #(MS / 2);
            btnC = 0; #(MS / 2);
        end
        btnC = 1; #(50 * MS);
        btnC = 0; #(30 * MS);
        if (shoots != 1) begin $display("FAIL bouncy press gave %0d shoot pulses", shoots); errors = errors + 1; end

        // 3 ms glitch on btnU must be ignored
        btnU = 1; #(3 * MS); btnU = 0; #(30 * MS);
        if (forward_seen != 0) begin $display("FAIL short glitch registered as movement"); errors = errors + 1; end

        // Real press on btnU must register
        btnU = 1; #(30 * MS);
        if (!move_forward) begin $display("FAIL held btnU not seen"); errors = errors + 1; end
        btnU = 0; #(30 * MS);

        // Hold btnC for 2.1 s: reset_game must go high, then low after release
        btnC = 1; #(1900 * MS);
        if (reset_game) begin $display("FAIL reset too early"); errors = errors + 1; end
        #(200 * MS);
        if (!reset_game) begin $display("FAIL reset not raised after 2 s hold"); errors = errors + 1; end
        btnC = 0; #(30 * MS);
        if (reset_game) begin $display("FAIL reset still high after release"); errors = errors + 1; end

        // Weapon and pause switches
        sw[0] = 1; #(30 * MS);
        sw[15] = 1; #(30 * MS);
        if (weapon_sel != 2'b01 || weapon_pulses != 1) begin $display("FAIL weapon switch"); errors = errors + 1; end
        if (!paused || pause_pulses != 1) begin $display("FAIL pause switch"); errors = errors + 1; end

        if (errors == 0) $display("PASS tb_board_controls");
        else             $display("FAIL tb_board_controls: %0d errors", errors);
        $finish;
    end
endmodule
