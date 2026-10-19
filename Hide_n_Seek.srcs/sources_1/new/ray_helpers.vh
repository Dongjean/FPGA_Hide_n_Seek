// Ray logic helpers for 3D Rendering

function [35:0]move_ray (input signed [17:0]x, signed [17:0]y, [7:0]dir);
    begin
        move_ray = {x + $signed(sin_lut(dir)), y - $signed(cos_lut(dir))};
    end
endfunction

//function signed [7:0] ray_angle_offset (input [6:0]column);
//    reg signed [8:0] centred;
//    reg signed [11:0] wide_centred;
//    reg signed [11:0] scaled;
//    begin
//        centred      = $signed({1'b0, column}) - 9'sd48; // -48 to +47
//        wide_centred = centred;
//        scaled       = (wide_centred <<< 3) + wide_centred; // centred * 9
//        ray_angle_offset = scaled >>> 4;                    // centred * 9 / 16
//    end
//endfunction

//function signed [7:0]ray_angle_offset (input [6:0]column);
//    reg signed [8:0]  centred;
//    reg signed [11:0] wide_centred;
//    reg signed [11:0] scaled;
//    begin
//        centred      = $signed({1'b0, column}) - 9'sd48;
//        wide_centred = centred;

//        // Smaller FOV: centred × 7 / 16
//        scaled = (wide_centred <<< 2) +
//                 (wide_centred <<< 1) +
//                  wide_centred;
//        ray_angle_offset = scaled >>> 4;
//    end
//endfunction

function signed [7:0]ray_angle_offset (input [6:0]column);
    reg signed [8:0]  centred;
    reg signed [11:0] wide_centred;
    reg signed [11:0] scaled;
    begin
        centred      = $signed({1'b0, column}) - 9'sd48;
        wide_centred = centred;

        // Approximately 50° FOV: centred × 3 / 8
        scaled = (wide_centred <<< 1) + wide_centred;
        ray_angle_offset = scaled >>> 3;
    end
endfunction
