// Convert number of 1/16-square march steps into a projected half-height
// and a colour shade.  Lookup thresholds avoid a hardware divider.
function [5:0]wall_half_height (input [9:0]distance);
    begin
        if      (distance <= 10'd8)  wall_half_height = 6'd30;
        else if (distance <= 10'd9)  wall_half_height = 6'd29;
        else if (distance <= 10'd10) wall_half_height = 6'd28;
        else if (distance <= 10'd11) wall_half_height = 6'd27;
        else if (distance <= 10'd12) wall_half_height = 6'd26;
        else if (distance <= 10'd14) wall_half_height = 6'd25;
        else if (distance <= 10'd15) wall_half_height = 6'd24;
        else if (distance <= 10'd17) wall_half_height = 6'd23;
        else if (distance <= 10'd18) wall_half_height = 6'd22;
        else if (distance <= 10'd20) wall_half_height = 6'd21;
        else if (distance <= 10'd22) wall_half_height = 6'd20;
        else if (distance <= 10'd25) wall_half_height = 6'd19;
        else if (distance <= 10'd26) wall_half_height = 6'd18;
        else if (distance <= 10'd29) wall_half_height = 6'd17;
        else if (distance <= 10'd32) wall_half_height = 6'd16;
        else if (distance <= 10'd35) wall_half_height = 6'd15;
        else if (distance <= 10'd38) wall_half_height = 6'd14;
        else if (distance <= 10'd43) wall_half_height = 6'd13;
        else if (distance <= 10'd48) wall_half_height = 6'd12;
        else if (distance <= 10'd54) wall_half_height = 6'd11;
        else if (distance <= 10'd63) wall_half_height = 6'd10;
        else if (distance <= 10'd76) wall_half_height = 6'd9;
        else                         wall_half_height = 6'd8;
    end
endfunction

function [4:0]wall_shade_for_distance (input [9:0]distance);
    begin
        // Output is RGB565 red brightness: 31 = brightest, 5 = darkest.
        if      (distance <= 10'd12) wall_shade_for_distance = 5'd31;
        else if (distance <= 10'd14) wall_shade_for_distance = 5'd30;
        else if (distance <= 10'd16) wall_shade_for_distance = 5'd29;
        else if (distance <= 10'd17) wall_shade_for_distance = 5'd28;
        else if (distance <= 10'd19) wall_shade_for_distance = 5'd27;
        else if (distance <= 10'd21) wall_shade_for_distance = 5'd26;
        else if (distance <= 10'd22) wall_shade_for_distance = 5'd25;
        else if (distance <= 10'd24) wall_shade_for_distance = 5'd24;
        else if (distance <= 10'd26) wall_shade_for_distance = 5'd23;
        else if (distance <= 10'd29) wall_shade_for_distance = 5'd22;
        else if (distance <= 10'd31) wall_shade_for_distance = 5'd21;
        else if (distance <= 10'd33) wall_shade_for_distance = 5'd20;
        else if (distance <= 10'd36) wall_shade_for_distance = 5'd19;
        else if (distance <= 10'd38) wall_shade_for_distance = 5'd18;
        else if (distance <= 10'd40) wall_shade_for_distance = 5'd17;
        else if (distance <= 10'd43) wall_shade_for_distance = 5'd16;
        else if (distance <= 10'd46) wall_shade_for_distance = 5'd15;
        else if (distance <= 10'd49) wall_shade_for_distance = 5'd14;
        else if (distance <= 10'd52) wall_shade_for_distance = 5'd13;
        else if (distance <= 10'd56) wall_shade_for_distance = 5'd12;
        else if (distance <= 10'd61) wall_shade_for_distance = 5'd11;
        else if (distance <= 10'd66) wall_shade_for_distance = 5'd10;
        else if (distance <= 10'd71) wall_shade_for_distance = 5'd9;
        else if (distance <= 10'd76) wall_shade_for_distance = 5'd8;
        else if (distance <= 10'd84) wall_shade_for_distance = 5'd7;
        else if (distance <= 10'd96) wall_shade_for_distance = 5'd6;
        else                         wall_shade_for_distance = 5'd5;
    end
endfunction

function [15:0]wall_colour;
    input [4:0] red_brightness;
    begin
        // RGB565: 5 red bits, 6 green bits, 5 blue bits.
        wall_colour = {red_brightness, 6'd0, 5'd0};
    end
endfunction

// Return 1 for a wall and 0 for empty space.  Each row is a 10-bit value
// whose bit number is the x coordinate.  Change these ten rows to design
// a different map.  The solid outer border keeps the player in the map.
function map_is_wall (input [3:0]x, [3:0]y, [99:0]map_bits);
    begin
        // If we are outside the map, just return as a wall
        if ((x > 4'd9) || (y > 4'd9))
            map_is_wall = 1'b1;
        
        // Otherwise, return the wall state
        else
            map_is_wall = map_bits[7'd99 - (y * 7'd10) - x];
    end
endfunction
