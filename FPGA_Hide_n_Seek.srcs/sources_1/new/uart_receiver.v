`timescale 1ns / 1ps
// UART receiver, 8N1.
// rx comes from the other Basys3 board, which runs on its own oscillator, so it is
// passed through a 2 flip-flop synchroniser before use to avoid metastability.
// Each bit is sampled in the middle of its bit period.

module uart_receiver
#(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
)
(
    input clk,
    input reset,
    input rx,

    output reg [7:0]data_out = 8'd0,
    output reg valid = 1'b0,         // one clock pulse when a byte has arrived
    output reg frame_error = 1'b0    // one clock pulse when the stop bit was missing
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;

    localparam [1:0]S_IDLE  = 2'd0;
    localparam [1:0]S_START = 2'd1;
    localparam [1:0]S_DATA  = 2'd2;
    localparam [1:0]S_STOP  = 2'd3;

    // 2 flip-flop synchroniser
    (* ASYNC_REG = "TRUE" *) reg rx_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rx_sync = 1'b1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    reg [1:0]state = S_IDLE;
    reg [15:0]clk_count = 16'd0;
    reg [2:0]bit_index = 3'd0;
    reg [7:0]shift = 8'd0;

    always @(posedge clk) begin
        valid       <= 1'b0;
        frame_error <= 1'b0;

        if (reset) begin
            state     <= S_IDLE;
            clk_count <= 16'd0;
            bit_index <= 3'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    if (!rx_sync)
                        state <= S_START;   // falling edge: possible start bit
                end

                // Wait half a bit, then check the line is still low.
                // A short glitch returns to idle instead of starting a byte.
                S_START: begin
                    if (clk_count == CLKS_PER_BIT / 2 - 1) begin
                        clk_count <= 16'd0;
                        state <= rx_sync ? S_IDLE : S_DATA;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                // We are now in the middle of a bit, so wait one full bit each time.
                S_DATA: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 16'd0;
                        shift <= {rx_sync, shift[7:1]};   // LSB arrives first
                        if (bit_index == 3'd7)
                            state <= S_STOP;
                        bit_index <= bit_index + 3'd1;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                // Sample the middle of the stop bit, then return to idle straight away
                // so the next start bit is not missed.
                S_STOP: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 16'd0;
                        state <= S_IDLE;
                        if (rx_sync) begin
                            data_out <= shift;
                            valid    <= 1'b1;
                        end else begin
                            frame_error <= 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end
            endcase
        end
    end
endmodule
