`timescale 1ns / 1ps
// Two copies of link_test_top wired together like two real boards.
// Board B runs 1% faster than board A, as two separate oscillators would.
//  1. Link comes up on both boards, and each shows the other's switches.
//  2. Holding btnD on A makes B count errors and keep its old LED values.
//  3. Unplugging the cable drops link_up within 0.5 s; plugging back in restores it.
// Clocks are scaled down (1 MHz, 50 kbaud) so this simulates quickly.

module tb_link_test_top;
    localparam integer CLK_HZ = 1_000_000;
    localparam integer BAUD   = 50_000;
    localparam integer MS     = 1_000_000;   // ns

    reg clk_a = 1'b0;
    reg clk_b = 1'b0;
    always #500 clk_a = ~clk_a;   // 1 MHz
    always #495 clk_b = ~clk_b;   // about 1% faster

    reg reset = 1'b1;
    reg [15:0]sw_a = 16'h1234;
    reg [15:0]sw_b = 16'h0ABC;
    reg btnD_a = 1'b0;
    reg plugged = 1'b1;

    wire a_tx, b_tx;
    wire [15:0]led_a, led_b;
    wire a_rx = plugged ? b_tx : 1'b1;   // unplugged line is pulled high
    wire b_rx = plugged ? a_tx : 1'b1;

    link_test_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) board_a (
        .clk(clk_a), .btnC(reset), .btnU(1'b0), .btnD(btnD_a), .btnL(1'b0), .btnR(1'b0),
        .sw(sw_a), .link_rx(a_rx), .link_tx(a_tx), .led(led_a), .seg(), .dp(), .an()
    );
    link_test_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) board_b (
        .clk(clk_b), .btnC(reset), .btnU(1'b0), .btnD(1'b0), .btnL(1'b0), .btnR(1'b0),
        .sw(sw_b), .link_rx(b_rx), .link_tx(b_tx), .led(led_b), .seg(), .dp(), .an()
    );

    integer errors = 0;
    reg [7:0]b_errors_before;
    initial begin
        #(1 * MS);
        reset = 1'b0;

        // 1. Link up and switches mirrored
        #(200 * MS);
        if (!led_a[15] || !led_b[15]) begin $display("FAIL link did not come up"); errors = errors + 1; end
        if (led_b[13:0] != sw_a[13:0]) begin $display("FAIL B shows %h, expected A's %h", led_b[13:0], sw_a[13:0]); errors = errors + 1; end
        if (led_a[13:0] != sw_b[13:0]) begin $display("FAIL A shows %h, expected B's %h", led_a[13:0], sw_b[13:0]); errors = errors + 1; end
        sw_a = 16'h0F0F;
        #(150 * MS);
        if (led_b[13:0] != sw_a[13:0]) begin $display("FAIL B did not follow A's switch change"); errors = errors + 1; end
        $display("  step 1: link up, switches mirrored both ways");

        // 2. Error injection from A: B must reject packets and keep showing 0F0F
        b_errors_before = board_b.error_count;
        btnD_a = 1'b1;
        sw_a = 16'h3333;
        #(300 * MS);
        if (board_b.error_count - b_errors_before < 4) begin $display("FAIL B counted only %0d errors", board_b.error_count - b_errors_before); errors = errors + 1; end
        if (led_b[13:0] != 14'h0F0F) begin $display("FAIL corrupted data reached B's LEDs"); errors = errors + 1; end
        btnD_a = 1'b0;
        #(150 * MS);
        if (led_b[13:0] != 14'h3333) begin $display("FAIL B did not recover after injection stopped"); errors = errors + 1; end
        $display("  step 2: corrupted packets rejected, recovery after");

        // 3. Unplug and replug
        plugged = 1'b0;
        #(600 * MS);
        if (led_a[15] || led_b[15]) begin $display("FAIL link_up still on after unplugging"); errors = errors + 1; end
        plugged = 1'b1;
        #(200 * MS);
        if (!led_a[15] || !led_b[15]) begin $display("FAIL link did not come back after replugging"); errors = errors + 1; end
        $display("  step 3: link drops when unplugged and recovers when replugged");

        if (errors == 0) $display("PASS tb_link_test_top");
        else             $display("FAIL tb_link_test_top: %0d errors", errors);
        $finish;
    end
endmodule
