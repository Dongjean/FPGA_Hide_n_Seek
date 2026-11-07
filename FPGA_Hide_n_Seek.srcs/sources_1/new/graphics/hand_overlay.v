`timescale 1ns / 1ps
// First-person held item drawn over the 3D view, always the one sw0 picks
// Hunter: shotgun (gun) or hider detector (item).  Hider: freeze blast (gun) or flashbang (item)
// Shotgun shot: muzzle flash overlay for 1/10 s
// Other counted shot or use: the overlay's own pixels turn white for 1/8 s
// Press with nothing left: the overlay is tinted red, on/off twice
// Frozen: ice-blue border around the screen
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
    input         try_fire,      // 1-cycle: fire pressed while I can act
    input         fired_gun,     // 1-cycle
    input         used_item,     // 1-cycle
    input         frozen,
    output        hit,
    output [15:0] colour
);

    // Overlays: 1 flashbang, 2 freeze blast, 3 shotgun, 4 hider detector, 5 muzzle flash
    // Stored as the 48x38 bottom-right window (x 48..95, y 26..63) of the 96x64 screen
    localparam [2:0] O_NONE = 3'd0, O_FLASH = 3'd1, O_FREEZE = 3'd2,
                     O_GUN = 3'd3, O_DETECT = 3'd4, O_MUZZLE = 3'd5;
    localparam [19:0] WHITE_CLKS  = CLK_HZ / 8;
    localparam [19:0] MUZZLE_CLKS = CLK_HZ / 10;
    localparam [19:0] BLINK_CLKS  = CLK_HZ / 12;

    wire [2:0] current = !in_game ? O_NONE :
                         is_hider ? (item_sel ? O_FLASH  : O_FREEZE)
                                  : (item_sel ? O_DETECT : O_GUN);
    wire empty_try = try_fire && (item_sel ? !has_use : !has_ammo);
    wire gun_shot  = fired_gun && !is_hider;

    // Use flash: muzzle flash for a shotgun shot, white for anything else
    reg [19:0] use_count = 20'd0;
    reg        use_muzzle = 1'b0;
    always @(posedge clk) begin
        if (empty_try) begin
            use_count  <= 20'd0;
        end else if (fired_gun || used_item) begin
            use_count  <= gun_shot ? MUZZLE_CLKS : WHITE_CLKS;
            use_muzzle <= gun_shot;
        end else if (use_count != 20'd0) begin
            use_count  <= use_count - 20'd1;
        end
    end

    // Red tint: 4 phases (on, off, on, off)
    reg [19:0] blink_count = 20'd0;
    reg [2:0]  blink_phase = 3'd0;      // phases left
    always @(posedge clk) begin
        if (empty_try) begin
            blink_count <= BLINK_CLKS;
            blink_phase <= 3'd4;
        end else if (blink_phase != 3'd0) begin
            if (blink_count == 20'd0) begin
                blink_count <= BLINK_CLKS;
                blink_phase <= blink_phase - 3'd1;
            end else begin
                blink_count <= blink_count - 20'd1;
            end
        end
    end

    wire white = (use_count != 20'd0) && !use_muzzle && in_game;
    wire red   = blink_phase[0] == 1'b0 && blink_phase != 3'd0 && in_game;   // phases 4 and 2
    wire [2:0] shown = ((use_count != 20'd0) && use_muzzle && (current == O_GUN)) ? O_MUZZLE : current;

    wire [5:0]  pixel_y = pixel_index / 13'd96;
    wire [12:0] y_x96   = ({7'd0, pixel_y} << 6) + ({7'd0, pixel_y} << 5);
    wire [6:0]  pixel_x = pixel_index - y_x96;

    wire       in_window = (pixel_x >= 7'd48) && (pixel_y >= 6'd26);
    wire [6:0] wx7 = pixel_x - 7'd48;
    wire [5:0] wx  = wx7[5:0];
    wire [5:0] wy  = pixel_y - 6'd26;
    wire [2:0] ovl_idx = shown - 3'd1;

    // overlay * 1824 + wy * 48 + wx
    wire [13:0] ovl_base = ({11'd0, ovl_idx} << 10) + ({11'd0, ovl_idx} << 9) +
                           ({11'd0, ovl_idx} << 8)  + ({11'd0, ovl_idx} << 5);
    wire [13:0] row_base = ({8'd0, wy} << 5) + ({8'd0, wy} << 4);
    wire [13:0] addr     = (in_window && shown != O_NONE) ? (ovl_base + row_base + {8'd0, wx}) : 14'd0;

    (* rom_style = "block" *) reg [3:0] overlay_texel [0:9119];   // 5 overlays * 48 * 38
    reg [15:0] overlay_palette [0:79];                            // 16 colours per overlay
    initial begin
        $readmemh("overlay_idx.mem", overlay_texel);
        $readmemh("overlay_pal.mem", overlay_palette);
    end

    reg [3:0] texel;
    always @(posedge clk)
        texel <= overlay_texel[addr];

    // Ice border: solid outer ring, dotted ring inside it
    wire edge0 = (pixel_x == 7'd0) || (pixel_x == 7'd95) || (pixel_y == 6'd0) || (pixel_y == 6'd63);
    wire edge1 = (((pixel_x == 7'd1) || (pixel_x == 7'd94)) && (pixel_y >= 6'd1) && (pixel_y <= 6'd62)) ||
                 (((pixel_y == 6'd1) || (pixel_y == 6'd62)) && (pixel_x >= 7'd1) && (pixel_x <= 7'd94));
    wire frost = frozen && in_game && (edge0 || (edge1 && (pixel_x[0] == pixel_y[0])));
    localparam [15:0] ICE       = 16'h6E5F;    // (110, 200, 255)
    localparam [15:0] ICE_LIGHT = 16'hCF9F;    // (200, 240, 255)

    wire        item_hit = in_window && (shown != O_NONE) && (texel != 4'd0);
    wire [15:0] drawn    = overlay_palette[{ovl_idx, texel}];
    wire [15:0] tinted   = {1'b0, drawn[15:12], 1'b0, drawn[10:6], 1'b0, drawn[4:1]} + 16'h7800;   // half drawn + half red

    assign hit    = frost || item_hit;
    assign colour = frost ? (edge0 ? ICE : ICE_LIGHT) :
                    white ? 16'hFFFF :
                    red   ? tinted : drawn;

endmodule
