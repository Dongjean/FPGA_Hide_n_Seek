// Lookup tables for the floor / ceiling and the sprites

// Ray-march steps (1/16 cell) that land on the row with wall half height hh
function [6:0]floor_dist_steps (input [5:0]hh);
    begin
        case (hh)
            6'd32: floor_dist_steps = 7'd6;
            6'd31: floor_dist_steps = 7'd7;
            6'd30: floor_dist_steps = 7'd8;
            6'd29: floor_dist_steps = 7'd9;
            6'd28: floor_dist_steps = 7'd10;
            6'd27: floor_dist_steps = 7'd11;
            6'd26: floor_dist_steps = 7'd12;
            6'd25: floor_dist_steps = 7'd13;
            6'd24: floor_dist_steps = 7'd15;
            6'd23: floor_dist_steps = 7'd16;
            6'd22: floor_dist_steps = 7'd18;
            6'd21: floor_dist_steps = 7'd19;
            6'd20: floor_dist_steps = 7'd21;
            6'd19: floor_dist_steps = 7'd24;
            6'd18: floor_dist_steps = 7'd26;
            6'd17: floor_dist_steps = 7'd28;
            6'd16: floor_dist_steps = 7'd31;
            6'd15: floor_dist_steps = 7'd34;
            6'd14: floor_dist_steps = 7'd37;
            6'd13: floor_dist_steps = 7'd41;
            6'd12: floor_dist_steps = 7'd46;
            6'd11: floor_dist_steps = 7'd51;
            6'd10: floor_dist_steps = 7'd59;
            6'd9: floor_dist_steps = 7'd70;
            default: floor_dist_steps = 7'd77;
        endcase
    end
endfunction

// 256 * 48 / size, size = hh + (hh >> 1), texel step per screen pixel
function [10:0]sprite_tex_step (input [5:0]hh);
    begin
        case (hh)
            6'd8: sprite_tex_step = 11'd1024;
            6'd9: sprite_tex_step = 11'd945;
            6'd10: sprite_tex_step = 11'd819;
            6'd11: sprite_tex_step = 11'd768;
            6'd12: sprite_tex_step = 11'd683;
            6'd13: sprite_tex_step = 11'd647;
            6'd14: sprite_tex_step = 11'd585;
            6'd15: sprite_tex_step = 11'd559;
            6'd16: sprite_tex_step = 11'd512;
            6'd17: sprite_tex_step = 11'd492;
            6'd18: sprite_tex_step = 11'd455;
            6'd19: sprite_tex_step = 11'd439;
            6'd20: sprite_tex_step = 11'd410;
            6'd21: sprite_tex_step = 11'd396;
            6'd22: sprite_tex_step = 11'd372;
            6'd23: sprite_tex_step = 11'd361;
            6'd24: sprite_tex_step = 11'd341;
            6'd25: sprite_tex_step = 11'd332;
            6'd26: sprite_tex_step = 11'd315;
            6'd27: sprite_tex_step = 11'd307;
            6'd28: sprite_tex_step = 11'd293;
            6'd29: sprite_tex_step = 11'd286;
            6'd30: sprite_tex_step = 11'd273;
            default: sprite_tex_step = 11'd273;
        endcase
    end
endfunction