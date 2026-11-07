`timescale 1ns / 1ps

//PS/2 host
//Receives bytes from the USB mouse/keyboard and sends it command bytes (lines are open-collector).
module ps2_host
#(
    parameter integer CLK_HZ = 6_250_000
)
(
    input clk,
    input reset,
    inout ps2_clk,
    inout ps2_data,

    input [7:0]tx_data,
    input tx_start,
    output tx_busy,
    output reg tx_done = 1'b0,
    output reg tx_error = 1'b0,

    output reg [7:0]rx_data = 8'd0,
    output reg rx_valid = 1'b0,
    output reg rx_error = 1'b0
);

    //Timing
    localparam integer INHIBIT_CLKS = CLK_HZ / 20_000 * 3;
    localparam integer BIT_GAP_CLKS = CLK_HZ / 500;
    localparam integer TX_WAIT_CLKS = CLK_HZ / 50;

    //Open-collector outputs
    reg clk_low = 1'b0;
    reg data_low = 1'b0;
    assign ps2_clk  = clk_low  ? 1'b0 : 1'bz;
    assign ps2_data = data_low ? 1'b0 : 1'bz;

    //Input synchroniser and clock filter
    (* ASYNC_REG = "TRUE" *) reg [1:0]clk_sync = 2'b11;
    (* ASYNC_REG = "TRUE" *) reg [1:0]data_sync = 2'b11;
    reg [3:0]clk_history = 4'hF;
    reg clk_filtered = 1'b1;
    reg clk_filtered_prev = 1'b1;
    always @(posedge clk) begin
        clk_sync  <= {clk_sync[0], ps2_clk};
        data_sync <= {data_sync[0], ps2_data};
        clk_history <= {clk_history[2:0], clk_sync[1]};
        if (clk_history == 4'hF)
            clk_filtered <= 1'b1;
        else if (clk_history == 4'h0)
            clk_filtered <= 1'b0;
        clk_filtered_prev <= clk_filtered;
    end
    wire falling_edge = clk_filtered_prev && !clk_filtered;
    wire data_in = data_sync[1];

    //Transmit states and registers
    localparam [2:0]T_IDLE    = 3'd0;
    localparam [2:0]T_INHIBIT = 3'd1;
    localparam [2:0]T_START   = 3'd2;
    localparam [2:0]T_BITS    = 3'd3;
    localparam [2:0]T_RELEASE = 3'd4;

    reg [2:0]tx_state = T_IDLE;
    reg [8:0]tx_shift;
    reg [3:0]tx_edges;
    reg [31:0]tx_timer = 32'd0;

    //Receive registers
    reg [3:0]rx_bits = 4'd0;
    reg [10:0]rx_shift;
    reg [31:0]rx_gap = 32'd0;

    assign tx_busy = (tx_state != T_IDLE);

    always @(posedge clk) begin
        tx_done  <= 1'b0;
        tx_error <= 1'b0;
        rx_valid <= 1'b0;
        rx_error <= 1'b0;

        if (reset) begin
            tx_state <= T_IDLE;
            clk_low  <= 1'b0;
            data_low <= 1'b0;
            rx_bits  <= 4'd0;
        end else begin

            //Transmit FSM (host to device)
            //IDLE -> INHIBIT (clock low 150 us) -> START -> BITS (11 device clocks) -> RELEASE.
            case (tx_state)
                T_IDLE: begin
                    if (tx_start) begin
                        tx_shift <= {~^tx_data, tx_data};
                        tx_edges <= 4'd0;
                        tx_timer <= 32'd0;
                        clk_low  <= 1'b1;
                        rx_bits  <= 4'd0;
                        tx_state <= T_INHIBIT;
                    end
                end

                T_INHIBIT: begin
                    if (tx_timer == INHIBIT_CLKS - 1) begin
                        tx_timer <= 32'd0;
                        data_low <= 1'b1;
                        clk_low  <= 1'b0;
                        tx_state <= T_START;
                    end else begin
                        tx_timer <= tx_timer + 32'd1;
                    end
                end

                T_START, T_BITS: begin
                    if (falling_edge) begin
                        tx_state <= T_BITS;
                        tx_timer <= 32'd0;
                        tx_edges <= tx_edges + 4'd1;
                        if (tx_edges < 4'd9) begin
                            data_low <= ~tx_shift[0];
                            tx_shift <= {1'b1, tx_shift[8:1]};
                        end else if (tx_edges == 4'd9) begin
                            data_low <= 1'b0;
                        end else begin
                            if (!data_in)
                                tx_done <= 1'b1;
                            else
                                tx_error <= 1'b1;
                            tx_state <= T_RELEASE;
                        end
                    end else if (tx_timer == TX_WAIT_CLKS - 1) begin
                        tx_error <= 1'b1;
                        data_low <= 1'b0;
                        tx_state <= T_RELEASE;
                    end else begin
                        tx_timer <= tx_timer + 32'd1;
                    end
                end

                T_RELEASE: begin
                    if (clk_filtered && data_in) begin
                        tx_state <= T_IDLE;
                        rx_bits  <= 4'd0;
                    end
                end

                default: tx_state <= T_IDLE;
            endcase

            //Receive (device to host)
            //11 bits per byte: start, 8 data, odd parity, stop.
            if (tx_state == T_IDLE) begin
                if (falling_edge) begin
                    rx_gap <= 32'd0;
                    if (rx_bits == 4'd0 && data_in) begin
                    end else begin
                        rx_shift <= {data_in, rx_shift[10:1]};
                        if (rx_bits == 4'd10) begin
                            rx_bits <= 4'd0;
                            if (data_in && (^{rx_shift[10:2]} == 1'b1)) begin
                                rx_data  <= rx_shift[9:2];
                                rx_valid <= 1'b1;
                            end else begin
                                rx_error <= 1'b1;
                            end
                        end else begin
                            rx_bits <= rx_bits + 4'd1;
                        end
                    end
                end else if (rx_bits != 4'd0) begin
                    if (rx_gap == BIT_GAP_CLKS - 1) begin
                        rx_bits  <= 4'd0;
                        rx_gap   <= 32'd0;
                        rx_error <= 1'b1;
                    end else begin
                        rx_gap <= rx_gap + 32'd1;
                    end
                end
            end
        end
    end
endmodule
