`timescale 1ns / 1ps
// PS/2 host port: receives bytes from a mouse or keyboard, and can send command
// bytes to it. On the Basys3 the USB port's microcontroller presents the USB mouse
// or keyboard as a PS/2 device on PS2Clk / PS2Data.
//
// Both lines are open-collector: each side only ever pulls a line low or lets it
// float, and a pull-up resistor makes it high. So we drive 0 or Z, never 1.
//
// Device to host (11 bits): start 0, 8 data bits LSB first, odd parity, stop 1.
//   The device makes the clock (10 to 16.7 kHz); data is valid on the falling edge.
//
// Host to device:
//   1. hold the clock low for 150 us (asks the device to listen)
//   2. pull data low (start bit) and release the clock
//   3. the device makes 11 clock pulses; we change data after each falling edge:
//      edges 1-8 data bits, 9 parity, 10 release data (stop bit)
//   4. on edge 11 the device pulls data low to acknowledge

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
    input tx_start,               // pulse to send tx_data
    output tx_busy,
    output reg tx_done = 1'b0,    // pulse: device acknowledged the byte
    output reg tx_error = 1'b0,   // pulse: no response or no acknowledge

    output reg [7:0]rx_data = 8'd0,
    output reg rx_valid = 1'b0,   // pulse: a byte arrived with correct parity
    output reg rx_error = 1'b0    // pulse: bad start/parity/stop bit
);
    localparam integer INHIBIT_CLKS = CLK_HZ / 20_000 * 3;   // 150 us
    localparam integer BIT_GAP_CLKS = CLK_HZ / 500;          // 2 ms without a clock edge
    localparam integer TX_WAIT_CLKS = CLK_HZ / 50;           // 20 ms for the device to respond

    // Open-collector outputs
    reg clk_low = 1'b0;
    reg data_low = 1'b0;
    assign ps2_clk  = clk_low  ? 1'b0 : 1'bz;
    assign ps2_data = data_low ? 1'b0 : 1'bz;

    // Synchronise both lines, then filter the clock: it only changes after 4 equal
    // samples in a row, so a noise spike cannot look like a clock edge.
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

    localparam [2:0]T_IDLE    = 3'd0;
    localparam [2:0]T_INHIBIT = 3'd1;   // holding the clock low
    localparam [2:0]T_START   = 3'd2;   // data low, clock released, waiting for the device
    localparam [2:0]T_BITS    = 3'd3;   // device is clocking our bits in
    localparam [2:0]T_RELEASE = 3'd4;   // waiting for the device to release both lines

    reg [2:0]tx_state = T_IDLE;
    reg [8:0]tx_shift;                  // {parity, data}
    reg [3:0]tx_edges;
    reg [31:0]tx_timer = 32'd0;

    reg [3:0]rx_bits = 4'd0;            // bits received so far in this frame
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
            // ---------------- Transmit (host to device) ----------------
            case (tx_state)
                T_IDLE: begin
                    if (tx_start) begin
                        tx_shift <= {~^tx_data, tx_data};   // odd parity
                        tx_edges <= 4'd0;
                        tx_timer <= 32'd0;
                        clk_low  <= 1'b1;
                        rx_bits  <= 4'd0;                   // abandon any partial byte
                        tx_state <= T_INHIBIT;
                    end
                end

                T_INHIBIT: begin
                    if (tx_timer == INHIBIT_CLKS - 1) begin
                        tx_timer <= 32'd0;
                        data_low <= 1'b1;                   // start bit
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
                            data_low <= ~tx_shift[0];       // edges 1-9: data bits then parity
                            tx_shift <= {1'b1, tx_shift[8:1]};
                        end else if (tx_edges == 4'd9) begin
                            data_low <= 1'b0;               // edge 10: stop bit (released)
                        end else begin
                            // edge 11: the device should be holding data low
                            if (!data_in)
                                tx_done <= 1'b1;
                            else
                                tx_error <= 1'b1;
                            tx_state <= T_RELEASE;
                        end
                    end else if (tx_timer == TX_WAIT_CLKS - 1) begin
                        tx_error <= 1'b1;                   // device never responded
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

            // ---------------- Receive (device to host) ----------------
            if (tx_state == T_IDLE) begin
                if (falling_edge) begin
                    rx_gap <= 32'd0;
                    if (rx_bits == 4'd0 && data_in) begin
                        // not a start bit: ignore
                    end else begin
                        rx_shift <= {data_in, rx_shift[10:1]};
                        if (rx_bits == 4'd10) begin
                            rx_bits <= 4'd0;
                            // Before this edge rx_shift[10:1] = {parity, data[7:0], start},
                            // and data_in is the stop bit
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
                    // A frame that stops halfway is thrown away
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
