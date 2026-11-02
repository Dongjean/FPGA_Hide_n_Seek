`timescale 1ns / 1ps
// Tests the opponent_select wrapper:
//  Solo mode (board S): picking Seeker and pressing ready starts the game at once,
//    the bot becomes the Hider, appears at its spawn when play begins, moves,
//    takes damage from this player's hits, and the Radio Pinger reveal works.
//    Restart returns to the lobby.
//  Multiplayer (boards A and B): the same wrapper hands over to multiplayer_link, and the
//    start-up handshake and an event still work through it.

module tb_opponent_select;
    localparam integer CLK_HZ = 100_000;
    localparam integer BAUD   = 5_000;
    localparam integer MS     = 1_000_000;

    reg clk = 1'b0;
    always #5000 clk = ~clk;
    reg frame_tick = 1'b0;
    initial forever begin
        #(16 * MS);
        @(negedge clk); frame_tick = 1'b1; @(negedge clk); frame_tick = 1'b0;
    end

    localparam [99:0]MAP = {
        10'b1111111111, 10'b1010001001, 10'b1010001001, 10'b1010011001, 10'b1010010001,
        10'b1000000001, 10'b1100011001, 10'b1000010001, 10'b1000010001, 10'b1111111111
    };

    task wait_ms(input integer n);
        integer w;
        begin for (w = 0; w < n; w = w + 1) #(MS); end
    endtask

    reg reset = 1'b1;

    // ---------------- Solo board S ----------------
    reg [1:0]s_role = 2'd0;
    reg s_ready = 1'b0, s_playing = 1'b0, s_hit = 1'b0, s_ping = 1'b0, s_restart = 1'b0;
    wire [1:0]s_peer_role;
    wire s_in_game, s_start, s_reveal, s_restart_out;
    wire signed [15:0]s_px, s_py;
    wire [7:0]s_phealth;
    wire [15:0]s_seed;

    opponent_select #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) solo (
        .clk(clk), .reset(reset), .solo_mode(1'b1), .difficulty(2'd2),
        .link_rx(1'b1), .link_tx(),
        .frame_tick(frame_tick), .playing(s_playing), .map_bits(MAP),
        .bot_spawn_x(16'sd2176), .bot_spawn_y(16'sd2176),       // cell (8,8)
        .capsule_valid(4'd0), .capsule_cells(32'd0),
        .my_role(s_role), .my_ready(s_ready),
        .peer_role(s_peer_role), .peer_ready(), .role_conflict(), .in_game(s_in_game),
        .start_game(s_start), .game_seed(s_seed),
        .my_x(16'sd384), .my_y(16'sd384), .my_dir(8'd0), .my_health(8'd100),
        .my_paused(1'b0), .my_frozen(1'b0), .my_stim(1'b0),
        .peer_x(s_px), .peer_y(s_py), .peer_dir(), .peer_health(s_phealth),
        .peer_paused(), .peer_frozen(), .peer_stim(), .link_up(), .game_paused(),
        .ev_hit(s_hit), .hit_damage(8'd25), .ev_freeze(1'b0), .ev_ping(s_ping), .ev_stim(1'b0),
        .ev_capsule(1'b0), .capsule_id(8'd0), .ev_restart(s_restart),
        .got_hit(), .got_hit_damage(), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .restart_game(s_restart_out),
        .reveal_active(s_reveal), .reveal_x(), .reveal_y()
    );

    // ---------------- Multiplayer boards A and B ----------------
    wire a_tx, b_tx;
    reg a_ready = 1'b0, b_ready = 1'b0, a_hit = 1'b0;
    wire a_start, b_start, b_got_hit;
    wire [15:0]a_seed, b_seed;
    wire [7:0]b_dmg;

    opponent_select #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) board_a (
        .clk(clk), .reset(reset), .solo_mode(1'b0), .difficulty(2'd0),
        .link_rx(b_tx), .link_tx(a_tx),
        .frame_tick(frame_tick), .playing(1'b0), .map_bits(MAP),
        .bot_spawn_x(16'sd0), .bot_spawn_y(16'sd0), .capsule_valid(4'd0), .capsule_cells(32'd0),
        .my_role(2'd2), .my_ready(a_ready),
        .peer_role(), .peer_ready(), .role_conflict(), .in_game(), .start_game(a_start), .game_seed(a_seed),
        .my_x(16'sd0), .my_y(16'sd0), .my_dir(8'd0), .my_health(8'd100),
        .my_paused(1'b0), .my_frozen(1'b0), .my_stim(1'b0),
        .peer_x(), .peer_y(), .peer_dir(), .peer_health(),
        .peer_paused(), .peer_frozen(), .peer_stim(), .link_up(), .game_paused(),
        .ev_hit(a_hit), .hit_damage(8'd40), .ev_freeze(1'b0), .ev_ping(1'b0), .ev_stim(1'b0),
        .ev_capsule(1'b0), .capsule_id(8'd0), .ev_restart(1'b0),
        .got_hit(), .got_hit_damage(), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .restart_game(),
        .reveal_active(), .reveal_x(), .reveal_y()
    );
    opponent_select #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) board_b (
        .clk(clk), .reset(reset), .solo_mode(1'b0), .difficulty(2'd0),
        .link_rx(a_tx), .link_tx(b_tx),
        .frame_tick(frame_tick), .playing(1'b0), .map_bits(MAP),
        .bot_spawn_x(16'sd0), .bot_spawn_y(16'sd0), .capsule_valid(4'd0), .capsule_cells(32'd0),
        .my_role(2'd1), .my_ready(b_ready),
        .peer_role(), .peer_ready(), .role_conflict(), .in_game(), .start_game(b_start), .game_seed(b_seed),
        .my_x(16'sd0), .my_y(16'sd0), .my_dir(8'd0), .my_health(8'd100),
        .my_paused(1'b0), .my_frozen(1'b0), .my_stim(1'b0),
        .peer_x(), .peer_y(), .peer_dir(), .peer_health(),
        .peer_paused(), .peer_frozen(), .peer_stim(), .link_up(), .game_paused(),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0), .ev_stim(1'b0),
        .ev_capsule(1'b0), .capsule_id(8'd0), .ev_restart(1'b0),
        .got_hit(b_got_hit), .got_hit_damage(b_dmg), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .restart_game(),
        .reveal_active(), .reveal_x(), .reveal_y()
    );

    integer s_starts = 0, a_starts = 0, b_starts = 0, b_hits = 0, s_restarts = 0;
    reg [7:0]b_last_dmg;
    always @(posedge clk) begin
        if (s_start) s_starts = s_starts + 1;
        if (a_start) a_starts = a_starts + 1;
        if (b_start) b_starts = b_starts + 1;
        if (b_got_hit) begin b_hits = b_hits + 1; b_last_dmg = b_dmg; end
        if (s_restart_out) s_restarts = s_restarts + 1;
    end

    integer errors = 0;
    reg signed [15:0]x0, y0;
    task check(input cond, input [8*64-1:0]msg);
        begin if (!cond) begin $display("FAIL %0s", msg); errors = errors + 1; end end
    endtask

    initial begin
        wait_ms(1);
        reset = 1'b0;
        wait_ms(50);

        // ---- Solo ----
        s_role = 2'd2; s_ready = 1'b1;
        wait_ms(5);
        check(s_starts == 1 && s_in_game && s_peer_role == 2'd1 && s_seed != 16'd0,
              "solo start: game should start at once with the bot as Hider");
        s_playing = 1'b1;
        wait_ms(5);
        check(s_px == 16'sd2176 && s_py == 16'sd2176, "bot not placed at its spawn when play began");
        x0 = s_px; y0 = s_py;
        wait_ms(2000);
        check(s_px != x0 || s_py != y0, "bot did not move");
        @(negedge clk); s_hit = 1'b1; @(negedge clk); s_hit = 1'b0;
        wait_ms(5);
        check(s_phealth == 8'd75, "hit on the bot should leave it at 75 health");
        @(negedge clk); s_ping = 1'b1; @(negedge clk); s_ping = 1'b0;
        wait_ms(5);
        check(s_reveal, "reveal not active after ping");
        wait_ms(2100);
        check(!s_reveal, "reveal did not end after 2 s");
        @(negedge clk); s_restart = 1'b1; @(negedge clk); s_restart = 1'b0;
        wait_ms(5);
        check(s_restarts == 1 && !s_in_game, "solo restart did not return to the lobby");
        $display("  solo: instant start (seed %h), bot placed and moving, damage, reveal, restart all work", s_seed);

        // ---- Multiplayer through the same wrapper ----
        a_ready = 1'b1; b_ready = 1'b1;
        wait_ms(1500);
        check(a_starts == 1 && b_starts == 1 && a_seed == b_seed, "multiplayer start through the wrapper failed");
        @(negedge clk); a_hit = 1'b1; @(negedge clk); a_hit = 1'b0;
        wait_ms(500);
        check(b_hits == 1 && b_last_dmg == 8'd40, "multiplayer hit not delivered through the wrapper");
        $display("  multiplayer: handshake (seed %h on both) and a hit event pass through the wrapper", a_seed);

        if (errors == 0) $display("PASS tb_opponent_select");
        else             $display("FAIL tb_opponent_select: %0d errors", errors);
        $finish;
    end
endmodule
