`timescale 1ns / 1ps
// Two boards running My_Top_Module, wired JA1 -> JA2 both ways (as on the bench).
// Board A is the Seeker, board B the Hider. Checks:
//   1. both ready -> both boards start the match with the same map seed
//   2. each board sees the other player's position, including after walking
//   3. a hit on board A takes board B's health from 100 to 80, and A sees it
//   4. pausing on board B pauses board A
// Simulates about 0.5 s of real time at 100 MHz, so allow a few minutes.
module tb_My_Top_Module;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg a_btnC = 0, a_btnU = 0, a_btnD = 0, a_btnL = 0, a_btnR = 0;
    reg b_btnC = 0, b_btnU = 0, b_btnD = 0, b_btnL = 0, b_btnR = 0;
    reg [15:0]a_sw = 16'h0000, b_sw = 16'h0000;
    wire [15:0]a_led, b_led;
    wire a_tx, b_tx;
    tri1 a_ps2c, a_ps2d, b_ps2c, b_ps2d;     // nothing plugged into the USB ports

    My_Top_Module a (
        .clk(clk), .btnC(a_btnC), .btnU(a_btnU), .btnD(a_btnD), .btnL(a_btnL), .btnR(a_btnR),
        .sw(a_sw), .led(a_led), .seg(), .dp(), .an(), .JB(),
        .PS2Clk(a_ps2c), .PS2Data(a_ps2d), .link_tx(a_tx), .link_rx(b_tx)
    );
    My_Top_Module b (
        .clk(clk), .btnC(b_btnC), .btnU(b_btnU), .btnD(b_btnD), .btnL(b_btnL), .btnR(b_btnR),
        .sw(b_sw), .led(b_led), .seg(), .dp(), .an(), .JB(),
        .PS2Clk(b_ps2c), .PS2Data(b_ps2d), .link_tx(b_tx), .link_rx(a_tx)
    );
    // The team clock divider has no initial value; on the FPGA it starts at 0
    initial begin
        a.oled_clk_gen.clock_divider = 4'd0;
        b.oled_clk_gen.clock_divider = 4'd0;
    end

    task wait_ms(input integer n);
        integer w;
        begin for (w = 0; w < n; w = w + 1) #(1_000_000); end
    endtask

    integer errors = 0;
    integer t;
    reg signed [15:0]a_x0;
    initial begin
        wait_ms(5);
        a_sw[13] = 1'b1;                 // A: Seeker, B: Hider, both playing the other board
        b_sw[13] = 1'b0;
        wait_ms(60);
        a_sw[14] = 1'b1;                 // both ready
        b_sw[14] = 1'b1;
        t = 0;
        while (!(a_led[15] && b_led[15]) && t < 200) begin wait_ms(1); t = t + 1; end

        // 1. Start
        if (!a_led[14] || !b_led[14]) begin $display("FAIL link not up"); errors = errors + 1; end
        if (!a_led[15] || !b_led[15]) begin $display("FAIL match did not start on both boards"); errors = errors + 1; end
        if (a.game_seed != b.game_seed) begin $display("FAIL different map seeds %h / %h", a.game_seed, b.game_seed); errors = errors + 1; end
        $display("  step 1: match started after %0d ms, both boards have seed %h", t, a.game_seed);

        // 2. Positions
        a_x0 = a.player_x;
        a_btnU = 1'b1; wait_ms(150); a_btnU = 1'b0;
        wait_ms(50);
        if (a.player_x == a_x0) begin $display("FAIL board A did not walk"); errors = errors + 1; end
        if (b.op_x != a.player_x || b.op_y != a.player_y || b.op_dir != a.view_dir) begin
            $display("FAIL board B sees A at (%0d,%0d) but A is at (%0d,%0d)", b.op_x, b.op_y, a.player_x, a.player_y);
            errors = errors + 1;
        end
        if (a.op_x != b.player_x || a.op_y != b.player_y) begin $display("FAIL board A does not see B"); errors = errors + 1; end
        $display("  step 2: A walked from x=%0d to x=%0d; B sees A at x=%0d", a_x0, a.player_x, b.op_x);

        // 3. Hit: put B right in front of A for the simple aim test, then shoot
        force a.multiplayer.op_x = a.player_x + 16'sd256;
        force a.multiplayer.op_y = a.player_y;
        force a.multiplayer.my_dir = 8'd64;
        wait_ms(1);
        a_btnC = 1'b1; wait_ms(30); a_btnC = 1'b0;
        wait_ms(10);
        release a.multiplayer.op_x; release a.multiplayer.op_y; release a.multiplayer.my_dir;
        wait_ms(50);
        if (b.my_health != 8'd80) begin $display("FAIL B health %0d after hit, expected 80", b.my_health); errors = errors + 1; end
        if (a.op_health != 8'd80) begin $display("FAIL A sees B health %0d, expected 80", a.op_health); errors = errors + 1; end
        $display("  step 3: A shot B; B health %0d, A sees %0d", b.my_health, a.op_health);

        // 4. Pause from B
        b_sw[15] = 1'b1;
        wait_ms(60);
        if (!a.game_paused || !b.game_paused) begin $display("FAIL pause on B did not pause both boards"); errors = errors + 1; end
        $display("  step 4: B paused, A paused = %0d", a.game_paused);

        if (errors == 0) $display("PASS tb_My_Top_Module (two boards)");
        else             $display("FAIL tb_My_Top_Module: %0d errors", errors);
        $finish;
    end
endmodule
