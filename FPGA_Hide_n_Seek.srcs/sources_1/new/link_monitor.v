`timescale 1ns / 1ps
// Tracks whether the other board is connected.
//
// heartbeat pulses every HEARTBEAT_MS. Send a packet on each pulse (even an empty
// one) so the other board knows you are still there.
//
// link_up goes high as soon as a good packet arrives, and drops if no good packet
// has arrived for TIMEOUT_MS, for example when the cable is unplugged or the other
// board is reset. It comes back up by itself when packets start arriving again.

module link_monitor
#(
    parameter integer CLK_HZ       = 100_000_000,
    parameter integer HEARTBEAT_MS = 50,
    parameter integer TIMEOUT_MS   = 500
)
(
    input clk,
    input reset,
    input rx_pkt_valid,

    output reg link_up = 1'b0,
    output reg heartbeat = 1'b0
);
    localparam integer CLKS_PER_MS     = CLK_HZ / 1000;
    localparam integer HEARTBEAT_CLKS  = HEARTBEAT_MS * CLKS_PER_MS;
    localparam integer TIMEOUT_CLKS    = TIMEOUT_MS * CLKS_PER_MS;

    reg [31:0]heartbeat_count = 32'd0;
    reg [31:0]silence_count = 32'd0;

    always @(posedge clk) begin
        heartbeat <= 1'b0;

        if (reset) begin
            link_up         <= 1'b0;
            heartbeat_count <= 32'd0;
            silence_count   <= 32'd0;
        end else begin
            if (heartbeat_count == HEARTBEAT_CLKS - 1) begin
                heartbeat_count <= 32'd0;
                heartbeat       <= 1'b1;
            end else begin
                heartbeat_count <= heartbeat_count + 32'd1;
            end

            if (rx_pkt_valid) begin
                silence_count <= 32'd0;
                link_up       <= 1'b1;
            end else if (silence_count == TIMEOUT_CLKS - 1) begin
                link_up <= 1'b0;   // stays here until a packet arrives
            end else begin
                silence_count <= silence_count + 32'd1;
            end
        end
    end
endmodule
