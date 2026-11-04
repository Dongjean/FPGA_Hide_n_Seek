`timescale 1ns / 1ps
// Tests player_controls with a mouse on one instance and a keyboard on another:
//  - sw[15] already up at power-on does not start the game paused
//  - mouse movement turns the player for the right number of frames, both ways
//  - left click shoots once, right click swaps weapon
//  - keyboard: W walks, Space shoots, 2 selects weapon 2, Esc toggles pause
//  - buttons and switches still work alongside (btnU, flipping sw[15])

module tb_player_controls;
    localparam integer CLK_HZ = 1_000_000;
    localparam integer MS = 1_000_000;

    reg clk = 1'b0;
    always #500 clk = ~clk;

    // 60 Hz frame tick
    reg frame_tick = 1'b0;
    integer f;
    initial forever begin
        #(16 * MS);
        @(negedge clk); frame_tick = 1'b1; @(negedge clk); frame_tick = 1'b0;
    end

    reg btnU = 0;
    reg [15:0]sw = 16'h8000;     // sw[15] up from power-on
    tri1 m_clk, m_data, k_clk, k_data;
    ps2_device_model #(.IS_MOUSE(1)) mouse    (.ps2_clk(m_clk), .ps2_data(m_data));
    ps2_device_model #(.IS_MOUSE(0)) keyboard (.ps2_clk(k_clk), .ps2_data(k_data));

    wire m_fwd, m_tl, m_tr, m_shoot, m_wchg, m_paused, m_mouse;
    wire [1:0]m_weapon;
    player_controls #(.CLK_HZ(CLK_HZ), .MOUSE_STEP(4), .POWERUP_MS(5)) dut_m (
        .clk(clk), .frame_tick(frame_tick), .btnU(btnU), .btnD(1'b0), .btnL(1'b0), .btnR(1'b0), .btnC(1'b0),
        .sw(sw), .ps2_clk(m_clk), .ps2_data(m_data),
        .move_forward(m_fwd), .move_backward(), .turn_left(m_tl), .turn_right(m_tr), .shoot(m_shoot),
        .weapon_sel(m_weapon), .weapon_changed(m_wchg), .paused(m_paused), .pause_changed(),
        .confirm(), .reset_game(), .mouse_present(m_mouse), .keyboard_present()
    );

    wire k_fwd, k_shoot, k_paused, k_kbd;
    wire [1:0]k_weapon;
    player_controls #(.CLK_HZ(CLK_HZ), .MOUSE_STEP(4), .POWERUP_MS(5)) dut_k (
        .clk(clk), .frame_tick(frame_tick), .btnU(1'b0), .btnD(1'b0), .btnL(1'b0), .btnR(1'b0), .btnC(1'b0),
        .sw(16'h0000), .ps2_clk(k_clk), .ps2_data(k_data),
        .move_forward(k_fwd), .move_backward(), .turn_left(), .turn_right(), .shoot(k_shoot),
        .weapon_sel(k_weapon), .weapon_changed(), .paused(k_paused), .pause_changed(),
        .confirm(), .reset_game(), .mouse_present(), .keyboard_present(k_kbd)
    );

    // Count frames where a turn is active, and shots
    integer right_frames = 0, left_frames = 0, m_shots = 0, k_shots = 0;
    always @(posedge clk) begin
        if (frame_tick && m_tr) right_frames = right_frames + 1;
        if (frame_tick && m_tl) left_frames = left_frames + 1;
        if (m_shoot) m_shots = m_shots + 1;
        if (k_shoot) k_shots = k_shots + 1;
    end

    integer errors = 0;
    task check(input cond, input [8*64-1:0]msg);
        begin if (!cond) begin $display("FAIL %0s", msg); errors = errors + 1; end end
    endtask

    initial begin
        #(200 * MS);
        check(m_mouse && k_kbd, "devices not detected");
        check(!m_paused, "sw[15] up at power-on started the game paused");

        // Mouse turning: 12 counts right = 3 frames of turning right
        mouse.send_mouse_packet(0, 0, 0, 9'sd12, 9'sd0);
        #(150 * MS);
        check(right_frames == 3 && left_frames == 0, "12 counts right should turn right for 3 frames");
        // A big flick left is capped at 4 frames of turning
        right_frames = 0;
        mouse.send_mouse_packet(0, 0, 0, -9'sd100, 9'sd0);
        #(150 * MS);
        check(left_frames == 4 && right_frames == 0, "big flick left should turn left for 4 frames");
        $display("  mouse turning: 3 frames right for 12 counts, flick left capped at 4 frames");

        // Clicks
        mouse.send_mouse_packet(1, 0, 0, 9'sd0, 9'sd0);
        mouse.send_mouse_packet(1, 0, 0, 9'sd0, 9'sd0);   // still held
        mouse.send_mouse_packet(0, 0, 0, 9'sd0, 9'sd0);
        mouse.send_mouse_packet(0, 1, 0, 9'sd0, 9'sd0);   // right click
        mouse.send_mouse_packet(0, 0, 0, 9'sd0, 9'sd0);
        #(5 * MS);
        check(m_shots == 1, "held left click should shoot exactly once");
        check(m_weapon == 2'd1, "right click should swap to weapon 1");
        $display("  mouse clicks: one shot per click, right click swaps weapon");

        // Buttons and switches alongside the mouse
        btnU = 1; #(30 * MS);
        check(m_fwd, "btnU not seen with a mouse plugged in");
        btnU = 0;
        sw[15] = 1'b0; #(30 * MS);
        check(m_paused, "flipping sw[15] should pause");
        sw[15] = 1'b1; #(30 * MS);
        check(!m_paused, "flipping sw[15] back should resume");
        $display("  buttons and switches still work with the mouse");

        // Keyboard
        keyboard.send_byte(8'h1D); #(2 * MS);
        check(k_fwd, "W should walk forward");
        keyboard.send_byte(8'hF0); keyboard.send_byte(8'h1D);
        keyboard.send_byte(8'h29); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h29);
        keyboard.send_byte(8'h1E); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h1E);
        keyboard.send_byte(8'h76); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h76);
        #(2 * MS);
        check(!k_fwd && k_shots == 1 && k_weapon == 2'd1 && k_paused, "keyboard Space/2/Esc wrong");
        keyboard.send_byte(8'h4D); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h4D);   // P
        #(2 * MS);
        check(!k_paused, "P should resume");
        $display("  keyboard: W walks, Space shoots, 2 selects weapon, Esc pauses, P resumes");

        if (errors == 0) $display("PASS tb_player_controls");
        else             $display("FAIL tb_player_controls: %0d errors", errors);
        $finish;
    end
endmodule
