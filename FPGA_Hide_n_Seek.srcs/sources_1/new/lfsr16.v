`timescale 1ns / 1ps


//random number generator (to ensure every match's map is different)

//////////////////////////////////////////////////////////////////////////////////
// lfsr16 - 16-bit maximal-length Galois LFSR
//
// Polynomial: x^16 + x^14 + x^13 + x^11 + 1  ->  right-shift Galois mask 16'hB400
// Period    : 65535 (every non-zero 16-bit value appears exactly once)
//
// Priority  : reset > load > step.  All synchronous to clk (oled_clk, 6.25 MHz).
// Zero lock : the all-zero state is the only state a Galois LFSR cannot leave,
//             so a zero seed (and reset) are replaced by ZERO_SUB.
//////////////////////////////////////////////////////////////////////////////////
module lfsr16
#(
    parameter [15:0] TAPS     = 16'hB400,  // feedback mask, taps 16,14,13,11
    parameter [15:0] ZERO_SUB = 16'hACE1   // used when seed == 0 and after reset
)
(
    input             clk,
    input             reset,   // synchronous, active-high
    input             load,    // 1-cycle: state <= seed (or ZERO_SUB if seed == 0)
    input      [15:0] seed,
    input             step,    // 1-cycle: advance one LFSR state
    output     [15:0] out      // current state (registered, never 0)
);

    reg [15:0] state;

    // Next state of a right-shift Galois LFSR:
    // shift right by 1; if the bit that fell off (state[0]) was 1, XOR the taps in.
    // {16{state[0]}} copies the dropped bit to all 16 positions, so the AND
    // selects either TAPS or 0 without a mux.
    wire [15:0] next_state = (state >> 1) ^ ({16{state[0]}} & TAPS);

    always @(posedge clk) begin
        if (reset)
            state <= ZERO_SUB;
        else if (load)
            state <= (seed == 16'd0) ? ZERO_SUB : seed;   // never enter the 0 lock-up state
        else if (step)
            state <= next_state;
        // else: hold
    end

    assign out = state;

endmodule
