`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// seed_capture - match seed source (Andrew, world generation)
//
// Host board  : a free-running 16-bit counter is latched when sw0 is flipped
//               (either direction) or when menu_new_game pulses.  The latched
//               value becomes the match seed, is pulsed out locally on
//               seed/seed_valid, and is handed to Toh's link on tx_seed/tx_seed_valid.
// Client board: local sw0 flips do NOT make a seed.  The seed arrives from the
//               host over the link (rx_seed/rx_seed_valid) and is passed through.
// Single-player vs the AI bot: tie is_host = 1 (the link simply ignores tx).
//
// Input path for sw0: 2-FF synchroniser -> debounce (stable for DEBOUNCE_CYCLES)
//                     -> toggle detect (either edge) -> 1-cycle sw_toggled pulse.
// The switch position at power-up / reset is adopted silently, so a switch that
// is already up never fires a spurious "new match".
//
// Clock: oled_clk (6.25 MHz).  Reset: synchronous, active-high (btnC).
//////////////////////////////////////////////////////////////////////////////////
module seed_capture
#(
    parameter integer DEBOUNCE_CYCLES = 62_500,  // 10 ms at 6.25 MHz (set small in simulation)
    parameter [15:0]  ZERO_SUB        = 16'h0001 // used if the counter happens to be 0
)
(
    input             clk,
    input             reset,          // synchronous, active-high (btnC)
    input             sw_raw,         // sw[0] straight from the pin (asynchronous)
    input             is_host,        // 1 = this board makes the seed, 0 = take it from the link
    input             menu_new_game,  // 1-cycle pulse from a future menu "reset game" item (tie 0 for now)

    input      [15:0] rx_seed,        // from Toh's link (client side)
    input             rx_seed_valid,  // 1-cycle pulse from Toh's link

    output reg [15:0] tx_seed,        // to Toh's link (host side), held until the next seed
    output reg        tx_seed_valid,  // 1-cycle pulse: please send tx_seed
    output reg [15:0] seed,           // match seed for lfsr16 / map_gen, held until the next seed
    output reg        seed_valid,     // 1-cycle pulse: a new match starts with this seed
    output reg        sw_toggled      // 1-cycle pulse on every debounced sw0 flip (any role)
);

    // ------------------------------------------------------------------
    // Free-running counter: the entropy source.  It wraps every 10.5 ms, so
    // the value at the moment a human flips the switch is effectively random.
    // It is only ever read on the HOST at the moment of a flip; after that the
    // seed is fixed, so the sync rule (no free-running counters after the
    // seed is set) is respected.
    // ------------------------------------------------------------------
    reg [15:0] free_cnt = 16'd0;
    always @(posedge clk) begin
        if (reset) free_cnt <= 16'd0;
        else       free_cnt <= free_cnt + 16'd1;
    end

    // ------------------------------------------------------------------
    // 2-FF synchroniser.  sw_raw can change at any time relative to clk, so
    // the first flop may go metastable; the second gives it a full clock
    // period (160 ns) to settle.  ASYNC_REG tells Vivado to place the pair
    // close together.  Not reset: they just track the pin.
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg sw_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg sw_sync = 1'b0;
    always @(posedge clk) begin
        sw_meta <= sw_raw;
        sw_sync <= sw_meta;
    end

    // ------------------------------------------------------------------
    // Debounce + toggle detect.
    // sw_db is the accepted (debounced) switch state.  When sw_sync differs
    // from it, db_cnt counts; any bounce back to the old value clears db_cnt.
    // Only after DEBOUNCE_CYCLES consecutive cycles of the new value do we
    // accept it and fire sw_toggled.
    // init_cnt: for the first 3 cycles after power-up or reset, sw_db simply
    // copies sw_sync (the synchroniser needs 2 cycles to fill), so the
    // starting switch position never counts as a flip.
    // ------------------------------------------------------------------
    reg        sw_db    = 1'b0;
    reg [19:0] db_cnt   = 20'd0;   // 20 bits: enough for DEBOUNCE_CYCLES up to ~1M
    reg [1:0]  init_cnt = 2'd0;

    always @(posedge clk) begin
        if (reset) begin
            init_cnt   <= 2'd0;
            db_cnt     <= 20'd0;
            sw_db      <= sw_sync;
            sw_toggled <= 1'b0;
        end else begin
            sw_toggled <= 1'b0;                       // default: no pulse
            if (init_cnt != 2'd3) begin
                init_cnt <= init_cnt + 2'd1;
                sw_db    <= sw_sync;                  // adopt start position silently
                db_cnt   <= 20'd0;
            end else if (sw_sync == sw_db) begin
                db_cnt <= 20'd0;                      // stable at accepted value (or bounced back)
            end else if (db_cnt == DEBOUNCE_CYCLES - 1) begin
                sw_db      <= sw_sync;                // new position held long enough: accept it
                db_cnt     <= 20'd0;
                sw_toggled <= 1'b1;                   // either edge counts as "new match"
            end else begin
                db_cnt <= db_cnt + 20'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Seed latch.
    // Host  : on a flip or menu pulse, capture the counter (never 0) and
    //         pulse both seed_valid (local) and tx_seed_valid (to the link).
    // Client: ignore local flips; pass rx_seed through on rx_seed_valid.
    // ------------------------------------------------------------------
    wire [15:0] captured = (free_cnt == 16'd0) ? ZERO_SUB : free_cnt;

    always @(posedge clk) begin
        if (reset) begin
            seed          <= 16'd0;
            seed_valid    <= 1'b0;
            tx_seed       <= 16'd0;
            tx_seed_valid <= 1'b0;
        end else begin
            seed_valid    <= 1'b0;                    // default: pulses last one cycle
            tx_seed_valid <= 1'b0;
            if (is_host) begin
                if (sw_toggled || menu_new_game) begin
                    seed          <= captured;
                    seed_valid    <= 1'b1;
                    tx_seed       <= captured;        // same value both boards will use
                    tx_seed_valid <= 1'b1;
                end
            end else if (rx_seed_valid) begin
                seed       <= rx_seed;                // lfsr16 handles a 0 the same way on both boards
                seed_valid <= 1'b1;
            end
        end
    end

endmodule