`timescale 1ns / 1ps
// Finds out whether a mouse or a keyboard is plugged into the Basys3 USB port,
// sets it up, and decodes what it sends.
//
// Detection: after power-up we send RESET (0xFF). Both devices answer ACK (0xFA)
// then self-test passed (0xAA). A mouse also sends its ID (0x00) and must then be
// told to start reporting movement (0xF4), which it acknowledges with 0xFA.
// A keyboard either sends no ID, or (as seen on real Basys3 hardware) sends 0x00
// too but never acknowledges 0xF4 - either way it ends up in keyboard mode.
// If nothing answers, we listen for keyboard scan codes anyway (in case the device
// ignores commands) and try the reset again every second, so a mouse plugged in
// later is still found. keyboard_present goes high once a key is actually pressed.
//
// Mouse packet (3 bytes): byte 0 = {Y overflow, X overflow, Y sign, X sign, 1, middle,
//   right, left}, byte 1 = X movement, byte 2 = Y movement (9-bit two's complement).
//
// Keyboard (scan code set 2): a key sends its make code when pressed; on release it
// sends 0xF0 then the code. Arrow keys are prefixed with 0xE0.
//   W / Up arrow = up       S / Down arrow = down
//   A / Left arrow = left   D / Right arrow = right
//   Space = fire   1 / 2 = weapon   Esc or P = pause   Enter = confirm

module usb_mouse_keyboard
#(
    parameter integer CLK_HZ     = 6_250_000,
    parameter integer POWERUP_MS = 500        // time for the USB chip to start up
)
(
    input clk,
    input reset,
    inout ps2_clk,
    inout ps2_data,

    output reg mouse_present = 1'b0,
    output reg keyboard_present = 1'b0,

    // Mouse
    output reg mouse_event = 1'b0,            // pulse: new movement/buttons below
    output reg signed [8:0]mouse_dx = 9'sd0,  // right is positive
    output reg signed [8:0]mouse_dy = 9'sd0,  // up is positive
    output reg mouse_left = 1'b0,
    output reg mouse_right = 1'b0,
    output reg mouse_middle = 1'b0,

    // Keyboard: held keys (levels)
    output key_up,
    output key_down,
    output key_left,
    output key_right,
    output key_fire,
    // Keyboard: one pulse per press
    output reg key_weapon1 = 1'b0,
    output reg key_weapon2 = 1'b0,
    output reg key_pause = 1'b0,
    output reg key_enter = 1'b0,

    // Debugging: {state, bytes received (mod 16), last byte received}
    output [15:0]debug
);
    localparam integer CLKS_PER_MS   = CLK_HZ / 1000;
    localparam integer POWERUP_CLKS  = POWERUP_MS * CLKS_PER_MS;
    localparam integer ACK_WAIT_CLKS = 100 * CLKS_PER_MS;     // 0xFA within 100 ms
    localparam integer BAT_WAIT_CLKS = 1500 * CLKS_PER_MS;    // self test within 1.5 s
    localparam integer ID_WAIT_CLKS  = 50 * CLKS_PER_MS;      // mouse ID follows quickly
    localparam integer RETRY_CLKS    = 1000 * CLKS_PER_MS;
    localparam integer PKT_GAP_CLKS  = 20 * CLKS_PER_MS;      // bytes of a packet are close together

    localparam [7:0]CMD_RESET  = 8'hFF;
    localparam [7:0]CMD_ENABLE = 8'hF4;
    localparam [7:0]RSP_ACK    = 8'hFA;
    localparam [7:0]RSP_BAT_OK = 8'hAA;
    localparam [7:0]MOUSE_ID   = 8'h00;

    localparam [3:0]S_POWERUP   = 4'd0;
    localparam [3:0]S_SEND_RST  = 4'd1;
    localparam [3:0]S_WAIT_ACK  = 4'd2;
    localparam [3:0]S_WAIT_BAT  = 4'd3;
    localparam [3:0]S_WAIT_ID   = 4'd4;
    localparam [3:0]S_SEND_EN   = 4'd5;
    localparam [3:0]S_WAIT_ACK2 = 4'd6;
    localparam [3:0]S_MOUSE     = 4'd7;
    localparam [3:0]S_KEYBOARD  = 4'd8;

    reg [7:0]tx_data = 8'd0;
    reg tx_start = 1'b0;
    wire tx_busy, tx_done, tx_error;
    wire [7:0]rx_data;
    wire rx_valid, rx_error;

    ps2_host #(.CLK_HZ(CLK_HZ)) port (
        .clk      (clk),
        .reset    (reset),
        .ps2_clk  (ps2_clk),
        .ps2_data (ps2_data),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx_busy  (tx_busy),
        .tx_done  (tx_done),
        .tx_error (tx_error),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .rx_error (rx_error)
    );

    reg [3:0]state = S_POWERUP;
    reg [3:0]debug_count = 4'd0;
    reg [7:0]debug_byte = 8'd0;
    assign debug = {state, debug_count, debug_byte};
    always @(posedge clk) begin
        if (rx_valid) begin
            debug_count <= debug_count + 4'd1;
            debug_byte  <= rx_data;
        end
    end
    reg [31:0]timer = 32'd0;
    reg sent = 1'b0;                 // command handed to ps2_host in this state

    // Mouse packet assembly
    reg [1:0]byte_index = 2'd0;
    reg [7:0]byte0;
    reg [7:0]byte1;
    reg [31:0]gap_timer = 32'd0;

    // Keyboard decoding
    reg got_break = 1'b0;            // previous byte was 0xF0
    reg w_held = 1'b0, a_held = 1'b0, s_held = 1'b0, d_held = 1'b0;
    reg up_held = 1'b0, down_held = 1'b0, left_held = 1'b0, right_held = 1'b0;
    reg space_held = 1'b0;
    reg one_held = 1'b0, two_held = 1'b0, esc_held = 1'b0, p_held = 1'b0, enter_held = 1'b0;

    assign key_up    = w_held || up_held;
    assign key_down  = s_held || down_held;
    assign key_left  = a_held || left_held;
    assign key_right = d_held || right_held;
    assign key_fire  = space_held;

    always @(posedge clk) begin
        tx_start    <= 1'b0;
        mouse_event <= 1'b0;
        key_weapon1 <= 1'b0;
        key_weapon2 <= 1'b0;
        key_pause   <= 1'b0;
        key_enter   <= 1'b0;

        if (reset) begin
            state            <= S_POWERUP;
            timer            <= 32'd0;
            sent             <= 1'b0;
            mouse_present    <= 1'b0;
            keyboard_present <= 1'b0;
            byte_index       <= 2'd0;
            got_break        <= 1'b0;
            {w_held, a_held, s_held, d_held, up_held, down_held, left_held, right_held} <= 8'd0;
            {space_held, one_held, two_held, esc_held, p_held, enter_held} <= 6'd0;
            {mouse_left, mouse_right, mouse_middle} <= 3'd0;
        end else begin
            timer <= timer + 32'd1;

            case (state)
                S_POWERUP: begin
                    if (timer >= POWERUP_CLKS) begin
                        timer <= 32'd0;
                        sent  <= 1'b0;
                        state <= S_SEND_RST;
                    end
                end

                // Send RESET and wait for ACK, self-test passed, then maybe the mouse ID
                S_SEND_RST: begin
                    mouse_present    <= 1'b0;
                    keyboard_present <= 1'b0;
                    if (!sent && !tx_busy) begin
                        tx_data  <= CMD_RESET;
                        tx_start <= 1'b1;
                        sent     <= 1'b1;
                    end else if (tx_done) begin
                        timer <= 32'd0;
                        state <= S_WAIT_ACK;
                    end else if (tx_error) begin
                        timer     <= 32'd0;
                        got_break <= 1'b0;
                        state     <= S_KEYBOARD;   // no answer: just listen for keys
                    end
                end

                S_WAIT_ACK: begin
                    if (rx_valid && rx_data == RSP_ACK) begin
                        timer <= 32'd0;
                        state <= S_WAIT_BAT;
                    end else if (timer >= ACK_WAIT_CLKS) begin
                        timer     <= 32'd0;
                        got_break <= 1'b0;
                        state     <= S_KEYBOARD;
                    end
                end

                S_WAIT_BAT: begin
                    if (rx_valid && rx_data == RSP_BAT_OK) begin
                        timer <= 32'd0;
                        state <= S_WAIT_ID;
                    end else if (timer >= BAT_WAIT_CLKS) begin
                        timer     <= 32'd0;
                        got_break <= 1'b0;
                        state     <= S_KEYBOARD;
                    end
                end

                S_WAIT_ID: begin
                    if (rx_valid && rx_data == MOUSE_ID) begin
                        timer <= 32'd0;
                        sent  <= 1'b0;
                        state <= S_SEND_EN;     // it's a mouse
                    end else if (timer >= ID_WAIT_CLKS) begin
                        keyboard_present <= 1'b1;
                        got_break        <= 1'b0;
                        state            <= S_KEYBOARD;   // no ID: it's a keyboard
                    end
                end

                // Mouse: enable movement reporting
                S_SEND_EN: begin
                    if (!sent && !tx_busy) begin
                        tx_data  <= CMD_ENABLE;
                        tx_start <= 1'b1;
                        sent     <= 1'b1;
                    end else if (tx_done) begin
                        timer <= 32'd0;
                        state <= S_WAIT_ACK2;
                    end else if (tx_error) begin
                        // Something answered the reset but refuses the mouse
                        // command: it is a keyboard
                        timer            <= 32'd0;
                        keyboard_present <= 1'b1;
                        got_break        <= 1'b0;
                        state            <= S_KEYBOARD;
                    end
                end

                S_WAIT_ACK2: begin
                    if (rx_valid && rx_data == RSP_ACK) begin
                        mouse_present <= 1'b1;
                        byte_index    <= 2'd0;
                        state         <= S_MOUSE;
                    end else if (timer >= ACK_WAIT_CLKS) begin
                        // Some keyboards (and the Basys3 USB chip with a keyboard
                        // attached) also send 0x00 after 0xAA, but never acknowledge
                        // the mouse's enable command. So no ACK here means keyboard.
                        timer            <= 32'd0;
                        keyboard_present <= 1'b1;
                        got_break        <= 1'b0;
                        state            <= S_KEYBOARD;
                    end
                end

                // Mouse running: assemble 3-byte packets
                S_MOUSE: begin
                    if (byte_index != 2'd0) begin
                        if (gap_timer >= PKT_GAP_CLKS) begin
                            // The packet stopped after byte 0. A lone 0xAA means a
                            // keyboard was plugged in instead of the mouse.
                            byte_index <= 2'd0;
                            if (byte_index == 2'd1 && byte0 == RSP_BAT_OK) begin
                                mouse_present    <= 1'b0;
                                keyboard_present <= 1'b1;
                                got_break        <= 1'b0;
                                state            <= S_KEYBOARD;
                            end
                        end else begin
                            gap_timer <= gap_timer + 32'd1;
                        end
                    end

                    if (rx_valid) begin
                        gap_timer <= 32'd0;
                        case (byte_index)
                            2'd0: begin
                                if (rx_data[3]) begin   // bit 3 of byte 0 is always 1
                                    byte0      <= rx_data;
                                    byte_index <= 2'd1;
                                end
                            end
                            2'd1: begin
                                if (byte0 == RSP_BAT_OK && rx_data == MOUSE_ID) begin
                                    // 0xAA 0x00: a mouse was unplugged and plugged back in
                                    byte_index <= 2'd0;
                                    timer      <= 32'd0;
                                    sent       <= 1'b0;
                                    state      <= S_SEND_EN;
                                end else begin
                                    byte1      <= rx_data;
                                    byte_index <= 2'd2;
                                end
                            end
                            default: begin
                                mouse_dx     <= {byte0[4], byte1};
                                mouse_dy     <= {byte0[5], rx_data};
                                mouse_left   <= byte0[0];
                                mouse_right  <= byte0[1];
                                mouse_middle <= byte0[2];
                                mouse_event  <= 1'b1;
                                byte_index   <= 2'd0;
                            end
                        endcase
                    end
                end

                // Keyboard running (or listening because nothing answered):
                // track make and break codes
                S_KEYBOARD: begin
                    if (!keyboard_present && timer >= RETRY_CLKS) begin
                        timer <= 32'd0;
                        sent  <= 1'b0;
                        state <= S_SEND_RST;   // try again in case a mouse was plugged in
                    end

                    if (rx_valid) begin
                        if (rx_data == 8'hF0) begin
                            got_break <= 1'b1;
                        end else if (rx_data == 8'hE0) begin
                            // extended prefix: arrow keys share codes with the keypad,
                            // and both are treated the same here
                        end else if (rx_data == RSP_BAT_OK) begin
                            // a device was plugged in: find out what it is
                            timer <= 32'd0;
                            keyboard_present <= 1'b0;
                            state <= S_WAIT_ID;
                        end else begin
                            got_break        <= 1'b0;
                            keyboard_present <= 1'b1;
                            case (rx_data)
                                8'h1D: w_held     <= !got_break;
                                8'h1C: a_held     <= !got_break;
                                8'h1B: s_held     <= !got_break;
                                8'h23: d_held     <= !got_break;
                                8'h75: up_held    <= !got_break;
                                8'h72: down_held  <= !got_break;
                                8'h6B: left_held  <= !got_break;
                                8'h74: right_held <= !got_break;
                                8'h29: space_held <= !got_break;
                                8'h16: begin
                                    if (!got_break && !one_held) key_weapon1 <= 1'b1;
                                    one_held <= !got_break;
                                end
                                8'h1E: begin
                                    if (!got_break && !two_held) key_weapon2 <= 1'b1;
                                    two_held <= !got_break;
                                end
                                8'h76: begin
                                    if (!got_break && !esc_held) key_pause <= 1'b1;
                                    esc_held <= !got_break;
                                end
                                8'h4D: begin
                                    if (!got_break && !p_held) key_pause <= 1'b1;
                                    p_held <= !got_break;
                                end
                                8'h5A: begin
                                    if (!got_break && !enter_held) key_enter <= 1'b1;
                                    enter_held <= !got_break;
                                end
                                default: ;
                            endcase
                        end
                    end
                end

                default: state <= S_POWERUP;
            endcase
        end
    end
endmodule
