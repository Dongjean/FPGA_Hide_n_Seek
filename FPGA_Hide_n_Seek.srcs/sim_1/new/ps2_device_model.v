`timescale 1ns / 1ps
// Simulation model of a PS/2 mouse or keyboard (not for synthesis).
// IS_MOUSE = 1: answers RESET with FA, AA, 00 and enables reporting on F4.
// IS_MOUSE = 0: answers RESET with FA, AA (a keyboard).
// RESPONDS = 0: never clocks in host commands (a device that ignores the host).
// SENDS_ID = 1, ACKS_F4 = 0 on a keyboard: behaves like the keyboard seen on real
//   Basys3 hardware (sends 0x00 after 0xAA, never acknowledges 0xF4).
// The clock runs at about 12.5 kHz (40 us low, 40 us high), like a real device.

module ps2_device_model
#(
    parameter IS_MOUSE = 1,
    parameter RESPONDS = 1,
    parameter SENDS_ID = IS_MOUSE,    // sends 0x00 after 0xAA
    parameter ACKS_F4  = 1            // replies 0xFA to the enable command 0xF4
)
(
    inout ps2_clk,
    inout ps2_data
);
    localparam integer US = 1000;

    reg clk_low = 1'b0;
    reg data_low = 1'b0;
    assign ps2_clk  = clk_low  ? 1'b0 : 1'bz;
    assign ps2_data = data_low ? 1'b0 : 1'bz;

    reg sending = 1'b0;
    reg reporting = 1'b0;
    reg [7:0]last_command = 8'h00;
    integer commands = 0;

    // Send one byte to the host: start, 8 data bits, odd parity, stop
    task send_byte(input [7:0]b);
        reg [10:0]frame;
        integer i;
        begin
            wait (!sending);
            sending = 1'b1;
            frame = {1'b1, ~^b, b, 1'b0};
            for (i = 0; i < 11; i = i + 1) begin
                data_low = ~frame[i];
                #(20 * US);
                clk_low = 1'b1;          // host samples on this falling edge
                #(40 * US);
                clk_low = 1'b0;
                #(20 * US);
            end
            data_low = 1'b0;
            #(100 * US);
            sending = 1'b0;
        end
    endtask

    task send_mouse_packet(input l, input r, input m, input signed [8:0]dx, input signed [8:0]dy);
        begin
            send_byte({2'b00, dy[8], dx[8], 1'b1, m, r, l});
            send_byte(dx[7:0]);
            send_byte(dy[7:0]);
        end
    endtask

    // Watch for the host asking to send: it holds the clock low, then pulls data low
    // and releases the clock.
    reg [9:0]bits;
    integer k;
    initial begin
        forever begin
            // The host holds the clock low for at least 100 us, so checking the level
            // (not the edge) still catches a request made while we were busy.
            wait (ps2_clk === 1'b0 && !clk_low && !sending);
            begin
                wait (ps2_clk === 1'b1);
                #(50 * US);
                if (ps2_data === 1'b0 && RESPONDS) begin
                    sending = 1'b1;
                    for (k = 0; k < 10; k = k + 1) begin
                        clk_low = 1'b1;
                        #(40 * US);
                        clk_low = 1'b0;      // host has set the next bit while clock was low
                        bits[k] = ps2_data;
                        #(40 * US);
                    end
                    data_low = 1'b1;          // acknowledge
                    clk_low  = 1'b1;
                    #(40 * US);
                    clk_low  = 1'b0;
                    #(20 * US);
                    data_low = 1'b0;
                    #(100 * US);
                    sending = 1'b0;

                    last_command = bits[7:0];
                    commands = commands + 1;
                    if (^bits[8:0] !== 1'b1 || bits[9] !== 1'b1)
                        $display("MODEL: bad parity or stop bit from host (%b)", bits);

                    // Reply
                    if (bits[7:0] == 8'hFF) begin
                        reporting = 1'b0;
                        #(1000 * US); send_byte(8'hFA);
                        #(3000 * US); send_byte(8'hAA);
                        if (SENDS_ID) begin #(500 * US); send_byte(8'h00); end
                    end else if (bits[7:0] == 8'hF4 && !ACKS_F4) begin
                        // clocks the command in, but never replies
                    end else begin
                        if (bits[7:0] == 8'hF4) reporting = 1'b1;
                        #(1000 * US); send_byte(8'hFA);
                    end
                end
            end
        end
    end
endmodule
