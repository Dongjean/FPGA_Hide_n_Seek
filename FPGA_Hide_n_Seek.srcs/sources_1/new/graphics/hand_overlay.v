`timescale 1ns / 1ps
// First-person held item drawn over the 3D view
// Hunter: energy blast (gun) or hider detector (item), empty hand when that one is used up
// Hider: freeze blast (gun) or flashbang (item), nothing when that one is used up
// A counted shot or use turns the overlay's own pixels white for 1/8 s
module hand_overlay #(
    parameter integer CLK_HZ = 6_250_000
)(
    input         clk,
    input  [12:0] pixel_index,
    input         in_game,
    input         is_hider,
    input         item_sel,      // weapon_sel[0]: 0 gun, 1 item
    input         has_ammo,
    input         has_use,
    input         fired_gun,     // 1-cycle
    input         used_item,     // 1-cycle
    output        hit,
    output [15:0] colour
);

    // Overlays: 1 flashbang, 2 freeze blast, 3 energy blast, 4 hider detector, 5 empty hand
    // Stored as the 48x36 bottom-right window (x 48..95, y 28..63) of the 96x64 screen
    localparam [2:0] O_NONE = 3'd0, O_FLASH = 3'd1, O_FREEZE = 3'd2,
                     O_BLAST = 3'd3, O_DETECT = 3'd4, O_EMPTY = 3'd5;
    localparam integer FLASH_CLKS = CLK_HZ / 8;

    wire [2:0] current = !in_game ? O_NONE :
                         is_hider ? (item_sel ? (has_use  ? O_FLASH  : O_NONE)
                                              : (has_ammo ? O_FREEZE : O_NONE))
                                  : (item_sel ? (has_use  ? O_DETECT : O_EMPTY)
                                              : (has_ammo ? O_BLAST  : O_EMPTY));

    // Keep showing the item that was used while it flashes, even if that emptied it
    reg [31:0] flash_count = 32'd0;
    reg [2:0]  flash_ovl   = O_NONE;
    always @(posedge clk) begin
        if (fired_gun || used_item) begin
            flash_count <= FLASH_CLKS;
            flash_ovl   <= current;
        end else if (flash_count != 32'd0) begin
            flash_count <= flash_count - 32'd1;
        end
    end
    wire       flashing = (flash_count != 32'd0) && in_game;
    wire [2:0] shown    = flashing ? flash_ovl : current;

    wire [5:0]  pixel_y = pixel_index / 13'd96;
    wire [12:0] y_x96   = ({7'd0, pixel_y} << 6) + ({7'd0, pixel_y} << 5);
    wire [6:0]  pixel_x = pixel_index - y_x96;

    wire       in_window = (pixel_x >= 7'd48) && (pixel_y >= 6'd28);
    wire [6:0] wx7 = pixel_x - 7'd48;
    wire [5:0] wx  = wx7[5:0];
    wire [5:0] wy  = pixel_y - 6'd28;
    wire [2:0] ovl_idx = shown - 3'd1;

    // overlay * 1728 + wy * 48 + wx
    wire [13:0] ovl_base = ({11'd0, ovl_idx} << 10) + ({11'd0, ovl_idx} << 9) +
                           ({11'd0, ovl_idx} << 7)  + ({11'd0, ovl_idx} << 6);
    wire [13:0] row_base = ({8'd0, wy} << 5) + ({8'd0, wy} << 4);
    wire [13:0] addr     = (in_window && shown != O_NONE) ? (ovl_base + row_base + {8'd0, wx}) : 14'd0;

    (* rom_style = "block" *) reg [3:0] overlay_texel [0:8639];   // 5 overlays * 48 * 36
    reg [15:0] overlay_palette [0:79];                            // 16 colours per overlay
    initial begin
        $readmemh("overlay_idx.mem", overlay_texel);
        $readmemh("overlay_pal.mem", overlay_palette);
    end

    reg [3:0] texel;
    always @(posedge clk)
        texel <= overlay_texel[addr];

    assign hit    = in_window && (shown != O_NONE) && (texel != 4'd0);
    assign colour = flashing ? 16'hFFFF : overlay_palette[{ovl_idx, texel}];

endmodule
