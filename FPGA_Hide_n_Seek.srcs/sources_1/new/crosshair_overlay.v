`timescale 1ns / 1ps

// Crosshair overlay for the 96x64 3D view
//
// Draws a "+" with an empty centre (so the target stays visible) around
// column 48, which is the centre ray of Raycast_3D_Engine and the column that
// sprite_billboard's crosshair_hit test uses. The row is the vertical middle of
// the view (the wall slices are centred between rows 31 and 32).
//
//            |            ARM pixels, starting GAP pixels away from the centre
//            |
//            .
//     --  .  +  .  --
//            .
//            |
//            |
//
// The colour switches to ON_TARGET_COLOUR while crosshair_hit says an enemy
// sprite is under the crosshair, so the player can see when a shot would land.
//
// Purely combinational: feed it the same pixel_index as the OLED driver.
module crosshair_overlay
#(
    parameter integer CENTRE_X = 48,
    parameter integer CENTRE_Y = 32,
    parameter integer GAP      = 2,    // empty pixels between the centre and each arm
    parameter integer ARM      = 3,    // length of each arm in pixels
    parameter [15:0]  COLOUR           = 16'hFFFF,   // white
    parameter [15:0]  ON_TARGET_COLOUR = 16'hF800    // red
)
(
    input  [12:0] pixel_index,
    input         on_target,       // crosshair_hit from the renderer
    output        draw,            // 1: this pixel is part of the crosshair
    output [15:0] colour
);
    // pixel_index -> (x, y), same constant-divide trick as the raycaster
    wire [5:0] pixel_y = pixel_index / 13'd96;
    wire [12:0] pixel_y_times_96 = ({7'd0, pixel_y} << 6) +
                                   ({7'd0, pixel_y} << 5);
    wire [6:0] pixel_x = pixel_index - pixel_y_times_96;

    localparam [6:0] CX = CENTRE_X;
    localparam [6:0] CY = CENTRE_Y;
    localparam [6:0] G  = GAP;
    localparam [6:0] GA = GAP + ARM;     // first pixel past the arm

    // Distance from the centre on each axis
    wire [6:0] py = {1'b0, pixel_y};
    wire [6:0] dx = (pixel_x >= CX) ? (pixel_x - CX) : (CX - pixel_x);
    wire [6:0] dy = (py      >= CY) ? (py      - CY) : (CY - py);

    wire in_horizontal_arm = (py == CY)      && (dx >= G) && (dx < GA);
    wire in_vertical_arm   = (pixel_x == CX) && (dy >= G) && (dy < GA);

    assign draw   = in_horizontal_arm || in_vertical_arm;
    assign colour = on_target ? ON_TARGET_COLOUR : COLOUR;
endmodule