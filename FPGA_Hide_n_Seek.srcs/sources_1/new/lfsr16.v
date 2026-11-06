`timescale 1ns / 1ps

//random number generator (for portal, capsule generation) 
//using polynomial x^16 + x^14 + x^13 + x^11 + 1; xor at bit 15,13,12,10 

//linear feedback shift register 16 bit 
module lfsr16
#(
    parameter [15:0] TAPS     = 16'hB400,  // feedback mask
    parameter [15:0] ZERO_SUB = 16'hACE1   // used when seed == 0 and after reset
)
(
    input             clk,
    input             reset,   
    input             load,    // state <= seed (or ZERO_SUB if seed == 0)
    input      [15:0] seed,    // takes in game_seed to start
    input             step,    // advance one LFSR state
    output     [15:0] out     
);

    reg [15:0] state;

    wire [15:0] next_state = (state >> 1) ^ ({16{state[0]}} & TAPS);
    //shift right by 1 bit and XOR with feedback mask 

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
