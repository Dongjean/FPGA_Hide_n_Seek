// CRC-8 with polynomial x^8 + x^2 + x + 1 (0x07), initial value 0x00.
// Processes one byte per call; all 8 bit steps are unrolled into one clock.
// Any single-bit error and any burst error up to 8 bits long is always detected.

function [7:0]crc8_update(input [7:0]crc, input [7:0]data);
    integer i;
    reg [7:0]c;
    begin
        c = crc ^ data;
        for (i = 0; i < 8; i = i + 1)
            c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
        crc8_update = c;
    end
endfunction
