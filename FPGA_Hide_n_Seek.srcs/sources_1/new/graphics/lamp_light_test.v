`timescale 1ns / 1ps
// Is a world position within 1.5 cells of a ceiling lamp
// The six squares are done in DSP blocks (lamp_square) to save LUTs
module lamp_light_test (
    input  [99:0]        light_bits,   // bit [99 - y*10 - x]
    input  signed [15:0] x,            // Q8.8
    input  signed [15:0] y,
    output               lit,
    output               lamp_here     // lamp in this position's cell
);

    // Cells off the 10x10 map have no lamp
    function lamp_at (input [99:0] bits, input signed [8:0] cx, input signed [8:0] cy);
        reg [3:0] ux;
        reg [3:0] uy;
        reg [6:0] row_times_10;
        begin
            ux = cx[3:0];
            uy = cy[3:0];
            row_times_10 = ({3'd0, uy} << 3) + ({3'd0, uy} << 1);
            if ((cx < 9'sd0) || (cx > 9'sd9) || (cy < 9'sd0) || (cy > 9'sd9))
                lamp_at = 1'b0;
            else
                lamp_at = bits[7'd99 - row_times_10 - {3'd0, ux}];
        end
    endfunction

    wire signed [8:0] cell_x = x[15:8];
    wire signed [8:0] cell_y = y[15:8];
    wire [7:0] frac_x = x[7:0];
    wire [7:0] frac_y = y[7:0];

    // Distance to the centre of the cell to the left / this one / to the right
    wire [8:0] dist_x_m1 = 9'd128 + {1'b0, frac_x};
    wire [8:0] dist_x_0  = (frac_x >= 8'd128) ? ({1'b0, frac_x} - 9'd128) : (9'd128 - {1'b0, frac_x});
    wire [8:0] dist_x_p1 = 9'd384 - {1'b0, frac_x};
    wire [8:0] dist_y_m1 = 9'd128 + {1'b0, frac_y};
    wire [8:0] dist_y_0  = (frac_y >= 8'd128) ? ({1'b0, frac_y} - 9'd128) : (9'd128 - {1'b0, frac_y});
    wire [8:0] dist_y_p1 = 9'd384 - {1'b0, frac_y};

    // Halved so the squares fit 16 bits
    wire [7:0]  half_x_m1 = dist_x_m1[8:1];
    wire [7:0]  half_x_0  = dist_x_0[8:1];
    wire [7:0]  half_x_p1 = dist_x_p1[8:1];
    wire [7:0]  half_y_m1 = dist_y_m1[8:1];
    wire [7:0]  half_y_0  = dist_y_0[8:1];
    wire [7:0]  half_y_p1 = dist_y_p1[8:1];
    wire [15:0] sq_x_m1, sq_x_0, sq_x_p1, sq_y_m1, sq_y_0, sq_y_p1;
    lamp_square sqxm (.a(half_x_m1), .sq(sq_x_m1));
    lamp_square sqx0 (.a(half_x_0),  .sq(sq_x_0));
    lamp_square sqxp (.a(half_x_p1), .sq(sq_x_p1));
    lamp_square sqym (.a(half_y_m1), .sq(sq_y_m1));
    lamp_square sqy0 (.a(half_y_0),  .sq(sq_y_0));
    lamp_square sqyp (.a(half_y_p1), .sq(sq_y_p1));

    localparam [16:0] RADIUS_SQUARED = 17'd36864;     // (384 / 2)^2

    // The 3x3 cells around the position
    wire [8:0] near;
    genvar i, j;
    generate
        for (j = 0; j < 3; j = j + 1) begin : row
            for (i = 0; i < 3; i = i + 1) begin : col
                wire [15:0] sq_x = (i == 0) ? sq_x_m1 : ((i == 1) ? sq_x_0 : sq_x_p1);
                wire [15:0] sq_y = (j == 0) ? sq_y_m1 : ((j == 1) ? sq_y_0 : sq_y_p1);
                wire [16:0] total = {1'b0, sq_x} + {1'b0, sq_y};
                wire here = lamp_at(light_bits, cell_x + (i - 1), cell_y + (j - 1));
                assign near[j * 3 + i] = here && (total < RADIUS_SQUARED);
            end
        end
    endgenerate

    assign lit       = |near;
    assign lamp_here = lamp_at(light_bits, cell_x, cell_y);

endmodule


// 8-bit square in a DSP block
(* use_dsp = "yes" *)
module lamp_square (
    input  [7:0]  a,
    output [15:0] sq
);
    assign sq = a * a;
endmodule
