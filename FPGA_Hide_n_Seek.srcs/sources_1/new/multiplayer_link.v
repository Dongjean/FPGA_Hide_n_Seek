`timescale 1ns / 1ps
// Game message layer between the two Basys3 boards, built on packet_sender/packet_receiver.
//
// 1. Start-up: each player picks a role (Hider or Seeker) and presses ready.
//    When both are ready with different roles, the Seeker's board picks a random
//    map seed and sends START. Both boards then pulse start_game with the same
//    game_seed, so both generate the same map and begin the countdown together.
//
// 2. State: every STATE_MS each board sends its player's position, direction,
//    health and status flags. The other board's copy appears on the peer_* outputs.
//
// 3. Events (hit, freeze, ping, stim, capsule, restart, start) must arrive exactly
//    once, so they are sent reliably: each has a sequence number, the receiver
//    replies with an ACK, the sender resends every RETRY_MS until it gets the ACK,
//    and the receiver ignores repeats of a sequence number it has already handled.
//
// 4. Pause: game_paused is high if either player has paused, or if the link is lost
//    during a game.
//
// 5. Radio Pinger: pulsing ev_ping on the Seeker's board raises reveal_active for
//    REVEAL_MS, while reveal_x/reveal_y give the Hider's live position for the minimap.
//    The Hider's board gets got_pinged so it can warn the player.
//
// Packets:  STATE 0x10 (7 bytes), EVENT 0x20 (3 bytes: code, arg low, arg high),
//           ACK 0x21 (1 byte: sequence number being acknowledged)

module multiplayer_link
#(
    parameter integer CLK_HZ     = 6_250_000,
    parameter integer BAUD       = 115_200,
    parameter integer STATE_MS   = 20,
    parameter integer TIMEOUT_MS = 500,
    parameter integer RETRY_MS   = 10,
    parameter integer REVEAL_MS  = 2000
)
(
    input clk,
    input reset,
    input link_rx,
    output link_tx,

    // Start-up (role select menu)
    input [1:0]my_role,                    // 0 = none, 1 = Hider, 2 = Seeker
    input my_ready,
    output reg [1:0]peer_role = 2'd0,
    output reg peer_ready = 1'b0,
    output role_conflict,                  // both players picked the same role
    output reg in_game = 1'b0,
    output reg start_game = 1'b0,          // one pulse on both boards
    output reg [15:0]game_seed = 16'd1,    // never 0, so it is safe for an LFSR

    // This board's player
    input signed [15:0]my_x,               // Q8.8 map cells
    input signed [15:0]my_y,
    input [7:0]my_dir,
    input [7:0]my_health,
    input my_paused,
    input my_frozen,
    input my_stim,

    // The other board's player
    output reg signed [15:0]peer_x = 16'sd0,
    output reg signed [15:0]peer_y = 16'sd0,
    output reg [7:0]peer_dir = 8'd0,
    output reg [7:0]peer_health = 8'd0,
    output reg peer_paused = 1'b0,
    output reg peer_frozen = 1'b0,
    output reg peer_stim = 1'b0,
    output reg peer_in_game = 1'b0,
    output link_up,
    output game_paused,

    // Events caused by this board (one clock pulses)
    input ev_hit,                          // this player's shot hit the other player
    input [7:0]hit_damage,
    input ev_freeze,                       // Hider's Freeze Gun hit the Seeker
    input ev_ping,                         // Seeker used the Radio Pinger
    input ev_stim,                         // Hider used a Stim Shot
    input ev_capsule,                      // Hider shot a Time Capsule
    input [7:0]capsule_id,
    input ev_restart,

    // Events caused by the other board (one clock pulses)
    output reg got_hit = 1'b0,
    output reg [7:0]got_hit_damage = 8'd0,
    output reg got_frozen = 1'b0,
    output reg got_pinged = 1'b0,
    output reg peer_stim_used = 1'b0,
    output reg peer_capsule = 1'b0,
    output reg [7:0]peer_capsule_id = 8'd0,
    output reg restart_game = 1'b0,        // pulses on both boards for a restart from either

    // Radio Pinger reveal on the Seeker's board
    output reveal_active,
    output signed [15:0]reveal_x,
    output signed [15:0]reveal_y,

    output reg [7:0]rx_error_count = 8'd0, // rejected packets, for debugging
    output reg ev_overflow = 1'b0          // stays high if an event was ever dropped
);
    localparam [1:0]ROLE_HIDER  = 2'd1;
    localparam [1:0]ROLE_SEEKER = 2'd2;

    localparam [7:0]TYPE_STATE = 8'h10;
    localparam [7:0]TYPE_EVENT = 8'h20;
    localparam [7:0]TYPE_ACK   = 8'h21;

    localparam [7:0]EV_START   = 8'd1;
    localparam [7:0]EV_HIT     = 8'd2;
    localparam [7:0]EV_FREEZE  = 8'd3;
    localparam [7:0]EV_PING    = 8'd4;
    localparam [7:0]EV_STIM    = 8'd5;
    localparam [7:0]EV_CAPSULE = 8'd6;
    localparam [7:0]EV_RESTART = 8'd7;

    localparam integer MAX_LEN     = 8;
    localparam integer CLKS_PER_MS = CLK_HZ / 1000;
    localparam integer RETRY_CLKS  = RETRY_MS * CLKS_PER_MS;
    localparam integer REVEAL_CLKS = REVEAL_MS * CLKS_PER_MS;

    // ---------------- Packet layer ----------------
    reg send = 1'b0;
    reg [7:0]send_type;
    reg [7:0]send_seq;
    reg [7:0]send_len;
    reg [8*MAX_LEN-1:0]send_payload;
    wire tx_busy;

    packet_sender #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) sender (
        .clk         (clk),
        .reset       (reset),
        .send        (send),
        .pkt_type    (send_type),
        .pkt_seq     (send_seq),
        .pkt_len     (send_len),
        .pkt_payload (send_payload),
        .busy        (tx_busy),
        .tx          (link_tx)
    );

    wire rx_valid;
    wire rx_error;
    wire [7:0]rx_type;
    wire [7:0]rx_seq;
    wire [7:0]rx_len;
    wire [8*MAX_LEN-1:0]rx_payload;

    packet_receiver #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) receiver (
        .clk         (clk),
        .reset       (reset),
        .rx          (link_rx),
        .pkt_valid   (rx_valid),
        .pkt_type    (rx_type),
        .pkt_seq     (rx_seq),
        .pkt_len     (rx_len),
        .pkt_payload (rx_payload),
        .pkt_error   (rx_error)
    );

    wire heartbeat;
    link_monitor #(.CLK_HZ(CLK_HZ), .HEARTBEAT_MS(STATE_MS), .TIMEOUT_MS(TIMEOUT_MS)) status (
        .clk          (clk),
        .reset        (reset),
        .rx_pkt_valid (rx_valid),
        .link_up      (link_up),
        .heartbeat    (heartbeat)
    );

    // ---------------- Outgoing event queue (8 entries of {code, arg}) ----------------
    reg [23:0]queue [0:7];
    reg [2:0]q_head = 3'd0;
    reg [2:0]q_tail = 3'd0;
    reg [3:0]q_count = 4'd0;
    wire [7:0]head_code = queue[q_head][23:16];
    wire [15:0]head_arg = queue[q_head][15:0];

    // Event requests waiting to enter the queue, so simultaneous pulses are not lost
    reg p_start = 1'b0, p_hit = 1'b0, p_freeze = 1'b0, p_ping = 1'b0;
    reg p_stim = 1'b0, p_capsule = 1'b0, p_restart = 1'b0;
    reg [15:0]arg_start;
    reg [7:0]arg_hit;
    reg [7:0]arg_capsule;

    reg waiting_ack = 1'b0;       // head of the queue has been sent, waiting for its ACK
    reg ev_send_req = 1'b0;       // head of the queue needs to be (re)sent
    reg [7:0]ev_seq = 8'd0;
    reg [31:0]retry_count = 32'd0;

    reg ack_pending = 1'b0;
    reg [7:0]ack_seq = 8'd0;
    reg have_rx_seq = 1'b0;
    reg [7:0]last_rx_seq = 8'd0;

    // Reboot detection: fresh_boot is set after reset and cleared once one of our
    // events has been acknowledged. When the other board sees it change from 0 to 1,
    // it knows we restarted (and our sequence numbers started again from 0).
    reg fresh_boot = 1'b1;
    reg fresh_announced = 1'b0;   // at least one STATE sent since reset
    reg peer_fresh = 1'b0;

    reg state_due = 1'b0;
    reg start_requested = 1'b0;
    reg ready_armed = 1'b0;       // my_ready has been released since the last game
    wire ready_now = my_ready && ready_armed;
    reg [15:0]free_count = 16'd0;
    reg [31:0]reveal_count = 32'd0;

    reg do_push;
    reg do_pop;
    reg [7:0]push_code;
    reg [15:0]push_arg;

    assign role_conflict = link_up && (my_role != 2'd0) && (my_role == peer_role);
    assign game_paused   = in_game && (my_paused || peer_paused || !link_up);
    assign reveal_active = (reveal_count != 32'd0);
    assign reveal_x      = peer_x;
    assign reveal_y      = peer_y;

    always @(posedge clk) begin
        send           <= 1'b0;
        start_game     <= 1'b0;
        got_hit        <= 1'b0;
        got_frozen     <= 1'b0;
        got_pinged     <= 1'b0;
        peer_stim_used <= 1'b0;
        peer_capsule   <= 1'b0;
        restart_game   <= 1'b0;
        free_count     <= free_count + 16'd1;
        do_push = 1'b0;
        do_pop  = 1'b0;

        if (reset) begin
            in_game         <= 1'b0;
            q_head          <= 3'd0;
            q_tail          <= 3'd0;
            q_count         <= 4'd0;
            ready_armed     <= 1'b0;
            p_start         <= 1'b0;
            p_hit           <= 1'b0;
            p_freeze        <= 1'b0;
            p_ping          <= 1'b0;
            p_stim          <= 1'b0;
            p_capsule       <= 1'b0;
            p_restart       <= 1'b0;
            waiting_ack     <= 1'b0;
            ev_send_req     <= 1'b0;
            ev_seq          <= 8'd0;
            ack_pending     <= 1'b0;
            have_rx_seq     <= 1'b0;
            fresh_boot      <= 1'b1;
            fresh_announced <= 1'b0;
            peer_fresh      <= 1'b0;
            state_due       <= 1'b0;
            start_requested <= 1'b0;
            reveal_count    <= 32'd0;
            peer_role       <= 2'd0;
            peer_ready      <= 1'b0;
            peer_in_game    <= 1'b0;
            peer_paused     <= 1'b0;
        end else begin
            if (reveal_count != 32'd0)
                reveal_count <= reveal_count - 32'd1;

            // ---------- Transmit: one packet at a time, ACKs first ----------
            if (!tx_busy && !send) begin
                if (ack_pending) begin
                    send         <= 1'b1;
                    send_type    <= TYPE_ACK;
                    send_seq     <= 8'd0;
                    send_len     <= 8'd1;
                    send_payload <= {56'd0, ack_seq};
                    ack_pending  <= 1'b0;
                end else if (ev_send_req && fresh_announced) begin
                    send         <= 1'b1;
                    send_type    <= TYPE_EVENT;
                    send_seq     <= ev_seq;
                    send_len     <= 8'd3;
                    send_payload <= {40'd0, head_arg[15:8], head_arg[7:0], head_code};
                    ev_send_req  <= 1'b0;
                    retry_count  <= 32'd0;
                end else if (state_due || !fresh_announced) begin
                    send         <= 1'b1;
                    send_type    <= TYPE_STATE;
                    send_seq     <= 8'd0;
                    send_len     <= 8'd7;
                    send_payload <= {8'd0,
                                     in_game, my_paused, my_frozen, my_stim, ready_now, fresh_boot, my_role,
                                     my_health, my_dir, my_y[15:8], my_y[7:0], my_x[15:8], my_x[7:0]};
                    state_due       <= 1'b0;
                    fresh_announced <= 1'b1;
                end
            end

            // ---------- Resend the head event if no ACK arrives in time ----------
            if (waiting_ack && !ev_send_req) begin
                if (retry_count == RETRY_CLKS - 1) begin
                    retry_count <= 32'd0;
                    ev_send_req <= 1'b1;
                end else begin
                    retry_count <= retry_count + 32'd1;
                end
            end

            // Start sending the next queued event
            if (!waiting_ack && q_count != 4'd0) begin
                waiting_ack <= 1'b1;
                ev_send_req <= 1'b1;
            end

            // ---------- Receive ----------
            if (rx_error)
                rx_error_count <= rx_error_count + 8'd1;

            if (rx_valid) begin
                case (rx_type)
                    TYPE_STATE: begin
                        peer_x       <= {rx_payload[15:8], rx_payload[7:0]};
                        peer_y       <= {rx_payload[31:24], rx_payload[23:16]};
                        peer_dir     <= rx_payload[39:32];
                        peer_health  <= rx_payload[47:40];
                        peer_role    <= rx_payload[49:48];
                        peer_fresh   <= rx_payload[50];
                        peer_ready   <= rx_payload[51];
                        peer_stim    <= rx_payload[52];
                        peer_frozen  <= rx_payload[53];
                        peer_paused  <= rx_payload[54];
                        peer_in_game <= rx_payload[55];
                        if (rx_payload[50] && !peer_fresh)
                            have_rx_seq <= 1'b0;     // the other board rebooted
                    end

                    TYPE_ACK: begin
                        if (waiting_ack && rx_payload[7:0] == ev_seq) begin
                            do_pop = 1'b1;
                            waiting_ack <= 1'b0;
                            ev_send_req <= 1'b0;
                            ev_seq      <= ev_seq + 8'd1;
                            fresh_boot  <= 1'b0;
                            // The Seeker's board starts when its START is acknowledged
                            if (head_code == EV_START && !in_game) begin
                                in_game    <= 1'b1;
                                start_game <= 1'b1;
                                game_seed  <= head_arg;
                            end
                        end
                    end

                    TYPE_EVENT: begin
                        ack_pending <= 1'b1;
                        ack_seq     <= rx_seq;
                        if (!have_rx_seq || rx_seq != last_rx_seq) begin
                            have_rx_seq <= 1'b1;
                            last_rx_seq <= rx_seq;
                            case (rx_payload[7:0])
                                EV_START: begin
                                    if (!in_game) begin
                                        in_game    <= 1'b1;
                                        start_game <= 1'b1;
                                        game_seed  <= rx_payload[23:8];
                                    end
                                end
                                EV_HIT: begin
                                    got_hit        <= 1'b1;
                                    got_hit_damage <= rx_payload[15:8];
                                end
                                EV_FREEZE:  got_frozen     <= 1'b1;
                                EV_PING:    got_pinged     <= 1'b1;
                                EV_STIM:    peer_stim_used <= 1'b1;
                                EV_CAPSULE: begin
                                    peer_capsule    <= 1'b1;
                                    peer_capsule_id <= rx_payload[15:8];
                                end
                                EV_RESTART: begin
                                    restart_game    <= 1'b1;
                                    in_game         <= 1'b0;
                                    start_requested <= 1'b0;
                                    ready_armed     <= 1'b0;
                                end
                                default: ;
                            endcase
                        end
                    end

                    default: ;
                endcase
            end

            // ---------- Move one waiting request into the queue ----------
            if (q_count != 4'd8) begin
                if (p_restart) begin
                    do_push = 1'b1; push_code = EV_RESTART; push_arg = 16'd0; p_restart <= 1'b0;
                end else if (p_start) begin
                    do_push = 1'b1; push_code = EV_START; push_arg = arg_start; p_start <= 1'b0;
                end else if (p_hit) begin
                    do_push = 1'b1; push_code = EV_HIT; push_arg = {8'd0, arg_hit}; p_hit <= 1'b0;
                end else if (p_freeze) begin
                    do_push = 1'b1; push_code = EV_FREEZE; push_arg = 16'd0; p_freeze <= 1'b0;
                end else if (p_ping) begin
                    do_push = 1'b1; push_code = EV_PING; push_arg = 16'd0; p_ping <= 1'b0;
                end else if (p_stim) begin
                    do_push = 1'b1; push_code = EV_STIM; push_arg = 16'd0; p_stim <= 1'b0;
                end else if (p_capsule) begin
                    do_push = 1'b1; push_code = EV_CAPSULE; push_arg = {8'd0, arg_capsule}; p_capsule <= 1'b0;
                end
            end

            if (do_push) begin
                queue[q_tail] <= {push_code, push_arg};
                q_tail <= q_tail + 3'd1;
            end
            if (do_pop)
                q_head <= q_head + 3'd1;
            q_count <= q_count + {3'd0, do_push} - {3'd0, do_pop};

            // ---------- New requests from the game (after the queue step, so
            //            a request arriving this clock is never lost) ----------
            // A request that finds the same kind still waiting (queue full) is lost
            if ((ev_hit && p_hit && !(do_push && push_code == EV_HIT)) ||
                (ev_capsule && p_capsule && !(do_push && push_code == EV_CAPSULE)))
                ev_overflow <= 1'b1;
            if (ev_hit)     begin p_hit <= 1'b1; arg_hit <= hit_damage; end
            if (ev_freeze)  p_freeze <= 1'b1;
            if (ev_ping)    begin p_ping <= 1'b1; reveal_count <= REVEAL_CLKS; end
            if (ev_stim)    p_stim <= 1'b1;
            if (ev_capsule) begin p_capsule <= 1'b1; arg_capsule <= capsule_id; end
            if (ev_restart) begin
                p_restart       <= 1'b1;
                restart_game    <= 1'b1;
                in_game         <= 1'b0;
                start_requested <= 1'b0;
                ready_armed     <= 1'b0;
            end

            // After a restart, my_ready only counts again once it has been released
            if (!my_ready && !in_game)
                ready_armed <= 1'b1;

            // The Seeker's board starts the game once both players are ready
            if (!in_game && !start_requested && link_up && ready_now && peer_ready &&
                my_role == ROLE_SEEKER && peer_role == ROLE_HIDER) begin
                p_start         <= 1'b1;
                arg_start       <= (free_count == 16'd0) ? 16'd1 : free_count;
                start_requested <= 1'b1;
            end

            if (heartbeat)
                state_due <= 1'b1;
        end
    end
endmodule
