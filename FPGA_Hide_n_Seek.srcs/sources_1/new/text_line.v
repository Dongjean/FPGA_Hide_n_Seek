`timescale 1ns / 1ps

// Draws one line of text (N characters) at (x0,y0), magnified by SCALE.
// Each character cell is 7*SCALE wide (1 gap + 5 glyph columns + 1 gap) and 7*SCALE tall.
module text_line
#(
    parameter integer N     = 4,
    parameter integer SCALE = 1
)
(
    input  [6:0]     px,          // Current pixel x
    input  [5:0]     py,          // Current pxiel y
    input  [6:0]     x0,          // Top left x
    input  [5:0]     y0,          // Top right y
    input  [8*N-1:0] str,         // String to display
    input            highlighted, // Whether or not the text is currently highlighted
    output reg [1:0] on           // Output variable (1 if the (px,py) is inside the text, 0 if not, 2 if (px,py) is in the bg)
);
    `include "font.vh"

    // The character cell
    localparam integer CELL_W = 7 * SCALE;

    integer dx, dy, idx, col, row;
    reg [7:0]  ch;
    reg [34:0] bits;

    always @(*) begin
        on = 1'b0;
        dx = px - x0;
        dy = py - y0;
        // px is left of x0                                (px >= x0)        AND
        // py is below y0                                  (py >= y0)        AND
        // px is to the right of the defined character row (dx < N * CELL_W) AND
        // py is to the left of the defined character row  (dy < 7 * SCALE)
        // All of the above checks if (px, py) is inside the defined character row
        if ((px >= x0) && (py >= y0) && (dx < N * CELL_W) && (dy < 7 * SCALE)) begin
            // (dx,dy) is the coordinates inside the character row
            idx  = dx / CELL_W;           // The current character index
            ch   = str[8*(N-1-idx) +: 8]; // Get the current character
            bits = glyph_bits(ch);        // Bitmap of the current character (5 glyph pixels wide, 7 glyph pixels tall) 
            
            // Column and Row of the current character bitmap
            // This is scaled based on SCALE
            col  = (dx % CELL_W) / SCALE;
            row  = dy / SCALE;
            if (col > 0 && col < 6 && bits[34 - (row * 5) + 1 - col]) // If col == 5, then dont display
                on = 1'd1; // Return the current pixel
            else if (highlighted) // Here, (px,py) is in the bg of the text, highlight it
                on = 2'd2;
            else
                on = 2'd0;
        end
    end
endmodule
