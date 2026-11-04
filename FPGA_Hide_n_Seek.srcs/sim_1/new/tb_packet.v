`timescale 1ns / 1ps
// Loopback test: packet_sender -> packet_receiver.
//  1. 50 packets with random type, sequence number, length (0 to 16) and payload
//     must all arrive intact.
//  2. A bit is flipped on the line in the middle of a packet: the receiver must
//     report pkt_error and must NOT report it as a good packet.
//  3. The next packet after the corrupted one must arrive correctly (recovery).
//  4. A packet cut off halfway (cable unplugged) must time out with pkt_error.

module tb_packet;
    localparam integer CLK_HZ  = 10_000_000;
    localparam integer BAUD    = 1_000_000;
    localparam integer MAX_LEN = 16;
    localparam integer BIT_NS  = 1_000_000_000 / BAUD;

    reg clk = 1'b0;
    always #50 clk = ~clk;   // 10 MHz

    reg reset = 1'b1;
    reg send = 1'b0;
    reg [7:0]pkt_type, pkt_seq, pkt_len;
    reg [8*MAX_LEN-1:0]pkt_payload;
    wire busy;
    wire tx_line;

    reg flip = 1'b0;    // XORed onto the line to inject a bit error
    reg cut = 1'b0;     // forces the line idle to simulate an unplugged cable
    wire rx_line = cut ? 1'b1 : (tx_line ^ flip);

    wire rx_valid, rx_error;
    wire [7:0]rx_type, rx_seq, rx_len;
    wire [8*MAX_LEN-1:0]rx_payload;

    packet_sender #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) dut_tx (
        .clk(clk), .reset(reset), .send(send), .pkt_type(pkt_type), .pkt_seq(pkt_seq),
        .pkt_len(pkt_len), .pkt_payload(pkt_payload), .busy(busy), .tx(tx_line)
    );
    packet_receiver #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) dut_rx (
        .clk(clk), .reset(reset), .rx(rx_line), .pkt_valid(rx_valid), .pkt_type(rx_type),
        .pkt_seq(rx_seq), .pkt_len(rx_len), .pkt_payload(rx_payload), .pkt_error(rx_error)
    );

    integer errors = 0;
    integer good_count = 0;
    integer error_count = 0;
    always @(posedge clk) begin
        if (rx_valid) good_count = good_count + 1;
        if (rx_error) error_count = error_count + 1;
    end

    // Payload with the bytes beyond len cleared, which is what the receiver reports
    function [8*MAX_LEN-1:0]masked(input [8*MAX_LEN-1:0]p, input [7:0]len);
        integer k;
        begin
            masked = 0;
            for (k = 0; k < MAX_LEN; k = k + 1)
                if (k < len) masked[8*k +: 8] = p[8*k +: 8];
        end
    endfunction

    task send_packet(input [7:0]t, input [7:0]s, input [7:0]l, input [8*MAX_LEN-1:0]p);
        begin
            // Stimulus changes on the falling edge so it never races the design's rising edge
            @(negedge clk);
            while (busy) @(negedge clk);
            pkt_type = t; pkt_seq = s; pkt_len = l; pkt_payload = p;
            send = 1'b1;
            @(negedge clk);
            send = 1'b0;
            @(negedge clk);
            while (busy) @(negedge clk);
            repeat (3 * CLK_HZ / BAUD) @(posedge clk);   // let the receiver finish
        end
    endtask

    task expect_good(input [7:0]t, input [7:0]s, input [7:0]l, input [8*MAX_LEN-1:0]p, input integer count_before);
        begin
            if (good_count != count_before + 1) begin
                $display("FAIL packet seq %0d not received", s);
                errors = errors + 1;
            end else if (rx_type !== t || rx_seq !== s || rx_len !== l || rx_payload !== masked(p, l)) begin
                $display("FAIL packet seq %0d received with wrong contents", s);
                errors = errors + 1;
            end
        end
    endtask

    integer i, before_good, before_err;
    reg [7:0]t, s, l;
    reg [8*MAX_LEN-1:0]p;
    initial begin
        repeat (5) @(posedge clk);
        reset = 1'b0;

        // 1. Random packets, including a zero-length one and payloads containing 0xA5
        for (i = 0; i < 50; i = i + 1) begin
            t = $random; s = i; l = (i == 0) ? 8'd0 : ($random & 8'h0F) + 1;
            p = {$random, $random, $random, $random};
            if (i == 1) p = {16{8'hA5}};
            before_good = good_count;
            send_packet(t, s, l, p);
            expect_good(t, s, l, p, before_good);
        end
        $display("  step 1: 50 random packets checked");

        // 2. Flip one bit in the middle of the payload
        before_good = good_count; before_err = error_count;
        fork
            send_packet(8'h10, 8'd200, 8'd8, 64'h0123456789ABCDEF);
            begin
                #(BIT_NS * 75);           // byte 7 of the packet, inside the payload
                flip = 1'b1;
                #(BIT_NS);
                flip = 1'b0;
            end
        join
        if (good_count != before_good || error_count != before_err + 1) begin
            $display("FAIL corrupted packet not rejected (good +%0d, errors +%0d)",
                     good_count - before_good, error_count - before_err);
            errors = errors + 1;
        end else
            $display("  step 2: corrupted packet rejected with pkt_error");

        // 3. Next packet must be fine
        before_good = good_count;
        send_packet(8'h11, 8'd201, 8'd4, 32'hDEADBEEF);
        expect_good(8'h11, 8'd201, 8'd4, 32'hDEADBEEF, before_good);
        $display("  step 3: receiver recovered after the error");

        // 4. Cut the cable halfway through a packet
        before_good = good_count; before_err = error_count;
        fork
            send_packet(8'h12, 8'd202, 8'd16, {4{32'hCAFEF00D}});
            begin
                #(BIT_NS * 85);
                cut = 1'b1;
            end
        join
        repeat (60 * CLK_HZ / BAUD) @(posedge clk);   // longer than the gap timeout
        cut = 1'b0;
        if (good_count != before_good || error_count < before_err + 1) begin
            $display("FAIL cut-off packet not reported");
            errors = errors + 1;
        end else
            $display("  step 4: cut-off packet timed out with pkt_error");

        before_good = good_count;
        send_packet(8'h13, 8'd203, 8'd2, 16'hBEEF);
        expect_good(8'h13, 8'd203, 8'd2, 16'hBEEF, before_good);

        if (errors == 0) $display("PASS tb_packet");
        else             $display("FAIL tb_packet: %0d errors", errors);
        $finish;
    end
endmodule
