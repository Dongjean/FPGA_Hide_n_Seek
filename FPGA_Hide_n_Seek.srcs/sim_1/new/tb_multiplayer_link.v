`timescale 1ns / 1ps
// Two multiplayer_link instances wired together like two boards (B's clock 1% faster).
//  1. Role conflict: both pick Hider -> role_conflict, no start.
//  2. Start-up: A = Seeker, B = Hider, both ready -> both start with the same seed.
//  3. State sync: position, direction, health and flags appear on the other board.
//  4. Events fired in the same clock (hit, freeze, ping, stim, capsule) each arrive
//     exactly once with the right values; the Seeker's reveal window opens.
//  5. With random bit errors on BOTH wires, 30 capsule events still arrive exactly
//     once and in order (tests retransmit and duplicate rejection).
//  6. Pause on one board pauses both; unplugging the cable pauses both.
//  7. Restart from B returns both boards to the lobby.
//  8. Board A reboots: events from A still get through afterwards.
// Clocks are scaled down (1 MHz, 50 kbaud) so this simulates quickly.

module tb_multiplayer_link;
    localparam integer CLK_HZ = 1_000_000;
    localparam integer BAUD   = 50_000;
    localparam integer MS     = 1_000_000;
    localparam integer BIT_NS = 1_000_000_000 / BAUD;

    reg clk_a = 1'b0, clk_b = 1'b0;
    always #500 clk_a = ~clk_a;
    always #495 clk_b = ~clk_b;

    reg reset_a = 1'b1, reset_b = 1'b1;
    reg plugged = 1'b1;
    reg noise = 1'b0;
    reg flip_ab = 1'b0, flip_ba = 1'b0;
    wire a_tx, b_tx;
    wire b_rx = plugged ? (a_tx ^ flip_ab) : 1'b1;
    wire a_rx = plugged ? (b_tx ^ flip_ba) : 1'b1;

    // Per-board inputs
    reg [1:0]role_a = 0, role_b = 0;
    reg ready_a = 0, ready_b = 0;
    reg signed [15:0]x_a = 16'sd1408, y_a = 16'sd1408, x_b = 16'sd512, y_b = 16'sd2048;
    reg [7:0]dir_a = 8'd64, dir_b = 8'd192, hp_a = 8'd100, hp_b = 8'd100;
    reg paused_a = 0, paused_b = 0, frozen_a = 0, stim_b = 0;
    reg hit_a = 0, freeze_a = 0, ping_a = 0, stim_ev_a = 0, cap_a = 0, restart_b = 0;
    reg [7:0]dmg_a = 0, capid_a = 0;

    // Outputs
    wire [1:0]peer_role_a, peer_role_b;
    wire peer_ready_a, peer_ready_b, conflict_a, conflict_b;
    wire in_game_a, in_game_b, start_a, start_b;
    wire [15:0]seed_a, seed_b;
    wire signed [15:0]px_a, py_a, px_b, py_b;
    wire [7:0]pdir_a, pdir_b, php_a, php_b;
    wire ppause_a, ppause_b, pfrozen_b, pstim_a, pin_a, pin_b;
    wire link_a, link_b, gp_a, gp_b;
    wire got_hit_b, got_frozen_b, got_pinged_b, stim_used_b, cap_b, restart_out_a, restart_out_b;
    wire [7:0]got_dmg_b, cap_id_b;
    wire reveal_a;
    wire [7:0]err_a, err_b;
    wire overflow_a;

    multiplayer_link #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) board_a (
        .clk(clk_a), .reset(reset_a), .link_rx(a_rx), .link_tx(a_tx),
        .my_role(role_a), .my_ready(ready_a), .peer_role(peer_role_a), .peer_ready(peer_ready_a),
        .role_conflict(conflict_a), .in_game(in_game_a), .start_game(start_a), .game_seed(seed_a),
        .my_x(x_a), .my_y(y_a), .my_dir(dir_a), .my_health(hp_a),
        .my_paused(paused_a), .my_frozen(frozen_a), .my_stim(1'b0),
        .peer_x(px_a), .peer_y(py_a), .peer_dir(pdir_a), .peer_health(php_a),
        .peer_paused(ppause_a), .peer_frozen(), .peer_stim(pstim_a), .peer_in_game(pin_a),
        .link_up(link_a), .game_paused(gp_a),
        .ev_hit(hit_a), .hit_damage(dmg_a), .ev_freeze(freeze_a), .ev_ping(ping_a), .ev_stim(stim_ev_a),
        .ev_capsule(cap_a), .capsule_id(capid_a), .ev_restart(1'b0),
        .got_hit(), .got_hit_damage(), .got_frozen(), .got_pinged(), .peer_stim_used(),
        .peer_capsule(), .peer_capsule_id(), .restart_game(restart_out_a),
        .reveal_active(reveal_a), .reveal_x(), .reveal_y(), .rx_error_count(err_a), .ev_overflow(overflow_a)
    );

    multiplayer_link #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) board_b (
        .clk(clk_b), .reset(reset_b), .link_rx(b_rx), .link_tx(b_tx),
        .my_role(role_b), .my_ready(ready_b), .peer_role(peer_role_b), .peer_ready(peer_ready_b),
        .role_conflict(conflict_b), .in_game(in_game_b), .start_game(start_b), .game_seed(seed_b),
        .my_x(x_b), .my_y(y_b), .my_dir(dir_b), .my_health(hp_b),
        .my_paused(paused_b), .my_frozen(1'b0), .my_stim(stim_b),
        .peer_x(px_b), .peer_y(py_b), .peer_dir(pdir_b), .peer_health(php_b),
        .peer_paused(ppause_b), .peer_frozen(pfrozen_b), .peer_stim(), .peer_in_game(pin_b),
        .link_up(link_b), .game_paused(gp_b),
        .ev_hit(1'b0), .hit_damage(8'd0), .ev_freeze(1'b0), .ev_ping(1'b0), .ev_stim(1'b0),
        .ev_capsule(1'b0), .capsule_id(8'd0), .ev_restart(restart_b),
        .got_hit(got_hit_b), .got_hit_damage(got_dmg_b), .got_frozen(got_frozen_b),
        .got_pinged(got_pinged_b), .peer_stim_used(stim_used_b),
        .peer_capsule(cap_b), .peer_capsule_id(cap_id_b), .restart_game(restart_out_b),
        .reveal_active(), .reveal_x(), .reveal_y(), .rx_error_count(err_b), .ev_overflow()
    );

    // ---------------- Monitors ----------------
    integer starts_a = 0, starts_b = 0, hits_b = 0, freezes_b = 0, pings_b = 0, stims_b = 0;
    integer caps_b = 0, restarts_a = 0, restarts_b = 0;
    reg [7:0]last_dmg_b;
    reg [7:0]cap_log [0:63];
    always @(posedge clk_a) begin
        if (start_a) starts_a = starts_a + 1;
        if (restart_out_a) restarts_a = restarts_a + 1;
    end
    always @(posedge clk_b) begin
        if (start_b) starts_b = starts_b + 1;
        if (got_hit_b) begin hits_b = hits_b + 1; last_dmg_b = got_dmg_b; end
        if (got_frozen_b) freezes_b = freezes_b + 1;
        if (got_pinged_b) pings_b = pings_b + 1;
        if (stim_used_b) stims_b = stims_b + 1;
        if (cap_b) begin cap_log[caps_b] = cap_id_b; caps_b = caps_b + 1; end
        if (restart_out_b) restarts_b = restarts_b + 1;
    end

    // Random single-bit errors on both wires while noise is on
    integer gap;
    initial forever begin
        gap = 2000 + ($random & 32'h1FFF);           // 2 to 10 ms
        #(gap * 1000);
        if (noise) begin flip_ab = 1'b1; #(BIT_NS); flip_ab = 1'b0; end
        gap = 1000 + ($random & 32'h1FFF);
        #(gap * 1000);
        if (noise) begin flip_ba = 1'b1; #(BIT_NS); flip_ba = 1'b0; end
    end

    // One-clock pulse on board A's clock
    task pulse_a(inout reg sig);
        begin @(negedge clk_a); sig = 1'b1; @(negedge clk_a); sig = 1'b0; end
    endtask

    integer errors = 0;
    integer i;
    task check(input cond, input [8*64-1:0]msg);
        begin if (!cond) begin $display("FAIL %0s", msg); errors = errors + 1; end end
    endtask

    initial begin
        #(1 * MS);
        reset_a = 1'b0; reset_b = 1'b0;
        #(100 * MS);
        check(link_a && link_b, "link did not come up");

        // 1. Role conflict (ready is pressed after power-up, as a player would)
        #(5 * MS);
        role_a = 2'd1; role_b = 2'd1; ready_a = 1; ready_b = 1;
        #(150 * MS);
        check(conflict_a && conflict_b, "role conflict not flagged");
        check(starts_a == 0 && starts_b == 0, "game started despite role conflict");
        $display("  step 1: role conflict detected, no start");

        // 2. Start-up
        role_a = 2'd2;   // A becomes Seeker
        #(150 * MS);
        check(starts_a == 1 && starts_b == 1, "both boards did not start exactly once");
        check(seed_a == seed_b && seed_a != 16'd0, "seeds differ or are zero");
        check(in_game_a && in_game_b, "not in game after start");
        $display("  step 2: both boards started, seed %h on both", seed_a);

        // 3. State sync
        x_a = 16'sd2000; y_a = -16'sd5; dir_a = 8'd200; hp_a = 8'd73; frozen_a = 1;
        #(80 * MS);
        check(px_b == 16'sd2000 && py_b == -16'sd5 && pdir_b == 8'd200 && php_b == 8'd73 && pfrozen_b,
              "B does not show A's state");
        check(px_a == x_b && py_a == y_b && pdir_a == dir_b, "A does not show B's state");
        $display("  step 3: state synced both ways");

        // 4. Five events in the same clock
        @(negedge clk_a);
        hit_a = 1; dmg_a = 8'd25; freeze_a = 1; ping_a = 1; stim_ev_a = 1; cap_a = 1; capid_a = 8'd9;
        @(negedge clk_a);
        hit_a = 0; freeze_a = 0; ping_a = 0; stim_ev_a = 0; cap_a = 0;
        #(5 * MS);
        check(reveal_a, "reveal window not open after ping");
        #(200 * MS);
        check(hits_b == 1 && last_dmg_b == 8'd25, "hit not received once with damage 25");
        check(freezes_b == 1 && pings_b == 1 && stims_b == 1, "freeze/ping/stim not received once");
        check(caps_b == 1 && cap_log[0] == 8'd9, "capsule 9 not received once");
        #(2000 * MS);
        check(!reveal_a, "reveal window did not close after 2 s");
        $display("  step 4: 5 simultaneous events each delivered once; reveal lasted 2 s");

        // 5. 30 events with bit errors on both wires
        noise = 1'b1;
        caps_b = 0;
        for (i = 0; i < 30; i = i + 1) begin
            @(negedge clk_a); cap_a = 1; capid_a = i[7:0];
            @(negedge clk_a); cap_a = 0;
            #((5 + ($random & 15)) * MS);
        end
        #(1500 * MS);
        noise = 1'b0;
        #(500 * MS);
        check(caps_b == 30, "not all 30 events arrived exactly once");
        check(!overflow_a, "event queue overflowed");
        for (i = 0; i < 30; i = i + 1)
            if (cap_log[i] != i[7:0]) begin $display("FAIL event %0d out of order (%0d)", i, cap_log[i]); errors = errors + 1; end
        $display("  step 5: 30 events through bit errors: %0d received in order (A rejected %0d, B rejected %0d packets)",
                 caps_b, err_a, err_b);

        // 6. Pause and unplug
        paused_b = 1; #(80 * MS);
        check(gp_a && gp_b, "pause on B did not pause both");
        paused_b = 0; #(80 * MS);
        check(!gp_a && !gp_b, "unpause did not resume both");
        plugged = 0; #(700 * MS);
        check(gp_a && gp_b && !link_a && !link_b, "unplugging did not pause both");
        plugged = 1; #(200 * MS);
        check(!gp_a && !gp_b && link_a && link_b, "replugging did not resume");
        $display("  step 6: pause synced; cable loss pauses and recovers");

        // 7. Restart from B
        @(negedge clk_b); restart_b = 1; @(negedge clk_b); restart_b = 0;
        #(200 * MS);
        check(restarts_a == 1 && restarts_b == 1, "restart not seen once on both boards");
        check(!in_game_a && !in_game_b, "boards did not return to the lobby (players still holding ready)");
        $display("  step 7: restart returned both boards to the lobby");

        // 8. Board A reboots, then A's events must still be accepted
        ready_a = 0; ready_b = 0;
        reset_a = 1'b1; #(5 * MS); reset_a = 1'b0;
        #(200 * MS);
        hits_b = 0;
        @(negedge clk_a); hit_a = 1; dmg_a = 8'd3; @(negedge clk_a); hit_a = 0;
        #(200 * MS);
        check(hits_b == 1 && last_dmg_b == 8'd3, "event after A rebooted was lost");
        $display("  step 8: event from rebooted board accepted");

        if (errors == 0) $display("PASS tb_multiplayer_link");
        else             $display("FAIL tb_multiplayer_link: %0d errors", errors);
        $finish;
    end
endmodule
