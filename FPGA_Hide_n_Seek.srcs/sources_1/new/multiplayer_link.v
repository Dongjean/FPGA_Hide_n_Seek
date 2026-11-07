`timescale 1ns / 1ps
// Game message layer between the two Basys3 boards, built on packet_sender/packet_receiver.
//
// 1. Master and slave: when the link first comes up the two boards agree which one
//    is the master. The board that has been switched on longer is the master
//    (uptime is sent in every STATE). If both were switched on within about a
//    second of each other, a random number (nonce) decides. A board that joins a
//    board that has already decided takes the other job, and if both ever claim
//    the same job, the nonce settles it.
//
// 2. Main menu: each board sends its game mode (my_mode: 0 = still choosing,
//    1 = singleplayer, 2 = multiplayer) in every STATE; the other board's mode
//    appears on peer_mode (0 while the link is down). In multiplayer, as soon as
//    EITHER player confirms a role (my_pick, my_confirmed / peer_pick,
//    peer_confirmed) the master picks a random map seed and sends START with its
//    own role: the confirmed player gets the role they picked and the other
//    player gets the other one. If both confirm at the same moment the master's
//    pick wins. Both boards then pulse start_game with the same game_seed and
//    set my_role for the match.
//
// 3. State: every STATE_MS each board sends its player's position, direction,
//    health and status flags. The other board's copy appears on the peer_* outputs.
//
// 4. Events (start, hit, freeze, ping, flashbang, capsule, restart, game over, menu,
//    player state) must arrive exactly once, so they are sent reliably: each has a
//    sequence number, the receiver replies with an ACK, the sender resends every
//    RETRY_MS until it gets the ACK, and the receiver ignores repeats of a sequence
//    number it has already handled.
//
// 5. End of match: ev_game_over (with the winner) ends the match on both boards.
//    If the boards disagree on the winner, the master's verdict wins. ev_menu
//    takes both boards from the end screen back to the main menu.
//
// 6. Player state: state_change_valid / player_state ask the OTHER board to put
//    its player_state_FSM into player_state. They arrive there as
//    got_state_change / got_player_state.
//
// 7. Pause: game_paused is high if either player has paused, or if the link is lost
//    during a game.
//
// 8. Radio Pinger: pulsing ev_ping on the Seeker's board raises reveal_active for
//    REVEAL_MS, while reveal_x/reveal_y give the Hider's live position for the minimap.
//    The Hider's board gets got_pinged so it can warn the player.
//
// Packets:  STATE 0x10 (11 bytes; byte 10 = {4'b0, hand, mode}), EVENT 0x20 (4 bytes: code, arg low, arg high, arg2),
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

    // Main menu
    input [1:0]my_mode,                    // 0 = choosing, 1 = singleplayer, 2 = multiplayer
    output reg [1:0]peer_mode = 2'd0,      // the other board's my_mode (0 while the link is down)
    input [1:0]my_pick,                    // role this player has picked: 1 = Hider, 2 = Seeker
    input my_confirmed,                    // this player has confirmed my_pick
    output reg [1:0]peer_pick = 2'd0,      // role the other player has picked
    output reg peer_confirmed = 1'b0,      // the other player has confirmed peer_pick
    output reg is_master = 1'b0,
    output reg master_decided = 1'b0,      // is_master is valid
    output reg [1:0]my_role = 2'd0,        // this player's role in the match (set at START)
    output reg in_game = 1'b0,
    output reg start_game = 1'b0,          // one pulse on both boards
    output reg [15:0]game_seed = 16'd1,    // never 0, so it is safe for an LFSR

    // End of match
    input ev_game_over,                    // this board decided the match is over
    input [1:0]winner_in,                  // 1 = Hider won, 2 = Seeker won
    input ev_menu,                         // back to the main menu from the end screen
    output reg game_over = 1'b0,           // the end screen is showing
    output reg [1:0]winner = 2'd0,

    // This board's player
    input signed [15:0]my_x,               // Q8.8 map cells
    input signed [15:0]my_y,
    input [7:0]my_dir,
    input [7:0]my_health,
    input my_paused,
    input my_frozen,  
    input [1:0]my_hand,                    // held item: 0 empty, 1 gun, 2 item

    // The other board's player
    output reg signed [15:0]peer_x = 16'sd0,
    output reg signed [15:0]peer_y = 16'sd0,
    output reg [7:0]peer_dir = 8'd0,
    output reg [7:0]peer_health = 8'd0,
    output reg peer_paused = 1'b0,
    output reg peer_frozen = 1'b0,
    output reg peer_in_game = 1'b0,
    output reg [1:0]peer_hand = 2'd0,
    output link_up,
    output game_paused,

    // Events caused by this board (one clock pulses)
    input ev_hit,                          // this player's shot hit the other player
    input [7:0]hit_damage,
    input ev_freeze,                       // Hider's Freeze Gun hit the Seeker
    input ev_ping,                         // Seeker used the Radio Pinger
    input ev_flash,                        // Hider threw a Flashbang
    input ev_capsule,                      // Hider took a Time Capsule
    input [7:0]capsule_id,
    input ev_restart,
    input state_change_valid,              // put the other player's FSM into player_state
    input [1:0]player_state,

    // Events caused by the other board (one clock pulses)
    output reg got_hit = 1'b0,
    output reg [7:0]got_hit_damage = 8'd0,
    output reg got_frozen = 1'b0,
    output reg got_pinged = 1'b0,
    output reg peer_flash_used = 1'b0,
    output reg peer_capsule = 1'b0,
    output reg [7:0]peer_capsule_id = 8'd0,
    output reg restart_game = 1'b0,        // pulses on both boards for a restart from either
    output reg got_state_change = 1'b0,    // the other board asks my FSM to enter got_player_state
    output reg [1:0]got_player_state = 2'd0,

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

    localparam [7:0]EV_START     = 8'd1;
    localparam [7:0]EV_HIT       = 8'd2;
    localparam [7:0]EV_FREEZE    = 8'd3;
    localparam [7:0]EV_PING      = 8'd4;
    localparam [7:0]EV_FLASH     = 8'd5;
    localparam [7:0]EV_CAPSULE   = 8'd6;
    localparam [7:0]EV_RESTART   = 8'd7;
    localparam [7:0]EV_GAME_OVER = 8'd8;
    localparam [7:0]EV_MENU      = 8'd9;
    localparam [7:0]EV_PSTATE    = 8'd10;
 
    localparam [1:0]MODE_MULTI  = 2'd2;

    localparam integer MAX_LEN     = 11;
    localparam integer CLKS_PER_MS = CLK_HZ / 1000;
    localparam integer RETRY_CLKS  = RETRY_MS * CLKS_PER_MS;
    localparam integer REVEAL_CLKS = REVEAL_MS * CLKS_PER_MS;

    function [1:0]other_role(input [1:0]r);
        other_role = (r == ROLE_HIDER) ? ROLE_SEEKER : ROLE_HIDER;
    endfunction

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

    // ---------------- Outgoing event queue (8 entries of {code, arg, arg2}) ----------------
    reg [31:0]queue [0:7];
    reg [2:0]q_head = 3'd0;
    reg [2:0]q_tail = 3'd0;
    reg [3:0]q_count = 4'd0;
    wire [7:0]head_code = queue[q_head][31:24];
    wire [15:0]head_arg = queue[q_head][23:8];
    wire [7:0]head_arg2 = queue[q_head][7:0];

    // Event requests waiting to enter the queue, so simultaneous pulses are not lost
    reg p_start = 1'b0, p_hit = 1'b0, p_freeze = 1'b0, p_ping = 1'b0;
    reg p_flash = 1'b0, p_capsule = 1'b0, p_restart = 1'b0;
    reg p_over = 1'b0, p_menu = 1'b0, p_pstate = 1'b0;
    reg [15:0]arg_start;
    reg [1:0]arg_start_role;
    reg [7:0]arg_hit;
    reg [7:0]arg_capsule;
    reg [1:0]arg_over;
    reg [1:0]arg_pstate;

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
    reg start_requested = 1'b0;   // master: START is queued for this menu
    reg start_next = 1'b0;        // my_role and game_seed are set: start on the next clock
    reg [15:0]free_count = 16'd0;
    reg [31:0]reveal_count = 32'd0;

    // ---------------- Master / slave election ----------------
    reg [31:0]sec_count = 32'd0;
    reg [15:0]uptime_s = 16'd0;   // seconds since this board was reset
    reg [4:0]nonce = 5'd0;        // random number for ties
    reg nonce_set = 1'b0;
    reg have_peer_state = 1'b0;   // a STATE has arrived since the link came up
    reg peer_decided = 1'b0;
    reg peer_master = 1'b0;
    reg peer_nonce_set = 1'b0;
    reg [4:0]peer_nonce = 5'd0;
    reg [15:0]peer_uptime = 16'd0;

    reg do_push;
    reg do_pop;
    reg [7:0]push_code;
    reg [15:0]push_arg;
    reg [7:0]push_arg2;

    wire [1:0]role_field = in_game ? my_role : my_pick;

    assign game_paused   = in_game && (my_paused || peer_paused || !link_up);
    assign reveal_active = (reveal_count != 32'd0);
    assign reveal_x      = peer_x;
    assign reveal_y      = peer_y;

    always @(posedge clk) begin
        send             <= 1'b0;
        start_game       <= 1'b0;
        got_hit          <= 1'b0;
        got_frozen       <= 1'b0;
        got_pinged       <= 1'b0;
        peer_flash_used  <= 1'b0;
        peer_capsule     <= 1'b0;
        restart_game     <= 1'b0;
        got_state_change <= 1'b0;
        free_count       <= free_count + 16'd1;
        do_push = 1'b0;
        do_pop  = 1'b0;

        if (reset) begin
            in_game         <= 1'b0;
            game_over       <= 1'b0;
            winner          <= 2'd0;
            my_role         <= 2'd0;
            q_head          <= 3'd0;
            q_tail          <= 3'd0;
            q_count         <= 4'd0;
            p_start         <= 1'b0;
            p_hit           <= 1'b0;
            p_freeze        <= 1'b0;
            p_ping          <= 1'b0;
            p_flash         <= 1'b0;
            p_capsule       <= 1'b0;
            p_restart       <= 1'b0;
            p_over          <= 1'b0;
            p_menu          <= 1'b0;
            p_pstate        <= 1'b0;
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
            start_next      <= 1'b0;
            reveal_count    <= 32'd0;
            peer_pick       <= 2'd0;
            peer_confirmed  <= 1'b0;
            peer_mode       <= 2'd0;
            peer_in_game    <= 1'b0;
            peer_paused     <= 1'b0;
            sec_count       <= 32'd0;
            uptime_s        <= 16'd0;
            nonce_set       <= 1'b0;
            is_master       <= 1'b0;
            master_decided  <= 1'b0;
            have_peer_state <= 1'b0;
            peer_decided    <= 1'b0;
        end else begin
            if (reveal_count != 32'd0)
                reveal_count <= reveal_count - 32'd1;

            // Uptime in seconds (stops at 65535, about 18 hours)
            if (sec_count == CLK_HZ - 1) begin
                sec_count <= 32'd0;
                if (uptime_s != 16'hFFFF)
                    uptime_s <= uptime_s + 16'd1;
            end else begin
                sec_count <= sec_count + 32'd1;
            end

            // ---------- Transmit: one packet at a time, ACKs first ----------
            if (!tx_busy && !send) begin
                if (ack_pending) begin
                    send         <= 1'b1;
                    send_type    <= TYPE_ACK;
                    send_seq     <= 8'd0;
                    send_len     <= 8'd1;
                    send_payload <= {80'd0, ack_seq};
                    ack_pending  <= 1'b0;
                end else if (ev_send_req && fresh_announced) begin
                    send         <= 1'b1;
                    send_type    <= TYPE_EVENT;
                    send_seq     <= ev_seq;
                    send_len     <= 8'd4;
                    send_payload <= {56'd0, head_arg2, head_arg[15:8], head_arg[7:0], head_code};
                    ev_send_req  <= 1'b0;
                    retry_count  <= 32'd0;
                end else if (state_due || !fresh_announced) begin
                    send         <= 1'b1;
                    send_type    <= TYPE_STATE;
                    send_seq     <= 8'd0;
                    send_len     <= 8'd11;
                    send_payload <= {4'd0, my_hand, my_mode, uptime_s[15:8], uptime_s[7:0],
                                     master_decided, is_master, nonce_set, nonce,
                                     in_game, my_paused, my_frozen, 1'b0, my_confirmed, fresh_boot, role_field,
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

            // ---------- Start the match one clock after my_role and game_seed are set ----------
            if (start_next) begin
                start_next <= 1'b0;
                in_game    <= 1'b1;
                start_game <= 1'b1;
                game_over  <= 1'b0;
            end

            // ---------- Receive ----------
            if (rx_error)
                rx_error_count <= rx_error_count + 8'd1;

            // A new random number the first time a packet arrives (the moment differs between boards)
            if (rx_valid && !nonce_set) begin
                nonce     <= free_count[4:0] ^ free_count[9:5];
                nonce_set <= 1'b1;
            end

            if (!link_up) begin
                have_peer_state <= 1'b0;
                peer_confirmed  <= 1'b0;
                peer_mode       <= 2'd0;
            end

            if (rx_valid) begin
                case (rx_type)
                    TYPE_STATE: begin
                        peer_x          <= {rx_payload[15:8], rx_payload[7:0]};
                        peer_y          <= {rx_payload[31:24], rx_payload[23:16]};
                        peer_dir        <= rx_payload[39:32];
                        peer_health     <= rx_payload[47:40];
                        peer_pick       <= rx_payload[49:48];
                        peer_fresh      <= rx_payload[50];
                        peer_confirmed  <= rx_payload[51];
                        peer_frozen     <= rx_payload[53];
                        peer_paused     <= rx_payload[54];
                        peer_in_game    <= rx_payload[55];
                        peer_nonce      <= rx_payload[60:56];
                        peer_nonce_set  <= rx_payload[61];
                        peer_master     <= rx_payload[62];
                        peer_decided    <= rx_payload[63];
                        peer_uptime     <= {rx_payload[79:72], rx_payload[71:64]};
                        peer_mode       <= rx_payload[81:80];
                        peer_hand       <= rx_payload[83:82];
                        have_peer_state <= 1'b1;
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
                            // The master starts when its START is acknowledged
                            if (head_code == EV_START && !in_game && !start_next) begin
                                my_role    <= head_arg2[1:0];
                                game_seed  <= head_arg;
                                start_next <= 1'b1;
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
                                    // The slave takes the role the master did not
                                    if (!in_game && !start_next) begin
                                        my_role    <= other_role(rx_payload[25:24]);
                                        game_seed  <= rx_payload[23:8];
                                        start_next <= 1'b1;
                                    end
                                end
                                EV_HIT: begin
                                    got_hit        <= 1'b1;
                                    got_hit_damage <= rx_payload[15:8];
                                end
                                EV_FREEZE:  got_frozen     <= 1'b1;
                                EV_PING:    got_pinged     <= 1'b1;
                                EV_FLASH:   peer_flash_used <= 1'b1;
                                EV_CAPSULE: begin
                                    peer_capsule    <= 1'b1;
                                    peer_capsule_id <= rx_payload[15:8];
                                end
                                EV_RESTART: begin
                                    restart_game    <= 1'b1;
                                    in_game         <= 1'b0;
                                    start_requested <= 1'b0;
                                end
                                EV_GAME_OVER: begin
                                    if (in_game) begin
                                        in_game   <= 1'b0;
                                        game_over <= 1'b1;
                                        winner    <= rx_payload[25:24];
                                    end else if (game_over && !is_master) begin
                                        winner    <= rx_payload[25:24];   // the master's verdict wins
                                    end
                                end
                                EV_MENU: begin
                                    if (game_over) begin
                                        game_over       <= 1'b0;
                                        start_requested <= 1'b0;
                                    end
                                end
                                EV_PSTATE: begin
                                    got_state_change <= 1'b1;
                                    got_player_state <= rx_payload[25:24];
                                end
                                default: ;
                            endcase
                        end
                    end

                    default: ;
                endcase
            end

            // ---------- Agree who is master ----------
            if (link_up && have_peer_state) begin
                if (!master_decided) begin
                    if (peer_decided) begin
                        is_master      <= !peer_master;           // join a board that has decided
                        master_decided <= 1'b1;
                    end else if ({1'b0, uptime_s} > {1'b0, peer_uptime} + 17'd1) begin
                        is_master      <= 1'b1;                   // I was switched on first
                        master_decided <= 1'b1;
                    end else if ({1'b0, peer_uptime} > {1'b0, uptime_s} + 17'd1) begin
                        is_master      <= 1'b0;
                        master_decided <= 1'b1;
                    end else if (nonce_set && peer_nonce_set) begin
                        if (nonce != peer_nonce) begin
                            is_master      <= (nonce > peer_nonce);
                            master_decided <= 1'b1;
                        end else begin
                            nonce_set <= 1'b0;                    // same number: pick again
                        end
                    end
                end else if (peer_decided && peer_master == is_master && nonce_set && peer_nonce_set) begin
                    // Both claim the same job: the nonce settles it
                    if (nonce != peer_nonce)
                        is_master <= (nonce > peer_nonce);
                    else
                        nonce_set <= 1'b0;
                end
            end

            // ---------- Move one waiting request into the queue ----------
            if (q_count != 4'd8) begin
                push_arg2 = 8'd0;
                if (p_restart) begin
                    do_push = 1'b1; push_code = EV_RESTART; push_arg = 16'd0; p_restart <= 1'b0;
                end else if (p_start) begin
                    do_push = 1'b1; push_code = EV_START; push_arg = arg_start;
                    push_arg2 = {6'd0, arg_start_role}; p_start <= 1'b0;
                end else if (p_over) begin
                    do_push = 1'b1; push_code = EV_GAME_OVER; push_arg = 16'd0;
                    push_arg2 = {6'd0, arg_over}; p_over <= 1'b0;
                end else if (p_menu) begin
                    do_push = 1'b1; push_code = EV_MENU; push_arg = 16'd0; p_menu <= 1'b0;
                end else if (p_hit) begin
                    do_push = 1'b1; push_code = EV_HIT; push_arg = {8'd0, arg_hit}; p_hit <= 1'b0;
                end else if (p_freeze) begin
                    do_push = 1'b1; push_code = EV_FREEZE; push_arg = 16'd0; p_freeze <= 1'b0;
                end else if (p_pstate) begin
                    do_push = 1'b1; push_code = EV_PSTATE; push_arg = 16'd0;
                    push_arg2 = {6'd0, arg_pstate}; p_pstate <= 1'b0;
                end else if (p_ping) begin
                    do_push = 1'b1; push_code = EV_PING; push_arg = 16'd0; p_ping <= 1'b0;
                end else if (p_flash) begin
                    do_push = 1'b1; push_code = EV_FLASH; push_arg = 16'd0; p_flash <= 1'b0;
                end else if (p_capsule) begin
                    do_push = 1'b1; push_code = EV_CAPSULE; push_arg = {8'd0, arg_capsule}; p_capsule <= 1'b0;
                end
            end

            if (do_push) begin
                queue[q_tail] <= {push_code, push_arg, push_arg2};
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
            if (ev_flash)   p_flash <= 1'b1;
            if (ev_capsule) begin p_capsule <= 1'b1; arg_capsule <= capsule_id; end
            if (state_change_valid) begin p_pstate <= 1'b1; arg_pstate <= player_state; end
            if (ev_restart) begin
                p_restart       <= 1'b1;
                restart_game    <= 1'b1;
                in_game         <= 1'b0;
                start_requested <= 1'b0;
            end
            if (ev_game_over && in_game) begin
                p_over    <= 1'b1;
                arg_over  <= winner_in;
                in_game   <= 1'b0;
                game_over <= 1'b1;
                winner    <= winner_in;
            end
            if (ev_menu && game_over) begin
                p_menu          <= 1'b1;
                game_over       <= 1'b0;
                start_requested <= 1'b0;
            end

            // Multiplayer: the master starts the match as soon as either player has
            // confirmed a role. The confirmed player keeps their pick (the master's
            // pick wins a tie); the slave takes whichever role the master did not.
            if (!in_game && !game_over && !start_next && !start_requested && link_up &&
                master_decided && is_master &&
                my_mode == MODE_MULTI && peer_mode == MODE_MULTI &&
                ((my_confirmed && my_pick != 2'd0) || (peer_confirmed && peer_pick != 2'd0))) begin
                p_start         <= 1'b1;
                arg_start       <= (free_count == 16'd0) ? 16'd1 : free_count;
                arg_start_role  <= (my_confirmed && my_pick != 2'd0) ? my_pick : other_role(peer_pick);
                start_requested <= 1'b1;
            end

            if (heartbeat)
                state_due <= 1'b1;
        end
    end
endmodule