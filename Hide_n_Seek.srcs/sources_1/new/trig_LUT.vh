// sine(x) lookup table to save computational resources
// O(1)
function signed [7:0]sin_lut (input [7:0]dir);
    begin
        case (dir)
            8'd0: sin_lut = 0;    8'd1: sin_lut = 2;
            8'd2: sin_lut = 3;    8'd3: sin_lut = 5;
            8'd4: sin_lut = 6;    8'd5: sin_lut = 8;
            8'd6: sin_lut = 9;    8'd7: sin_lut = 11;
            8'd8: sin_lut = 12;   8'd9: sin_lut = 14;
            8'd10: sin_lut = 16;  8'd11: sin_lut = 17;
            8'd12: sin_lut = 19;  8'd13: sin_lut = 20;
            8'd14: sin_lut = 22;  8'd15: sin_lut = 23;
            8'd16: sin_lut = 24;  8'd17: sin_lut = 26;
            8'd18: sin_lut = 27;  8'd19: sin_lut = 29;
            8'd20: sin_lut = 30;  8'd21: sin_lut = 32;
            8'd22: sin_lut = 33;  8'd23: sin_lut = 34;
            8'd24: sin_lut = 36;  8'd25: sin_lut = 37;
            8'd26: sin_lut = 38;  8'd27: sin_lut = 39;
            8'd28: sin_lut = 41;  8'd29: sin_lut = 42;
            8'd30: sin_lut = 43;  8'd31: sin_lut = 44;
            8'd32: sin_lut = 45;  8'd33: sin_lut = 46;
            8'd34: sin_lut = 47;  8'd35: sin_lut = 48;
            8'd36: sin_lut = 49;  8'd37: sin_lut = 50;
            8'd38: sin_lut = 51;  8'd39: sin_lut = 52;
            8'd40: sin_lut = 53;  8'd41: sin_lut = 54;
            8'd42: sin_lut = 55;  8'd43: sin_lut = 56;
            8'd44: sin_lut = 56;  8'd45: sin_lut = 57;
            8'd46: sin_lut = 58;  8'd47: sin_lut = 59;
            8'd48: sin_lut = 59;  8'd49: sin_lut = 60;
            8'd50: sin_lut = 60;  8'd51: sin_lut = 61;
            8'd52: sin_lut = 61;  8'd53: sin_lut = 62;
            8'd54: sin_lut = 62;  8'd55: sin_lut = 62;
            8'd56: sin_lut = 63;  8'd57: sin_lut = 63;
            8'd58: sin_lut = 63;  8'd59: sin_lut = 64;
            8'd60: sin_lut = 64;  8'd61: sin_lut = 64;
            8'd62: sin_lut = 64;  8'd63: sin_lut = 64;
            8'd64: sin_lut = 64;  8'd65: sin_lut = 64;
            8'd66: sin_lut = 64;  8'd67: sin_lut = 64;
            8'd68: sin_lut = 64;  8'd69: sin_lut = 64;
            8'd70: sin_lut = 63;  8'd71: sin_lut = 63;
            8'd72: sin_lut = 63;  8'd73: sin_lut = 62;
            8'd74: sin_lut = 62;  8'd75: sin_lut = 62;
            8'd76: sin_lut = 61;  8'd77: sin_lut = 61;
            8'd78: sin_lut = 60;  8'd79: sin_lut = 60;
            8'd80: sin_lut = 59;  8'd81: sin_lut = 59;
            8'd82: sin_lut = 58;  8'd83: sin_lut = 57;
            8'd84: sin_lut = 56;  8'd85: sin_lut = 56;
            8'd86: sin_lut = 55;  8'd87: sin_lut = 54;
            8'd88: sin_lut = 53;  8'd89: sin_lut = 52;
            8'd90: sin_lut = 51;  8'd91: sin_lut = 50;
            8'd92: sin_lut = 49;  8'd93: sin_lut = 48;
            8'd94: sin_lut = 47;  8'd95: sin_lut = 46;
            8'd96: sin_lut = 45;  8'd97: sin_lut = 44;
            8'd98: sin_lut = 43;  8'd99: sin_lut = 42;
            8'd100: sin_lut = 41; 8'd101: sin_lut = 39;
            8'd102: sin_lut = 38; 8'd103: sin_lut = 37;
            8'd104: sin_lut = 36; 8'd105: sin_lut = 34;
            8'd106: sin_lut = 33; 8'd107: sin_lut = 32;
            8'd108: sin_lut = 30; 8'd109: sin_lut = 29;
            8'd110: sin_lut = 27; 8'd111: sin_lut = 26;
            8'd112: sin_lut = 24; 8'd113: sin_lut = 23;
            8'd114: sin_lut = 22; 8'd115: sin_lut = 20;
            8'd116: sin_lut = 19; 8'd117: sin_lut = 17;
            8'd118: sin_lut = 16; 8'd119: sin_lut = 14;
            8'd120: sin_lut = 12; 8'd121: sin_lut = 11;
            8'd122: sin_lut = 9;  8'd123: sin_lut = 8;
            8'd124: sin_lut = 6;  8'd125: sin_lut = 5;
            8'd126: sin_lut = 3;  8'd127: sin_lut = 2;

            8'd128: sin_lut = 0;   8'd129: sin_lut = -2;
            8'd130: sin_lut = -3;  8'd131: sin_lut = -5;
            8'd132: sin_lut = -6;  8'd133: sin_lut = -8;
            8'd134: sin_lut = -9;  8'd135: sin_lut = -11;
            8'd136: sin_lut = -12; 8'd137: sin_lut = -14;
            8'd138: sin_lut = -16; 8'd139: sin_lut = -17;
            8'd140: sin_lut = -19; 8'd141: sin_lut = -20;
            8'd142: sin_lut = -22; 8'd143: sin_lut = -23;
            8'd144: sin_lut = -24; 8'd145: sin_lut = -26;
            8'd146: sin_lut = -27; 8'd147: sin_lut = -29;
            8'd148: sin_lut = -30; 8'd149: sin_lut = -32;
            8'd150: sin_lut = -33; 8'd151: sin_lut = -34;
            8'd152: sin_lut = -36; 8'd153: sin_lut = -37;
            8'd154: sin_lut = -38; 8'd155: sin_lut = -39;
            8'd156: sin_lut = -41; 8'd157: sin_lut = -42;
            8'd158: sin_lut = -43; 8'd159: sin_lut = -44;
            8'd160: sin_lut = -45; 8'd161: sin_lut = -46;
            8'd162: sin_lut = -47; 8'd163: sin_lut = -48;
            8'd164: sin_lut = -49; 8'd165: sin_lut = -50;
            8'd166: sin_lut = -51; 8'd167: sin_lut = -52;
            8'd168: sin_lut = -53; 8'd169: sin_lut = -54;
            8'd170: sin_lut = -55; 8'd171: sin_lut = -56;
            8'd172: sin_lut = -56; 8'd173: sin_lut = -57;
            8'd174: sin_lut = -58; 8'd175: sin_lut = -59;
            8'd176: sin_lut = -59; 8'd177: sin_lut = -60;
            8'd178: sin_lut = -60; 8'd179: sin_lut = -61;
            8'd180: sin_lut = -61; 8'd181: sin_lut = -62;
            8'd182: sin_lut = -62; 8'd183: sin_lut = -62;
            8'd184: sin_lut = -63; 8'd185: sin_lut = -63;
            8'd186: sin_lut = -63; 8'd187: sin_lut = -64;
            8'd188: sin_lut = -64; 8'd189: sin_lut = -64;
            8'd190: sin_lut = -64; 8'd191: sin_lut = -64;
            8'd192: sin_lut = -64; 8'd193: sin_lut = -64;
            8'd194: sin_lut = -64; 8'd195: sin_lut = -64;
            8'd196: sin_lut = -64; 8'd197: sin_lut = -64;
            8'd198: sin_lut = -63; 8'd199: sin_lut = -63;
            8'd200: sin_lut = -63; 8'd201: sin_lut = -62;
            8'd202: sin_lut = -62; 8'd203: sin_lut = -62;
            8'd204: sin_lut = -61; 8'd205: sin_lut = -61;
            8'd206: sin_lut = -60; 8'd207: sin_lut = -60;
            8'd208: sin_lut = -59; 8'd209: sin_lut = -59;
            8'd210: sin_lut = -58; 8'd211: sin_lut = -57;
            8'd212: sin_lut = -56; 8'd213: sin_lut = -56;
            8'd214: sin_lut = -55; 8'd215: sin_lut = -54;
            8'd216: sin_lut = -53; 8'd217: sin_lut = -52;
            8'd218: sin_lut = -51; 8'd219: sin_lut = -50;
            8'd220: sin_lut = -49; 8'd221: sin_lut = -48;
            8'd222: sin_lut = -47; 8'd223: sin_lut = -46;
            8'd224: sin_lut = -45; 8'd225: sin_lut = -44;
            8'd226: sin_lut = -43; 8'd227: sin_lut = -42;
            8'd228: sin_lut = -41; 8'd229: sin_lut = -39;
            8'd230: sin_lut = -38; 8'd231: sin_lut = -37;
            8'd232: sin_lut = -36; 8'd233: sin_lut = -34;
            8'd234: sin_lut = -33; 8'd235: sin_lut = -32;
            8'd236: sin_lut = -30; 8'd237: sin_lut = -29;
            8'd238: sin_lut = -27; 8'd239: sin_lut = -26;
            8'd240: sin_lut = -24; 8'd241: sin_lut = -23;
            8'd242: sin_lut = -22; 8'd243: sin_lut = -20;
            8'd244: sin_lut = -19; 8'd245: sin_lut = -17;
            8'd246: sin_lut = -16; 8'd247: sin_lut = -14;
            8'd248: sin_lut = -12; 8'd249: sin_lut = -11;
            8'd250: sin_lut = -9;  8'd251: sin_lut = -8;
            8'd252: sin_lut = -6;  8'd253: sin_lut = -5;
            8'd254: sin_lut = -3;  8'd255: sin_lut = -2;
        endcase
    end
endfunction

// cos(x) lookup table
// cos(dir) = sin(dir + 90 degrees), dont need to make another big hashtable
function signed [7:0]cos_lut(input [7:0]dir);
    begin
        cos_lut = sin_lut(dir + 8'd64);
    end
endfunction