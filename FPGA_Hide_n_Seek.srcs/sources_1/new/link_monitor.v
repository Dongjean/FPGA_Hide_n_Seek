`timescale 1ns / 1ps

//Link monitor
//Makes the heartbeat pulse and reports whether the other board is connected.
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

    //Timing and counters
    localparam integer CLKS_PER_MS     = CLK_HZ / 1000;
    localparam integer HEARTBEAT_CLKS  = HEARTBEAT_MS * CLKS_PER_MS;
    localparam integer TIMEOUT_CLKS    = TIMEOUT_MS * CLKS_PER_MS;

    reg [31:0]heartbeat_count = 32'd0;
    reg [31:0]silence_count = 32'd0;

    //Heartbeat and timeout
    //link_up rises on any good packet and drops after TIMEOUT_MS of silence.
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
                link_up <= 1'b0;
            end else begin
                silence_count <= silence_count + 32'd1;
            end
        end
    end
endmodule
