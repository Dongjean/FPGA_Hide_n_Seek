`timescale 1ns / 1ps
// Round countdown shown on the 7-seg display

module game_timer #(
    parameter integer CLK_HZ        = 6_250_000,
    parameter integer ROUND_MINUTES = 5,           // 1..9
    parameter integer PENALTY_SEC   = 10           // 10..50, multiple of 10
)(
    input        clk,
    input        reset,
    input        start,         // 1-clock pulse: reload full time
    input        run,           // count only while high
    input        penalty,       // 1-clock pulse: -PENALTY_SEC
    output reg [3:0] min_digit  = ROUND_MINUTES,
    output reg [2:0] sec_tens   = 3'd0,
    output reg [3:0] sec_ones   = 4'd0,
    output reg [3:0] cs_tens    = 4'd0,
    output reg [3:0] cs_ones    = 4'd0,
    output reg       time_up    = 1'b0,
    output           time_up_pulse,
    output [8:0]     game_seconds_left,    // rounded up, for the HUD
    output           flash_off,            // dark half of the last 10 s flash
    output reg [6:0] seg        = 7'h7F,
    output reg       dp         = 1'b1,
    output reg [3:0] an         = 4'hF
);

    localparam [2:0] PEN_TENS = PENALTY_SEC / 10;

    localparam integer CS_CLKS      = (CLK_HZ / 100  < 1) ? 1 : CLK_HZ / 100;
    localparam integer BLINK_CLKS   = (CLK_HZ / 8    < 1) ? 1 : CLK_HZ / 8;
    localparam integer REFRESH_CLKS = (CLK_HZ / 1000 < 1) ? 1 : CLK_HZ / 1000;

    localparam integer CS_W      = $clog2(CS_CLKS + 1);
    localparam integer BLINK_W   = $clog2(BLINK_CLKS + 1);
    localparam integer REFRESH_W = $clog2(REFRESH_CLKS + 1);

    reg [CS_W-1:0]      cs_count = 0;
    reg [BLINK_W-1:0]   blink_count = 0;
    reg [REFRESH_W-1:0] refresh_count = 0;
    reg        blink_on = 1'b1;
    reg [1:0]  digit_sel = 2'd0;

    wire cs_tick = (cs_count == CS_CLKS - 1);

    always @(posedge clk) begin
        if (reset || start) begin
            cs_count <= 0;
        end else if (run && !time_up) begin
            cs_count <= cs_tick ? 0 : cs_count + 1'b1;
        end

        if (blink_count == BLINK_CLKS - 1) begin
            blink_count <= 0;
            blink_on    <= ~blink_on;
        end else begin
            blink_count <= blink_count + 1'b1;
        end

        if (refresh_count == REFRESH_CLKS - 1) begin
            refresh_count <= 0;
            digit_sel     <= digit_sel + 2'd1;
        end else begin
            refresh_count <= refresh_count + 1'b1;
        end
    end

    wire at_one_cs = (min_digit == 4'd0) && (sec_tens == 3'd0) && (sec_ones == 4'd0) &&
                     (cs_tens == 4'd0) && (cs_ones == 4'd1);

    // Countdown, digits borrow like a clock
    always @(posedge clk) begin
        if (reset || start) begin
            min_digit <= ROUND_MINUTES;
            sec_tens  <= 3'd0;
            sec_ones  <= 4'd0;
            cs_tens   <= 4'd0;
            cs_ones   <= 4'd0;
            time_up   <= 1'b0;
        end else if (!time_up) begin
            if (penalty) begin
                // The penalty is PEN_TENS on the tens digit
                if (min_digit == 4'd0 &&
                    (sec_tens < PEN_TENS || (sec_tens == PEN_TENS && sec_ones == 4'd0 && cs_tens == 4'd0 && cs_ones == 4'd0))) begin
                    sec_tens <= 3'd0; sec_ones <= 4'd0; cs_tens <= 4'd0; cs_ones <= 4'd0;
                    time_up  <= 1'b1;
                end else if (sec_tens >= PEN_TENS) begin
                    sec_tens <= sec_tens - PEN_TENS;
                end else begin
                    sec_tens  <= sec_tens + (3'd6 - PEN_TENS);
                    min_digit <= min_digit - 4'd1;
                end
            end else if (run && cs_tick) begin
                if (at_one_cs) begin
                    cs_ones <= 4'd0;
                    time_up <= 1'b1;
                end else if (cs_ones != 4'd0) begin
                    cs_ones <= cs_ones - 4'd1;
                end else begin
                    cs_ones <= 4'd9;
                    if (cs_tens != 4'd0) begin
                        cs_tens <= cs_tens - 4'd1;
                    end else begin
                        cs_tens <= 4'd9;
                        if (sec_ones != 4'd0) begin
                            sec_ones <= sec_ones - 4'd1;
                        end else begin
                            sec_ones <= 4'd9;
                            if (sec_tens != 3'd0) begin
                                sec_tens <= sec_tens - 3'd1;
                            end else begin
                                sec_tens  <= 3'd5;
                                min_digit <= min_digit - 4'd1;
                            end
                        end
                    end
                end
            end
        end
    end

    // Whole seconds left, plus one while a fraction remains
    wire [8:0] min_x60 = ({5'b00000, min_digit} << 6) - ({5'b00000, min_digit} << 2);
    wire [8:0] sec_x10 = ({6'b000000, sec_tens} << 3) + ({6'b000000, sec_tens} << 1);
    wire       frac    = (cs_tens != 4'd0) || (cs_ones != 4'd0);
    assign game_seconds_left = min_x60 + sec_x10 + {5'b00000, sec_ones} + {8'd0, frac};

    reg time_up_d = 1'b0;
    always @(posedge clk) time_up_d <= time_up;
    assign time_up_pulse = time_up && !time_up_d;

    // 7-seg: M.SS above a minute, SS.cc below, an[3] is the leftmost digit
    wire final_ten  = (min_digit == 4'd0) && (sec_tens == 3'd0) && !time_up;
    assign flash_off = final_ten && !blink_on;
    wire minute_mode = (min_digit != 4'd0);

    reg [3:0] value;      // 0..9, 10 = blank
    reg       point;

    always @(*) begin
        value = 4'd10;
        point = 1'b0;
        if (!flash_off) begin
            if (minute_mode) begin
                case (digit_sel)
                    2'd3: begin value = min_digit;        point = 1'b1; end
                    2'd2: begin value = {1'b0, sec_tens}; end
                    2'd1: begin value = sec_ones;         end
                    default: ;
                endcase
            end else begin
                case (digit_sel)
                    2'd3: begin value = {1'b0, sec_tens}; end
                    2'd2: begin value = sec_ones;         point = 1'b1; end
                    2'd1: begin value = cs_tens;          end
                    default: begin value = cs_ones;       end
                endcase
            end
        end
    end

    always @(posedge clk) begin
        an <= ~(4'b0001 << digit_sel);
        dp <= ~point;
        case (value)
            4'd0: seg <= 7'b1000000;
            4'd1: seg <= 7'b1111001;
            4'd2: seg <= 7'b0100100;
            4'd3: seg <= 7'b0110000;
            4'd4: seg <= 7'b0011001;
            4'd5: seg <= 7'b0010010;
            4'd6: seg <= 7'b0000010;
            4'd7: seg <= 7'b1111000;
            4'd8: seg <= 7'b0000000;
            4'd9: seg <= 7'b0010000;
            default: seg <= 7'b1111111;
        endcase
    end

endmodule
