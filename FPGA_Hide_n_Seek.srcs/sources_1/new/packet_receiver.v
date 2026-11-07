`timescale 1ns / 1ps

//Packet receiver
//Rebuilds packets from UART bytes; only packets with a correct CRC are published.
module packet_receiver
#(
    parameter integer CLK_HZ  = 100_000_000,
    parameter integer BAUD    = 115_200,
    parameter integer MAX_LEN = 16
)
(
    input clk,
    input reset,
    input rx,

    output reg pkt_valid = 1'b0,
    output reg [7:0]pkt_type = 8'd0,
    output reg [7:0]pkt_seq = 8'd0,
    output reg [7:0]pkt_len = 8'd0,
    output reg [8*MAX_LEN-1:0]pkt_payload = 0,
    output reg pkt_error = 1'b0
);

    //Constants and states
    `include "crc8_checksum.vh"

    localparam [7:0]SYNC_BYTE = 8'hA5;

    localparam integer CLKS_PER_BIT  = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer GAP_TIMEOUT   = 40 * CLKS_PER_BIT;

    localparam [2:0]S_HUNT = 3'd0;
    localparam [2:0]S_TYPE = 3'd1;
    localparam [2:0]S_SEQ  = 3'd2;
    localparam [2:0]S_LEN  = 3'd3;
    localparam [2:0]S_DATA = 3'd4;
    localparam [2:0]S_CRC  = 3'd5;

    //UART
    wire [7:0]rx_byte;
    wire rx_valid;
    wire rx_frame_error;

    uart_receiver #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uart (
        .clk         (clk),
        .reset       (reset),
        .rx          (rx),
        .data_out    (rx_byte),
        .valid       (rx_valid),
        .frame_error (rx_frame_error)
    );

    //Packet registers
    reg [2:0]state = S_HUNT;
    reg [7:0]type_r;
    reg [7:0]seq_r;
    reg [7:0]len_r;
    reg [8*MAX_LEN-1:0]payload_r;
    reg [7:0]data_count;
    reg [7:0]crc;
    reg [23:0]gap_count = 24'd0;

    //Receive FSM
    //HUNT (sync byte) -> TYPE -> SEQ -> LEN -> DATA -> CRC. A cut-off packet is dropped.
    always @(posedge clk) begin
        pkt_valid <= 1'b0;
        pkt_error <= 1'b0;

        if (reset) begin
            state     <= S_HUNT;
            gap_count <= 24'd0;
        end else if (rx_frame_error) begin
            if (state != S_HUNT)
                pkt_error <= 1'b1;
            state <= S_HUNT;
        end else if (rx_valid) begin
            gap_count <= 24'd0;
            case (state)
                S_HUNT: begin
                    if (rx_byte == SYNC_BYTE) begin
                        crc       <= 8'd0;
                        payload_r <= 0;
                        state     <= S_TYPE;
                    end
                end

                S_TYPE: begin
                    type_r <= rx_byte;
                    crc    <= crc8_update(crc, rx_byte);
                    state  <= S_SEQ;
                end

                S_SEQ: begin
                    seq_r <= rx_byte;
                    crc   <= crc8_update(crc, rx_byte);
                    state <= S_LEN;
                end

                S_LEN: begin
                    len_r      <= rx_byte;
                    crc        <= crc8_update(crc, rx_byte);
                    data_count <= 8'd0;
                    if (rx_byte > MAX_LEN) begin
                        pkt_error <= 1'b1;
                        state     <= S_HUNT;
                    end else if (rx_byte == 8'd0) begin
                        state <= S_CRC;
                    end else begin
                        state <= S_DATA;
                    end
                end

                S_DATA: begin
                    payload_r[8 * data_count +: 8] <= rx_byte;
                    crc        <= crc8_update(crc, rx_byte);
                    data_count <= data_count + 8'd1;
                    if (data_count == len_r - 8'd1)
                        state <= S_CRC;
                end

                S_CRC: begin
                    state <= S_HUNT;
                    if (rx_byte == crc) begin
                        pkt_type    <= type_r;
                        pkt_seq     <= seq_r;
                        pkt_len     <= len_r;
                        pkt_payload <= payload_r;
                        pkt_valid   <= 1'b1;
                    end else begin
                        pkt_error <= 1'b1;
                    end
                end
            endcase
        end else if (state != S_HUNT) begin
            if (gap_count == GAP_TIMEOUT) begin
                gap_count <= 24'd0;
                pkt_error <= 1'b1;
                state     <= S_HUNT;
            end else begin
                gap_count <= gap_count + 24'd1;
            end
        end
    end
endmodule
