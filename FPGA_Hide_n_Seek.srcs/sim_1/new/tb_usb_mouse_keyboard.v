`timescale 1ns / 1ps
// Tests usb_mouse_keyboard (and ps2_host) against PS/2 device models:
//  1. A mouse is detected (RESET -> FA AA 00, then F4 -> FA) and its packets
//     decode to the right movement and buttons, including large negative moves.
//  2. A keyboard is detected (no mouse ID) and WASD, arrow keys, fire, weapon,
//     pause and enter decode correctly; held-key repeats give only one pulse.
//  3. A keyboard that ignores host commands still works once a key is pressed.

module tb_usb_mouse_keyboard;
    localparam integer CLK_HZ = 1_000_000;
    localparam integer MS = 1_000_000;

    reg clk = 1'b0;
    always #500 clk = ~clk;   // 1 MHz
    reg reset = 1'b1;

    tri1 m_clk, m_data, k_clk, k_data, q_clk, q_data, b_clk, b_data;   // tri1 = pulled up

    ps2_device_model #(.IS_MOUSE(1), .RESPONDS(1)) mouse    (.ps2_clk(m_clk), .ps2_data(m_data));
    ps2_device_model #(.IS_MOUSE(0), .RESPONDS(1)) keyboard (.ps2_clk(k_clk), .ps2_data(k_data));
    ps2_device_model #(.IS_MOUSE(0), .RESPONDS(0)) quiet_kb (.ps2_clk(q_clk), .ps2_data(q_data));
    // Like the keyboard on real hardware: sends 0x00 after 0xAA but ignores 0xF4
    ps2_device_model #(.IS_MOUSE(0), .SENDS_ID(1), .ACKS_F4(0)) basys_kb (.ps2_clk(b_clk), .ps2_data(b_data));

    wire m_mouse, m_kbd, m_event, m_l, m_r, m_m;
    wire signed [8:0]m_dx, m_dy;
    usb_mouse_keyboard #(.CLK_HZ(CLK_HZ), .POWERUP_MS(5)) dut_m (
        .clk(clk), .reset(reset), .ps2_clk(m_clk), .ps2_data(m_data),
        .mouse_present(m_mouse), .keyboard_present(m_kbd),
        .mouse_event(m_event), .mouse_dx(m_dx), .mouse_dy(m_dy),
        .mouse_left(m_l), .mouse_right(m_r), .mouse_middle(m_m),
        .key_up(), .key_down(), .key_left(), .key_right(), .key_fire(),
        .key_weapon1(), .key_weapon2(), .key_pause(), .key_enter(), .debug()
    );

    wire k_mouse, k_kbd, k_up, k_down, k_left, k_right, k_fire, k_w1, k_w2, k_pause, k_enter;
    usb_mouse_keyboard #(.CLK_HZ(CLK_HZ), .POWERUP_MS(5)) dut_k (
        .clk(clk), .reset(reset), .ps2_clk(k_clk), .ps2_data(k_data),
        .mouse_present(k_mouse), .keyboard_present(k_kbd),
        .mouse_event(), .mouse_dx(), .mouse_dy(), .mouse_left(), .mouse_right(), .mouse_middle(),
        .key_up(k_up), .key_down(k_down), .key_left(k_left), .key_right(k_right), .key_fire(k_fire),
        .key_weapon1(k_w1), .key_weapon2(k_w2), .key_pause(k_pause), .key_enter(k_enter), .debug()
    );

    wire q_kbd, q_fire;
    usb_mouse_keyboard #(.CLK_HZ(CLK_HZ), .POWERUP_MS(5)) dut_q (
        .clk(clk), .reset(reset), .ps2_clk(q_clk), .ps2_data(q_data),
        .mouse_present(), .keyboard_present(q_kbd),
        .mouse_event(), .mouse_dx(), .mouse_dy(), .mouse_left(), .mouse_right(), .mouse_middle(),
        .key_up(), .key_down(), .key_left(), .key_right(), .key_fire(q_fire),
        .key_weapon1(), .key_weapon2(), .key_pause(), .key_enter(), .debug()
    );

    wire b_mouse, b_kbd, b_up, b_fire;
    usb_mouse_keyboard #(.CLK_HZ(CLK_HZ), .POWERUP_MS(5)) dut_b (
        .clk(clk), .reset(reset), .ps2_clk(b_clk), .ps2_data(b_data),
        .mouse_present(b_mouse), .keyboard_present(b_kbd),
        .mouse_event(), .mouse_dx(), .mouse_dy(), .mouse_left(), .mouse_right(), .mouse_middle(),
        .key_up(b_up), .key_down(), .key_left(), .key_right(), .key_fire(b_fire),
        .key_weapon1(), .key_weapon2(), .key_pause(), .key_enter(), .debug()
    );

    integer events = 0, w1 = 0, w2 = 0, pauses = 0, enters = 0;
    always @(posedge clk) begin
        if (m_event) events = events + 1;
        if (k_w1) w1 = w1 + 1;
        if (k_w2) w2 = w2 + 1;
        if (k_pause) pauses = pauses + 1;
        if (k_enter) enters = enters + 1;
    end

    integer errors = 0;
    task check(input cond, input [8*64-1:0]msg);
        begin if (!cond) begin $display("FAIL %0s", msg); errors = errors + 1; end end
    endtask

    initial begin
        #(1 * MS);
        reset = 1'b0;
        #(150 * MS);

        // 1. Mouse
        check(m_mouse && !m_kbd, "mouse not detected");
        check(mouse.reporting, "mouse never received the enable command");
        mouse.send_mouse_packet(1, 0, 0, 9'sd5, -9'sd3);
        #(2 * MS);
        check(events == 1 && m_dx == 9'sd5 && m_dy == -9'sd3 && m_l && !m_r, "packet 1 decoded wrong");
        mouse.send_mouse_packet(0, 1, 1, -9'sd200, 9'sd120);
        #(2 * MS);
        check(events == 2 && m_dx == -9'sd200 && m_dy == 9'sd120 && !m_l && m_r && m_m, "packet 2 decoded wrong");
        $display("  step 1: mouse detected and enabled; packets decode (dx 5/-200, dy -3/120, buttons)");

        // 2. Keyboard
        check(k_kbd && !k_mouse, "keyboard not detected");
        keyboard.send_byte(8'h1D); #(1 * MS);                                  // W down
        check(k_up, "W not held");
        keyboard.send_byte(8'hF0); keyboard.send_byte(8'h1D); #(1 * MS);       // W up
        check(!k_up, "W not released");
        keyboard.send_byte(8'hE0); keyboard.send_byte(8'h74); #(1 * MS);       // Right arrow down
        check(k_right, "right arrow not held");
        keyboard.send_byte(8'hE0); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h74); #(1 * MS);
        check(!k_right, "right arrow not released");
        keyboard.send_byte(8'h29); #(1 * MS);                                  // Space
        check(k_fire, "space not held");
        keyboard.send_byte(8'hF0); keyboard.send_byte(8'h29);
        keyboard.send_byte(8'h16); keyboard.send_byte(8'h16); keyboard.send_byte(8'h16);  // 1 held (repeats)
        keyboard.send_byte(8'hF0); keyboard.send_byte(8'h16);
        keyboard.send_byte(8'h1E); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h1E);  // 2
        keyboard.send_byte(8'h76); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h76);  // Esc
        keyboard.send_byte(8'h5A); keyboard.send_byte(8'hF0); keyboard.send_byte(8'h5A);  // Enter
        #(2 * MS);
        check(w1 == 1, "key 1 held with repeats should give exactly one pulse");
        check(w2 == 1 && pauses == 1 && enters == 1, "weapon 2 / pause / enter pulses wrong");
        $display("  step 2: keyboard detected; WASD, arrows, fire, 1, 2, Esc, Enter decode; repeats ignored");

        // 3. Keyboard that ignores host commands
        check(!q_kbd, "silent device reported as keyboard before any key");
        quiet_kb.send_byte(8'h29); #(1 * MS);
        check(q_kbd && q_fire, "silent keyboard's keys not decoded");
        $display("  step 3: keyboard that ignores commands still works");

        // 4. Keyboard like the one on real hardware (sends 0x00, ignores 0xF4)
        check(b_kbd && !b_mouse, "Basys3-style keyboard not detected as a keyboard");
        basys_kb.send_byte(8'h1D); #(1 * MS);
        check(b_up, "Basys3-style keyboard: W not decoded");
        basys_kb.send_byte(8'hF0); basys_kb.send_byte(8'h1D);
        basys_kb.send_byte(8'h29); #(1 * MS);
        check(!b_up && b_fire, "Basys3-style keyboard: release/Space not decoded");
        $display("  step 4: keyboard that sends 0x00 and ignores the mouse command is detected and decoded");

        if (errors == 0) $display("PASS tb_usb_mouse_keyboard");
        else             $display("FAIL tb_usb_mouse_keyboard: %0d errors", errors);
        $finish;
    end
endmodule
