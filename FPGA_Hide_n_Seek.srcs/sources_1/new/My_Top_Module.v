`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
//  FILL IN THE FOLLOWING INFORMATION:
//  STUDENT A NAME: Dongjin Shin
//  STUDENT B NAME: Isaac Goh Yong Chee
//  STUDENT C NAME: Andrew Chong Kian Wei
//  STUDENT D NAME: Toh Jian Bin
//////////////////////////////////////////////////////////////////////////////////

// Top module
module My_Top_Module (input clk, btnC, btnU, btnD, btnL, btnR, input [15:0]sw,
                      output [7:0]JB, output [7:0]JC);

    wire oled_clk;
    clk_6p25m oled_clk_gen (.clk(clk), .slow_clk(oled_clk));

    wire frame_begin;
    wire sending_pixels;
    wire sample_pixel;
    wire [12:0]pixel_index;
    wire [15:0]pixel_data;

    // Oled Display module
    Oled_Display oled_display (
        .clk            (oled_clk),
        .reset          (btnC),
        .frame_begin    (frame_begin),
        .sending_pixels (sending_pixels),
        .sample_pixel   (sample_pixel),
        .pixel_index    (pixel_index),
        .pixel_data     (pixel_data),
        .cs             (JB[0]),
        .sdin           (JB[1]),
        .sclk           (JB[3]),
        .d_cn           (JB[4]),
        .resn           (JB[5]),
        .vccen          (JB[6]),
        .pmoden         (JB[7])
    );

    localparam [7:0]DIR_NORTH = 8'd0;
    localparam [7:0]DIR_EAST  = 8'd64;
    localparam [7:0]DIR_SOUTH = 8'd128;
    localparam [7:0]DIR_WEST  = 8'd192;

    // Player location in Q8.8 units.  Start at the centre of grid square
    wire signed [15:0]player_x;
    wire signed [15:0]player_y;
    wire [7:0]view_dir;

    localparam [99:0] DEFAULT_MAP = {
        10'b1111111111,
        10'b1010001001,
        10'b1010001001,
        10'b1010011001,
        10'b1010010001,
        10'b1000000001,
        10'b1100011001,
        10'b1000010001,
        10'b1000010001,
        10'b1111111111
    };

    // ================= Andrew: world generation (test build) =================
    // sw0 flip (either direction) -> new seed -> map_gen -> cell array -> OLED #2.
    // A boot map (seed ACE1) is generated automatically after power-up/btnC so
    // the screen is never blank.  Set USE_GENERATED_MAP = 0 to give Dongjin's
    // engine the old DEFAULT_MAP again (the minimap still shows the new maze).
    localparam USE_GENERATED_MAP = 1;

    // ---- Seed: sw0 flip on this board (host only for now) ----
    wire [15:0] seed;
    wire        seed_valid;
    seed_capture seed_cap (
        .clk           (oled_clk),
        .reset         (btnC),
        .sw_raw        (sw[0]),
        .is_host       (1'b1),        // single board for now; Toh's link later
        .menu_new_game (1'b0),
        .rx_seed       (16'd0),
        .rx_seed_valid (1'b0),
        .tx_seed       (),
        .tx_seed_valid (),
        .seed          (seed),
        .seed_valid    (seed_valid),
        .sw_toggled    ()
    );

    // ---- Boot map: one start pulse 4 cycles after reset ----
    reg [2:0] boot_cnt = 3'd0;
    reg       boot_start = 1'b0;
    always @(posedge oled_clk) begin
        if (btnC) begin
            boot_cnt   <= 3'd0;
            boot_start <= 1'b0;
        end else begin
            boot_start <= (boot_cnt == 3'd3);          // exactly one pulse
            if (boot_cnt != 3'd4) boot_cnt <= boot_cnt + 3'd1;
        end
    end

    wire        gen_start = seed_valid | boot_start;
    wire [15:0] gen_seed  = seed_valid ? seed : 16'hACE1;

    // ---- Maze generator ----
    wire       gen_busy, gen_done, gen_we;
    wire [7:0] gen_waddr;
    wire [1:0] gen_wdata;
    map_gen #(.LOOP_WALLS(3)) maze (
        .clk   (oled_clk),
        .reset (btnC),
        .start (gen_start),
        .seed  (gen_seed),
        .busy  (gen_busy),
        .done  (gen_done),
        .we    (gen_we),
        .waddr (gen_waddr),
        .wdata (gen_wdata)
    );

    // ---- Temporary cell-type array (replaced by world_top in module 6) ----
    // cells[2*(y*10+x) +: 2]: 00 floor, 01 wall, 10 portal, 11 capsule
    reg [199:0] cells = {100{2'b01}};
    always @(posedge oled_clk) begin
        if (btnC)
            cells <= {100{2'b01}};                    // all wall until the boot map arrives
        else if (gen_we)
            cells[{gen_waddr[6:0], 1'b0} +: 2] <= gen_wdata;
    end

    // ---- Convert to the engine's format: bit (99 - (y*10+x)), 1 = solid ----
    wire [99:0] gen_map_bits;
    genvar gi;
    generate
        for (gi = 0; gi < 100; gi = gi + 1) begin : g_map_bits
            assign gen_map_bits[99 - gi] = (cells[2*gi +: 2] == 2'b01) ||
                                           (cells[2*gi +: 2] == 2'b10);
        end
    endgenerate

    wire [99:0] map_bits = USE_GENERATED_MAP ? gen_map_bits : DEFAULT_MAP;

    // 3D Renderer
    Raycast_3D_Engine #(
        .DIR_NORTH (DIR_NORTH),
        .DIR_EAST  (DIR_EAST),
        .DIR_SOUTH (DIR_SOUTH),
        .DIR_WEST  (DIR_WEST)
    ) renderer (
        .clk         (oled_clk),
        .reset       (btnC),
        .player_x    (player_x),
        .player_y    (player_y),
        .view_dir    (view_dir),
        .frame_begin (frame_begin),
        .pixel_index (pixel_index),
        .map_bits    (map_bits),
        .pixel_data  (pixel_data)
    );
    
    // Player Movement Module
    player_movement #(
        .DIR_NORTH (DIR_NORTH),
        .DIR_EAST  (DIR_EAST),
        .DIR_SOUTH (DIR_SOUTH),
        .DIR_WEST  (DIR_WEST)
    ) player_mover (
        .clk          (oled_clk),
        .reset        (btnC),
        .btn_forward  (btnU),
        .btn_backward (btnD),
        .btn_left     (btnL),
        .btn_right    (btnR),
        .frame_begin  (frame_begin),
        .map_bits     (map_bits),
        .player_x     (player_x),
        .player_y     (player_y),
        .view_dir     (view_dir)
    );

    // ================= Andrew: OLED #2 on JC (minimap) =================
    wire        frame_begin2;
    wire        sending_pixels2;
    wire        sample_pixel2;
    wire [12:0] pixel_index2;
    wire [15:0] pixel_data2;
    wire [15:0] minimap_pixel;
    wire        in_minimap;

    Oled_Display oled_display2 (
        .clk            (oled_clk),
        .reset          (btnC),
        .frame_begin    (frame_begin2),
        .sending_pixels (sending_pixels2),
        .sample_pixel   (sample_pixel2),
        .pixel_index    (pixel_index2),
        .pixel_data     (pixel_data2),
        .cs             (JC[0]),
        .sdin           (JC[1]),
        .sclk           (JC[3]),
        .d_cn           (JC[4]),
        .resn           (JC[5]),
        .vccen          (JC[6]),
        .pmoden         (JC[7])
    );

    minimap_render minimap (
        .clk            (oled_clk),
        .reset          (btnC),
        .pixel_index    (pixel_index2),
        .cells          (cells),
        .player_x       (player_x),
        .player_y       (player_y),
        .view_dir       (view_dir),
        .pinger_active  (1'b0),           // game logic later
        .rx_hider_x     (16'sd0),
        .rx_hider_y     (16'sd0),
        .cap_fade_valid (2'b00),          // capsule_ctrl later
        .cap_fade_cell0 (7'd0),
        .cap_fade_cell1 (7'd0),
        .pixel_data     (minimap_pixel),
        .in_minimap     (in_minimap)
    );

    // Right strip (x = 64..95) is black until hud_render (module 8)
    assign pixel_data2 = in_minimap ? minimap_pixel : 16'h0000;

endmodule