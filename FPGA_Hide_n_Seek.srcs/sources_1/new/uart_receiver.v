`timescale 1ns / 1ps

//UART receiver
//Receives one 8N1 byte, sampling each bit in the middle of its bit time.
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
    output reg valid = 1'b0,
    output reg frame_error = 1'b0
);

    //Timing and states
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;

    localparam [1:0]S_IDLE  = 2'd0;
    localparam [1:0]S_START = 2'd1;
    localparam [1:0]S_DATA  = 2'd2;
    localparam [1:0]S_STOP  = 2'd3;

    //Input synchroniser
    //Two flip-flops, because rx comes from the other board's clock.
    (* ASYNC_REG = "TRUE" *) reg rx_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rx_sync = 1'b1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    //Registers
    reg [1:0]state = S_IDLE;
    reg [15:0]clk_count = 16'd0;
    reg [2:0]bit_index = 3'd0;
    reg [7:0]shift = 8'd0;

    //Receive FSM
    //IDLE -> START (check start bit) -> DATA (8 bits) -> STOP (valid or frame_error).
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
                        state <= S_START;
                end

                S_START: begin
                    if (clk_count == CLKS_PER_BIT / 2 - 1) begin
                        clk_count <= 16'd0;
                        state <= rx_sync ? S_IDLE : S_DATA;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                S_DATA: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 16'd0;
                        shift <= {rx_sync, shift[7:1]};
                        if (bit_index == 3'd7)
                            state <= S_STOP;
                        bit_index <= bit_index + 3'd1;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

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
