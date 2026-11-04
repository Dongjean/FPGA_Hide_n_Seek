`timescale 1ns / 1ps
// Loopback test: uart_transmitter -> uart_receiver.
// The receiver is set 2% off the transmitter's baud rate to check it still works
// when the two boards' clocks are not exactly equal.

module tb_uart;
    localparam integer CLK_HZ = 10_000_000;
    localparam integer BAUD   = 100_000;

    reg clk = 1'b0;
    always #50 clk = ~clk;   // 10 MHz

    reg reset = 1'b1;
    reg start = 1'b0;
    reg [7:0]data_in = 8'd0;
    wire line;
    wire busy;
    wire [7:0]data_out;
    wire valid;
    wire frame_error;

    uart_transmitter #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut_tx (
        .clk(clk), .reset(reset), .start(start), .data_in(data_in), .tx(line), .busy(busy)
    );
    uart_receiver #(.CLK_HZ(CLK_HZ), .BAUD(BAUD * 102 / 100)) dut_rx (
        .clk(clk), .reset(reset), .rx(line), .data_out(data_out), .valid(valid), .frame_error(frame_error)
    );

    integer errors = 0;
    integer received = 0;
    reg [7:0]expected [0:255];

    always @(posedge clk) begin
        if (valid) begin
            if (data_out !== expected[received]) begin
                $display("FAIL byte %0d: got %02h expected %02h", received, data_out, expected[received]);
                errors = errors + 1;
            end
            received = received + 1;
        end
        if (frame_error) begin
            $display("FAIL unexpected framing error");
            errors = errors + 1;
        end
    end

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            expected[i] = (i == 0) ? 8'h00 : (i == 1) ? 8'hFF : (i == 2) ? 8'hA5 : $random;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        // Stimulus changes on the falling edge so it never races the design's rising edge
        for (i = 0; i < 256; i = i + 1) begin
            @(negedge clk);
            while (busy) @(negedge clk);
            data_in = expected[i];
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            @(negedge clk);
        end
        while (busy) @(posedge clk);
        repeat (200) @(posedge clk);
        if (received != 256) begin
            $display("FAIL received %0d of 256 bytes", received);
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS tb_uart: 256 bytes sent and received, receiver 2%% off baud");
        else             $display("FAIL tb_uart: %0d errors", errors);
        $finish;
    end
endmodule
