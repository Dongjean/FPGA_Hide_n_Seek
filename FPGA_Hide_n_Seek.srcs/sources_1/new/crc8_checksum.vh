//CRC-8 checksum
//Polynomial 0x07, one byte per call. Used to check packets on the link.
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
