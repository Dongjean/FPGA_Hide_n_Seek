`timescale 1ns / 1ps
// Hardware test for the board-to-board link. Load the SAME bitstream on both boards
// and connect them with 3 wires (see link_test.xdc):
//
//   Board A link_tx  ->  Board B link_rx
//   Board A link_rx  <-  Board B link_tx
//   Board A GND      ---  Board B GND
//
// Each board sends a packet every 50 ms carrying its switches and buttons.
//
//   led[13:0]   the OTHER board's switches 13 to 0 (flip a switch on A, watch B)
//   led[14]     toggles on every good packet received
//   led[15]     link up (goes off about 0.5 s after the cable is unplugged)
//   7-segment   left 2 digits: good packets received (hex, wraps at FF)
//               right 2 digits: rejected packets (hex)
//   btnD held   deliberately corrupts one bit in each outgoing packet; the other
//               board's error count should rise and its LEDs should NOT change
//   btnC        reset

module link_test_top
#(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
)
(
    input clk,
    input btnC,
    input btnU,
    input btnD,
    input btnL,
    input btnR,
    input [15:0]sw,
    input link_rx,

    output link_tx,
    output [15:0]led,
    output [6:0]seg,
    output dp,
    output [3:0]an
);
    localparam integer MAX_LEN = 16;
    localparam [7:0]TYPE_TEST = 8'h01;
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;

    wire reset = btnC;

    // ---------------- Link status and heartbeat ----------------
    wire rx_valid;
    wire rx_error;
    wire link_up;
    wire heartbeat;

    link_monitor #(.CLK_HZ(CLK_HZ), .HEARTBEAT_MS(50), .TIMEOUT_MS(500)) status (
        .clk          (clk),
        .reset        (reset),
        .rx_pkt_valid (rx_valid),
        .link_up      (link_up),
        .heartbeat    (heartbeat)
    );

    // ---------------- Transmit: one packet per heartbeat ----------------
    reg [7:0]tx_seq = 8'd0;
    wire tx_busy;
    wire tx_line;
    wire [8*MAX_LEN-1:0]tx_payload = {
        96'd0,                                     // bytes 4 to 15 unused
        tx_seq,                                    // byte 3
        {3'b000, btnC, btnU, btnD, btnL, btnR},    // byte 2
        sw[15:8],                                  // byte 1
        sw[7:0]                                    // byte 0
    };
    wire send = heartbeat && !tx_busy;

    always @(posedge clk) begin
        if (reset)
            tx_seq <= 8'd0;
        else if (send)
            tx_seq <= tx_seq + 8'd1;
    end

    packet_sender #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) sender (
        .clk         (clk),
        .reset       (reset),
        .send        (send),
        .pkt_type    (TYPE_TEST),
        .pkt_seq     (tx_seq),
        .pkt_len     (8'd4),
        .pkt_payload (tx_payload),
        .busy        (tx_busy),
        .tx          (tx_line)
    );

    // Error injection: while btnD is held, invert the line for one bit period in
    // the middle of each packet (bit 55 = inside payload byte 1).
    reg [31:0]since_send = 32'hFFFF_FFFF;
    always @(posedge clk) begin
        if (send)
            since_send <= 32'd0;
        else if (since_send != 32'hFFFF_FFFF)
            since_send <= since_send + 32'd1;
    end
    wire inject = btnD && (since_send >= 55 * CLKS_PER_BIT) && (since_send < 56 * CLKS_PER_BIT);
    assign link_tx = tx_line ^ inject;

    // ---------------- Receive ----------------
    wire [7:0]rx_type;
    wire [7:0]rx_seq;
    wire [7:0]rx_len;
    wire [8*MAX_LEN-1:0]rx_payload;

    packet_receiver #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) receiver (
        .clk         (clk),
        .reset       (reset),
        .rx          (link_rx),
        .pkt_valid   (rx_valid),
        .pkt_type    (rx_type),
        .pkt_seq     (rx_seq),
        .pkt_len     (rx_len),
        .pkt_payload (rx_payload),
        .pkt_error   (rx_error)
    );

    reg [15:0]peer_switches = 16'd0;
    reg [7:0]good_count = 8'd0;
    reg [7:0]error_count = 8'd0;
    reg rx_toggle = 1'b0;

    always @(posedge clk) begin
        if (reset) begin
            peer_switches <= 16'd0;
            good_count    <= 8'd0;
            error_count   <= 8'd0;
        end else begin
            if (rx_valid && rx_type == TYPE_TEST) begin
                peer_switches <= rx_payload[15:0];
                good_count    <= good_count + 8'd1;
                rx_toggle     <= ~rx_toggle;
            end
            if (rx_error)
                error_count <= error_count + 8'd1;
        end
    end

    assign led = {link_up, rx_toggle, peer_switches[13:0]};

    seven_segment_display #(.CLK_HZ(CLK_HZ)) display (
        .clk   (clk),
        .value ({good_count, error_count}),
        .seg   (seg),
        .dp    (dp),
        .an    (an)
    );
endmodule
