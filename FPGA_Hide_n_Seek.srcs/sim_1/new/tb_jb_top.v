`timescale 1ns / 1ps
// Whole-demo check with the team's real Oled_Display and player_movement:
// solo mode, Seeker, ready -> game starts, the bot moves, walking moves me,
// shooting the bot when it is in front of me lowers its health, and every
// OLED pixel the driver asks for has a defined colour.
// Simulates about 0.9 s of real time at 100 MHz, so allow several minutes.
module tb_jb_top;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg btnC = 0, btnU = 0, btnD = 0, btnL = 0, btnR = 0;
    reg [15:0]sw = 16'h0000;
    wire [15:0]led;
    wire [7:0]JB;
    tri1 ps2c, ps2d;               // nothing plugged in

    jb_top dut (
        .clk(clk), .btnC(btnC), .btnU(btnU), .btnD(btnD), .btnL(btnL), .btnR(btnR),
        .sw(sw), .led(led), .seg(), .dp(), .an(), .JB(JB),
        .PS2Clk(ps2c), .PS2Data(ps2d), .link_tx(), .link_rx(1'b1)
    );
    initial dut.oled_clk_gen.clock_divider = 4'd0;   // the team divider has no init value

    integer x_pixels = 0, frames = 0;
    always @(posedge dut.oled_clk) begin
        if (dut.frame_begin) frames = frames + 1;
        if (dut.sample_pixel && ^dut.pixel_data === 1'bx) x_pixels = x_pixels + 1;
    end

    task wait_ms(input integer n);
        integer w;
        begin for (w = 0; w < n; w = w + 1) #(1_000_000); end
    endtask

    integer errors = 0;
    reg signed [15:0]bx0, by0, mx0, my0;
    initial begin
        wait_ms(5);
        sw[12] = 1; sw[13] = 1; sw[11:10] = 2'd1;      // solo, Seeker, medium bot
        wait_ms(60);
        sw[14] = 1;                                      // ready
        wait_ms(20);
        if (!led[15]) begin $display("FAIL game did not start"); errors = errors + 1; end
        bx0 = dut.op_x; by0 = dut.op_y; mx0 = dut.my_x; my0 = dut.my_y;
        btnU = 1;
        wait_ms(400);
        btnU = 0;
        if (dut.op_x == bx0 && dut.op_y == by0) begin $display("FAIL bot did not move"); errors = errors + 1; end
        if (dut.my_x == mx0 && dut.my_y == my0) begin $display("FAIL walking did not move me"); errors = errors + 1; end
        // Put the bot right in front of me and shoot
        force dut.op_x = dut.my_x + 16'sd256;
        force dut.op_y = dut.my_y;
        force dut.my_dir = 8'd64;                        // facing east
        wait_ms(1);
        btnC = 1; wait_ms(30); btnC = 0;
        wait_ms(20);
        release dut.op_x; release dut.op_y; release dut.my_dir;
        wait_ms(1);
        if (dut.op_health != 8'd80) begin $display("FAIL shooting the bot: health %0d, expected 80", dut.op_health); errors = errors + 1; end
        if (x_pixels != 0) begin $display("FAIL %0d undefined pixels sent to the OLED", x_pixels); errors = errors + 1; end
        $display("  demo: %0d OLED frames drawn, game started, bot and player moved, shot took bot to %0d health",
                 frames, dut.op_health);
        if (errors == 0) $display("PASS tb_jb_top");
        else             $display("FAIL tb_jb_top: %0d errors", errors);
        $finish;
    end
endmodule
