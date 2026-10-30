`timescale 1ns / 1ps
// Tests ai_bot on the team's 10x10 map, with several bots running side by side.
// On every clock, no bot may ever stand inside a wall.
//  1. Seeker bot (hard) starting far away finds a hidden player and shoots them.
//     The easy bot is run too, to compare how long each takes.
//  2. Hider bot next to the Seeker uses a Stim Shot and runs away. A Hider trapped
//     at a dead end with the Seeker 3 cells away fights back with the Freeze Gun.
//  3. A bot hit by the Freeze Gun stands still for 5 s, then moves again.
//  4. Damage: health drops by each hit and the bot stops when it reaches 0.
//  5. Hider bot shoots a Time Capsule it can see.
//  6. Seeker bot that can't see the player uses the Radio Pinger.
// The clock is scaled down to 100 kHz so 30+ seconds of play simulate quickly.

module tb_ai_bot;
    localparam integer CLK_HZ = 100_000;
    localparam integer MS = 1_000_000;            // ns

    reg clk = 1'b0;
    always #5000 clk = ~clk;                      // 100 kHz

    reg frame_tick = 1'b0;
    initial forever begin
        #(16 * MS);
        @(negedge clk); frame_tick = 1'b1; @(negedge clk); frame_tick = 1'b0;
    end

    localparam [99:0]MAP = {
        10'b1111111111,   // y = 0
        10'b1010001001,   // y = 1
        10'b1010001001,   // y = 2
        10'b1010011001,   // y = 3
        10'b1010010001,   // y = 4
        10'b1000000001,   // y = 5
        10'b1100011001,   // y = 6
        10'b1000010001,   // y = 7
        10'b1000010001,   // y = 8
        10'b1111111111    // y = 9
    };
    function wall(input integer x, input integer y);
        begin wall = (x < 0 || y < 0 || x > 9 || y > 9) ? 1'b1 : MAP[99 - (y * 10 + x)]; end
    endfunction
    function signed [15:0]centre(input integer n);
        begin centre = n * 256 + 128; end
    endfunction

    reg reset = 1'b1;
    reg start = 1'b0;

    // ---- Bot A: Seeker, hard, player hidden far away at (8,8)
    // ---- Bot E: Seeker, easy, same situation
    // ---- Bot H: Hider, hard, Seeker right next to it
    // ---- Bot F: Hider, used for freeze and damage tests
    // ---- Bot C: Hider with a capsule in view, player far away
    // ---- Bot P: Seeker, expert, player hidden: should use the Radio Pinger
    reg hit_f = 1'b0, freeze_f = 1'b0;
    reg [7:0]dmg_f = 8'd0;

    wire signed [15:0]ax, ay, ex, ey, hx, hy, fx, fy, cx, cy, px, py;
    wire [7:0]a_hp, f_hp;
    wire a_hit, e_hit, h_frz, h_stim, c_cap, p_ping, f_frozen, z_frz;
    wire signed [15:0]zx, zy;
    wire [7:0]c_cap_id;

    ai_bot #(.CLK_HZ(CLK_HZ)) bot_a (
        .clk(clk), .reset(reset), .enable(1'b1), .frame_tick(frame_tick), .start_game(start),
        .map_bits(MAP), .bot_role(2'd2), .difficulty(2'd2), .spawn_x(centre(1)), .spawn_y(centre(1)),
        .player_x(centre(8)), .player_y(centre(8)),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0),
        .capsule_valid(4'd0), .capsule_cells(32'd0),
        .bot_x(ax), .bot_y(ay), .bot_dir(), .bot_health(a_hp), .bot_frozen(), .bot_stim(),
        .got_hit(a_hit), .got_hit_damage(), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .can_see_player()
    );
    ai_bot #(.CLK_HZ(CLK_HZ)) bot_e (
        .clk(clk), .reset(reset), .enable(1'b1), .frame_tick(frame_tick), .start_game(start),
        .map_bits(MAP), .bot_role(2'd2), .difficulty(2'd0), .spawn_x(centre(1)), .spawn_y(centre(1)),
        .player_x(centre(8)), .player_y(centre(8)),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0),
        .capsule_valid(4'd0), .capsule_cells(32'd0),
        .bot_x(ex), .bot_y(ey), .bot_dir(), .bot_health(), .bot_frozen(), .bot_stim(),
        .got_hit(e_hit), .got_hit_damage(), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .can_see_player()
    );
    ai_bot #(.CLK_HZ(CLK_HZ)) bot_h (
        .clk(clk), .reset(reset), .enable(1'b1), .frame_tick(frame_tick), .start_game(start),
        .map_bits(MAP), .bot_role(2'd1), .difficulty(2'd2), .spawn_x(centre(4)), .spawn_y(centre(5)),
        .player_x(centre(3)), .player_y(centre(5)),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0),
        .capsule_valid(4'd0), .capsule_cells(32'd0),
        .bot_x(hx), .bot_y(hy), .bot_dir(), .bot_health(), .bot_frozen(), .bot_stim(),
        .got_hit(), .got_hit_damage(), .got_frozen(h_frz), .got_pinged(), .peer_stim_used(h_stim),
        .peer_capsule(), .peer_capsule_id(), .can_see_player()
    );
    // ---- Bot Z: Hider trapped at the dead end (1,1) of the x = 1 corridor,
    //      Seeker standing at (1,4) looking up the corridor
    ai_bot #(.CLK_HZ(CLK_HZ)) bot_z (
        .clk(clk), .reset(reset), .enable(1'b1), .frame_tick(frame_tick), .start_game(start),
        .map_bits(MAP), .bot_role(2'd1), .difficulty(2'd2), .spawn_x(centre(1)), .spawn_y(centre(1)),
        .player_x(centre(1)), .player_y(centre(4)),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0),
        .capsule_valid(4'd0), .capsule_cells(32'd0),
        .bot_x(zx), .bot_y(zy), .bot_dir(), .bot_health(), .bot_frozen(), .bot_stim(),
        .got_hit(), .got_hit_damage(), .got_frozen(z_frz), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .can_see_player()
    );
    ai_bot #(.CLK_HZ(CLK_HZ)) bot_f (
        .clk(clk), .reset(reset), .enable(1'b1), .frame_tick(frame_tick), .start_game(start),
        .map_bits(MAP), .bot_role(2'd1), .difficulty(2'd1), .spawn_x(centre(1)), .spawn_y(centre(8)),
        .player_x(centre(8)), .player_y(centre(1)),
        .ev_hit(hit_f), .hit_damage(dmg_f), .ev_freeze(freeze_f), .ev_ping(1'b0),
        .capsule_valid(4'd0), .capsule_cells(32'd0),
        .bot_x(fx), .bot_y(fy), .bot_dir(), .bot_health(f_hp), .bot_frozen(f_frozen), .bot_stim(),
        .got_hit(), .got_hit_damage(), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .can_see_player()
    );
    ai_bot #(.CLK_HZ(CLK_HZ)) bot_c (
        .clk(clk), .reset(reset), .enable(1'b1), .frame_tick(frame_tick), .start_game(start),
        .map_bits(MAP), .bot_role(2'd1), .difficulty(2'd1), .spawn_x(centre(1)), .spawn_y(centre(5)),
        .player_x(centre(8)), .player_y(centre(1)),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0),
        .capsule_valid(4'b0100), .capsule_cells({8'h00, 8'h54, 8'h00, 8'h00}),   // capsule 2 at (4,5)
        .bot_x(cx), .bot_y(cy), .bot_dir(), .bot_health(), .bot_frozen(), .bot_stim(),
        .got_hit(), .got_hit_damage(), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(c_cap), .peer_capsule_id(c_cap_id), .can_see_player()
    );
    ai_bot #(.CLK_HZ(CLK_HZ)) bot_p (
        .clk(clk), .reset(reset), .enable(1'b1), .frame_tick(frame_tick), .start_game(start),
        .map_bits(MAP), .bot_role(2'd2), .difficulty(2'd3), .spawn_x(centre(1)), .spawn_y(centre(1)),
        .player_x(centre(8)), .player_y(centre(8)),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0),
        .capsule_valid(4'd0), .capsule_cells(32'd0),
        .bot_x(px), .bot_y(py), .bot_dir(), .bot_health(), .bot_frozen(), .bot_stim(),
        .got_hit(), .got_hit_damage(), .got_frozen(), .got_pinged(p_ping), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .can_see_player()
    );

    // ---------------- Monitors ----------------
    integer errors = 0;
    integer a_hits = 0, e_hits = 0, h_freezes = 0, h_stims = 0, c_caps = 0, p_pings = 0, z_freezes = 0;
    integer a_first_ms = -1, e_first_ms = -1;
    integer now_ms;
    reg [7:0]last_cap_id;
    always @(posedge clk) begin
        now_ms = $time / MS;
        if (!reset) begin
            if (wall(ax >>> 8, ay >>> 8) || wall(ex >>> 8, ey >>> 8) || wall(hx >>> 8, hy >>> 8) ||
                wall(fx >>> 8, fy >>> 8) || wall(cx >>> 8, cy >>> 8) || wall(px >>> 8, py >>> 8) ||
                wall(zx >>> 8, zy >>> 8)) begin
                if (errors < 5) $display("FAIL a bot is inside a wall at t=%0d ms", now_ms);
                errors = errors + 1;
            end
        end
        if (a_hit) begin a_hits = a_hits + 1; if (a_first_ms < 0) a_first_ms = now_ms; end
        if (e_hit) begin e_hits = e_hits + 1; if (e_first_ms < 0) e_first_ms = now_ms; end
        if (h_frz) h_freezes = h_freezes + 1;
        if (z_frz) z_freezes = z_freezes + 1;
        if (h_stim) h_stims = h_stims + 1;
        if (c_cap) begin c_caps = c_caps + 1; last_cap_id = c_cap_id; end
        if (p_ping) p_pings = p_pings + 1;
    end

    // Long waits in 1 ms steps: a single #(n * MS) overflows 32 bits above about 2.1 s
    task wait_ms(input integer n);
        integer w;
        begin for (w = 0; w < n; w = w + 1) #(MS); end
    endtask

    task check(input cond, input [8*72-1:0]msg);
        begin if (!cond) begin $display("FAIL %0s", msg); errors = errors + 1; end end
    endtask

    integer hx0, hy0, fx0, fy0, t;
    initial begin
        #(1 * MS);
        reset = 1'b0;
        @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0;

        // 3. Freeze bot F straight away and check it stays put for 5 s
        #(500 * MS);
        @(negedge clk); freeze_f = 1'b1; @(negedge clk); freeze_f = 1'b0;
        #(100 * MS);
        fx0 = fx; fy0 = fy;
        wait_ms(4500);
        check(fx == fx0 && fy == fy0 && f_frozen, "frozen bot moved during the 5 s freeze");
        wait_ms(2000);
        check(!f_frozen && (fx != fx0 || fy != fy0), "bot did not move again after the freeze");
        $display("  freeze: bot stood still for 5 s, then moved again");

        // 4. Damage
        @(negedge clk); hit_f = 1'b1; dmg_f = 8'd30; @(negedge clk); hit_f = 1'b0;
        #(5 * MS);
        check(f_hp == 8'd70, "health should be 100 - 30 = 70");
        for (t = 0; t < 3; t = t + 1) begin
            @(negedge clk); hit_f = 1'b1; dmg_f = 8'd30; @(negedge clk); hit_f = 1'b0;
        end
        #(100 * MS);
        fx0 = fx; fy0 = fy;
        wait_ms(2000);
        check(f_hp == 8'd0 && fx == fx0 && fy == fy0, "bot should be at 0 health and stopped");
        $display("  damage: 100 -> 70 -> 0 (no wrap below zero), bot stops at 0");

        // Let the rest of the game run
        wait_ms(25000);

        // 1. Seekers
        check(a_hits >= 1, "hard Seeker never hit the hidden player in 32 s");
        $display("  seeker: hard bot first hit after %0d ms (%0d hits); easy bot first hit after %0d ms (%0d hits)",
                 a_first_ms, a_hits, e_first_ms, e_hits);

        // 2. Hider runs, stims and freezes
        check(h_stims >= 1, "Hider next to the Seeker never used a Stim Shot");
        check(z_freezes >= 1, "trapped Hider never landed a Freeze Gun hit");
        t = ((hx >>> 8) - 3); if (t < 0) t = -t;
        t = t + (((hy >>> 8) - 5) < 0 ? 5 - (hy >>> 8) : (hy >>> 8) - 5);
        check(t >= 3, "Hider did not get away from the Seeker");
        $display("  hider: used %0d Stim Shot(s) and escaped to %0d cells away; trapped Hider landed %0d Freeze Gun hit(s)", h_stims, t, z_freezes);

        // 5. Capsule
        check(c_caps >= 1 && last_cap_id == 8'd2, "Hider did not shoot visible capsule 2");
        $display("  capsule: Hider shot capsule %0d (%0d shots, capsule left in place by this test)", last_cap_id, c_caps);

        // 6. Ping
        check(p_pings >= 1 && p_pings <= 3, "Seeker should use the Radio Pinger 1 to 3 times");
        $display("  radio pinger: used %0d time(s) (limit 3)", p_pings);

        if (errors == 0) $display("PASS tb_ai_bot (no bot ever entered a wall)");
        else             $display("FAIL tb_ai_bot: %0d errors", errors);
        $finish;
    end
endmodule
