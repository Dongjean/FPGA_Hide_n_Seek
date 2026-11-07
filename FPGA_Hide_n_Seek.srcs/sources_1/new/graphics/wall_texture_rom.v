`timescale 1ns / 1ps
// Wall texture ROM: id 0 plain wall, 1..9 ornaments
// Texels are read one clock late from block RAM, the OLED pixel index holds for 16 clocks
module wall_texture_rom (
    input         clk,
    input  [3:0]  tex_id,
    input  [3:0]  u,
    input  [3:0]  v,
    input         lit,      // 1: +40 % palette, 0: -40 % palette
    output [15:0] colour    // RGB565, not distance-shaded
);

    (* rom_style = "block" *) reg [3:0] texel_index [0:2559];
    reg [15:0] palette_unlit [0:159];
    reg [15:0] palette_lit   [0:159];

    initial begin
        $readmemh("wall_tex_idx.mem",   texel_index);
        $readmemh("wall_pal_unlit.mem", palette_unlit);
        $readmemh("wall_pal_lit.mem",   palette_lit);
    end

    // Anything above 9 is the plain wall
    wire [3:0]  id          = (tex_id > 4'd9) ? 4'd0 : tex_id;
    wire [11:0] texel_addr  = {id, v, u};
    reg  [3:0]  index;
    always @(posedge clk)
        index <= texel_index[texel_addr];
    wire [7:0]  palette_addr = {id, index};

    assign colour = lit ? palette_lit[palette_addr] : palette_unlit[palette_addr];

endmodule
