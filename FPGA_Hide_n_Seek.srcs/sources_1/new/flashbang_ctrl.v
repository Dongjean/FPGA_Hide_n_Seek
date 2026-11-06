`timescale 1ns / 1ps

// When the Hider uses a Flashbang, the hider's dot on the seeker's minimap
// first blinks for BLINK_MS, then disappears for HIDE_MS, then comes back

module flashbang_ctrl
#(
    parameter integer CLK_HZ        = 6_250_000,
    parameter integer BLINK_MS      = 1000,  // blinking part
    parameter integer HIDE_MS       = 5000, // fully hidden part
    parameter integer BLINK_HALF_MS = 125 // on/off time while blinking
)
(
    input      clk,
    input      reset,
    input      start, //new game; restart everything 
    input      game_paused,    
    input      flash, // Hider used Flash
    output     opp_visible, // 1 = draw the Hider's dot
    output     flash_active // 1 = flash in effect
);
    // Counting ticks 
    localparam integer CLK_MS     = CLK_HZ / 1000;
    localparam integer HIDE_CLKS  = HIDE_MS * CLK_MS; 
    localparam integer TOTAL_CLKS = (BLINK_MS + HIDE_MS) * CLK_MS;   
    localparam integer HALF_CLKS  = BLINK_HALF_MS * CLK_MS; 

    reg [25:0] left; // start clk ticks counting down
    reg [19:0] half_cnt;  
    reg        blink_on;   

    wire blinking = (left > HIDE_CLKS);          //more than 5s left 
    assign flash_active = (left != 26'd0); //1 = effect running; 0 = finished 
    assign opp_visible  = !flash_active || (blinking && blink_on); //first second + blink == shown on map

    always @(posedge clk) begin
        if (reset || start) begin
            left     <= 26'd0;
            half_cnt <= 20'd0;
            blink_on <= 1'b0;
        end 
        //just thrown
        else if (flash) begin
        // start the timeline; 6s 
            left     <= TOTAL_CLKS; 
            half_cnt <= 20'd0;
            blink_on <= 1'b0; 
        end 
        //effect inprogress
        else if (flash_active && !game_paused) begin
            left <= left - 26'd1;
            
            //blinking logic (toggle at 4Hz)
            if (half_cnt == HALF_CLKS - 1) begin
            //reach the end 
                half_cnt <= 20'd0;
                blink_on <= ~blink_on;           
            end else begin
            // +1 
                half_cnt <= half_cnt + 20'd1;
            end
        end
    end
endmodule