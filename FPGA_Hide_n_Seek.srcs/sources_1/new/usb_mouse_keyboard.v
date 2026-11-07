`timescale 1ns / 1ps

//USB mouse / keyboard
//Detects which device is plugged in, sets it up, and decodes its packets or key codes.
module usb_mouse_keyboard
#(
    parameter integer CLK_HZ     = 6_250_000,
    parameter integer POWERUP_MS = 500
)
(
    input clk,
    input reset,
    inout ps2_clk,
    inout ps2_data,

    output reg mouse_present = 1'b0,
    output reg keyboard_present = 1'b0,

    output reg mouse_event = 1'b0,
    output reg signed [8:0]mouse_dx = 9'sd0,
    output reg signed [8:0]mouse_dy = 9'sd0,
    output reg mouse_left = 1'b0,
    output reg mouse_right = 1'b0,
    output reg mouse_middle = 1'b0,

    output key_up,
    output key_down,
    output key_left,
    output key_right,
    output key_fire,
    output reg key_weapon1 = 1'b0,
    output reg key_weapon2 = 1'b0,
    output reg key_pause = 1'b0,
    output reg key_enter = 1'b0,

    output [15:0]debug
);

    //Timing
    localparam integer CLKS_PER_MS   = CLK_HZ / 1000;
    localparam integer POWERUP_CLKS  = POWERUP_MS * CLKS_PER_MS;
    localparam integer ACK_WAIT_CLKS = 100 * CLKS_PER_MS;
    localparam integer BAT_WAIT_CLKS = 1500 * CLKS_PER_MS;
    localparam integer ID_WAIT_CLKS  = 50 * CLKS_PER_MS;
    localparam integer RETRY_CLKS    = 1000 * CLKS_PER_MS;
    localparam integer PKT_GAP_CLKS  = 20 * CLKS_PER_MS;

    //PS/2 commands and replies
    localparam [7:0]CMD_RESET  = 8'hFF;
    localparam [7:0]CMD_ENABLE = 8'hF4;
    localparam [7:0]RSP_ACK    = 8'hFA;
    localparam [7:0]RSP_BAT_OK = 8'hAA;
    localparam [7:0]MOUSE_ID   = 8'h00;

    //Detection states
    localparam [3:0]S_POWERUP   = 4'd0;
    localparam [3:0]S_SEND_RST  = 4'd1;
    localparam [3:0]S_WAIT_ACK  = 4'd2;
    localparam [3:0]S_WAIT_BAT  = 4'd3;
    localparam [3:0]S_WAIT_ID   = 4'd4;
    localparam [3:0]S_SEND_EN   = 4'd5;
    localparam [3:0]S_WAIT_ACK2 = 4'd6;
    localparam [3:0]S_MOUSE     = 4'd7;
    localparam [3:0]S_KEYBOARD  = 4'd8;

    //PS/2 port
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

    //Debug value for the 7-segment display
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

    //Registers
    reg [31:0]timer = 32'd0;
    reg sent = 1'b0;

    reg [1:0]byte_index = 2'd0;
    reg [7:0]byte0;
    reg [7:0]byte1;
    reg [31:0]gap_timer = 32'd0;

    reg got_break = 1'b0;
    reg w_held = 1'b0, a_held = 1'b0, s_held = 1'b0, d_held = 1'b0;
    reg up_held = 1'b0, down_held = 1'b0, left_held = 1'b0, right_held = 1'b0;
    reg space_held = 1'b0;
    reg one_held = 1'b0, two_held = 1'b0, esc_held = 1'b0, p_held = 1'b0, enter_held = 1'b0;

    //Held keys
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

                //Detection FSM
                //POWERUP -> reset the device -> ACK -> self-test -> ID (mouse) or keyboard.
                S_POWERUP: begin
                    if (timer >= POWERUP_CLKS) begin
                        timer <= 32'd0;
                        sent  <= 1'b0;
                        state <= S_SEND_RST;
                    end
                end

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
                        state     <= S_KEYBOARD;
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
                        state <= S_SEND_EN;
                    end else if (timer >= ID_WAIT_CLKS) begin
                        keyboard_present <= 1'b1;
                        got_break        <= 1'b0;
                        state            <= S_KEYBOARD;
                    end
                end

                S_SEND_EN: begin
                    if (!sent && !tx_busy) begin
                        tx_data  <= CMD_ENABLE;
                        tx_start <= 1'b1;
                        sent     <= 1'b1;
                    end else if (tx_done) begin
                        timer <= 32'd0;
                        state <= S_WAIT_ACK2;
                    end else if (tx_error) begin
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
                        timer            <= 32'd0;
                        keyboard_present <= 1'b1;
                        got_break        <= 1'b0;
                        state            <= S_KEYBOARD;
                    end
                end

                //Mouse: decode 3-byte packets
                S_MOUSE: begin
                    if (byte_index != 2'd0) begin
                        if (gap_timer >= PKT_GAP_CLKS) begin
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
                                if (rx_data[3]) begin
                                    byte0      <= rx_data;
                                    byte_index <= 2'd1;
                                end
                            end
                            2'd1: begin
                                if (byte0 == RSP_BAT_OK && rx_data == MOUSE_ID) begin
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

                //Keyboard: decode make and break codes
                S_KEYBOARD: begin
                    if (!keyboard_present && timer >= RETRY_CLKS) begin
                        timer <= 32'd0;
                        sent  <= 1'b0;
                        state <= S_SEND_RST;
                    end

                    if (rx_valid) begin
                        if (rx_data == 8'hF0) begin
                            got_break <= 1'b1;
                        end else if (rx_data == 8'hE0) begin
                        end else if (rx_data == RSP_BAT_OK) begin
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
