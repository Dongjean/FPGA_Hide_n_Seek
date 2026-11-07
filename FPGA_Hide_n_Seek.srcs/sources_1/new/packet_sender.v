`timescale 1ns / 1ps

//Packet sender
//Sends | A5 | TYPE | SEQ | LEN | PAYLOAD | CRC-8 | through the UART.
module packet_sender
#(
    parameter integer CLK_HZ  = 100_000_000,
    parameter integer BAUD    = 115_200,
    parameter integer MAX_LEN = 16
)
(
    input clk,
    input reset,
    input send,
    input [7:0]pkt_type,
    input [7:0]pkt_seq,
    input [7:0]pkt_len,
    input [8*MAX_LEN-1:0]pkt_payload,

    output busy,
    output tx
);

    //Constants and states
    `include "crc8_checksum.vh"

    localparam [7:0]SYNC_BYTE = 8'hA5;

    localparam [1:0]S_IDLE    = 2'd0;
    localparam [1:0]S_LOAD    = 2'd1;
    localparam [1:0]S_WAIT_HI = 2'd2;
    localparam [1:0]S_WAIT_LO = 2'd3;

    //Packet registers
    reg [1:0]state = S_IDLE;
    reg [7:0]type_r;
    reg [7:0]seq_r;
    reg [7:0]len_r;
    reg [8*MAX_LEN-1:0]payload_r;
    reg [7:0]byte_index;
    reg [7:0]crc;

    //UART
    reg uart_start = 1'b0;
    reg [7:0]uart_data;
    wire uart_busy;

    uart_transmitter #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uart (
        .clk     (clk),
        .reset   (reset),
        .start   (uart_start),
        .data_in (uart_data),
        .tx      (tx),
        .busy    (uart_busy)
    );

    //Current byte
    //Chooses the sync, header, payload or CRC byte for the current position.
    assign busy = (state != S_IDLE);

    wire [7:0]payload_index = byte_index - 8'd4;
    wire is_crc_byte = (byte_index == len_r + 8'd4);
    reg [7:0]current_byte;
    always @(*) begin
        case (byte_index)
            8'd0:    current_byte = SYNC_BYTE;
            8'd1:    current_byte = type_r;
            8'd2:    current_byte = seq_r;
            8'd3:    current_byte = len_r;
            default: current_byte = is_crc_byte ? crc : payload_r[8 * payload_index +: 8];
        endcase
    end

    //Send FSM
    //IDLE latches the packet, then LOAD -> WAIT_HI -> WAIT_LO for every byte.
    always @(posedge clk) begin
        uart_start <= 1'b0;

        if (reset) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: begin
                    if (send) begin
                        type_r     <= pkt_type;
                        seq_r      <= pkt_seq;
                        len_r      <= (pkt_len > MAX_LEN) ? MAX_LEN[7:0] : pkt_len;
                        payload_r  <= pkt_payload;
                        byte_index <= 8'd0;
                        crc        <= 8'd0;
                        state      <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    uart_data  <= current_byte;
                    uart_start <= 1'b1;
                    if (byte_index != 8'd0 && !is_crc_byte)
                        crc <= crc8_update(crc, current_byte);
                    state <= S_WAIT_HI;
                end

                S_WAIT_HI: begin
                    if (uart_busy)
                        state <= S_WAIT_LO;
                end

                S_WAIT_LO: begin
                    if (!uart_busy) begin
                        if (is_crc_byte) begin
                            state <= S_IDLE;
                        end else begin
                            byte_index <= byte_index + 8'd1;
                            state <= S_LOAD;
                        end
                    end
                end
            endcase
        end
    end
endmodule
