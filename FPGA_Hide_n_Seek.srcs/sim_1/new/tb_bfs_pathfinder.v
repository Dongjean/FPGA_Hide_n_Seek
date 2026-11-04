`timescale 1ns / 1ps
// Checks bfs_pathfinder against a reference breadth-first search written in the
// testbench, on the team's default map plus 100 random 10x10 maps (solid border,
// about 30% random walls), each from a random source cell. Every cell's distance
// must match. Also reports the longest search time in clocks.

module tb_bfs_pathfinder;
    localparam integer W = 10, H = 10, N = 100;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;
    reg [N-1:0]map_bits;
    reg start = 1'b0;
    reg [3:0]src_x, src_y, qx, qy;
    wire busy, done;
    wire [7:0]qdist;

    bfs_pathfinder #(.MAP_W(W), .MAP_H(H)) dut (
        .clk(clk), .reset(reset), .map_bits(map_bits), .start(start), .src_x(src_x), .src_y(src_y),
        .busy(busy), .done(done), .query_x(qx), .query_y(qy), .query_dist(qdist)
    );

    localparam [99:0]TEAM_MAP = {
        10'b1111111111, 10'b1010001001, 10'b1010001001, 10'b1010011001, 10'b1010010001,
        10'b1000000001, 10'b1100011001, 10'b1000010001, 10'b1000010001, 10'b1111111111
    };

    function wall(input integer x, input integer y);
        begin wall = map_bits[N - 1 - (y * W + x)]; end
    endfunction

    // Reference BFS
    integer ref_dist [0:N-1];
    integer rq [0:N-1];
    integer head, tail, c, x, y, k, nxr, nyr;
    task reference_bfs;
        begin
            for (c = 0; c < N; c = c + 1) ref_dist[c] = 255;
            head = 0; tail = 0;
            if (!wall(src_x, src_y)) begin
                ref_dist[src_y * W + src_x] = 0;
                rq[tail] = src_y * W + src_x; tail = tail + 1;
            end
            while (head < tail) begin
                c = rq[head]; head = head + 1;
                x = c % W; y = c / W;
                for (k = 0; k < 4; k = k + 1) begin
                    nxr = x + ((k == 1) ? 1 : (k == 3) ? -1 : 0);
                    nyr = y + ((k == 2) ? 1 : (k == 0) ? -1 : 0);
                    if (nxr >= 0 && nxr < W && nyr >= 0 && nyr < H)
                        if (!wall(nxr, nyr) && ref_dist[nyr * W + nxr] == 255) begin
                            ref_dist[nyr * W + nxr] = ref_dist[c] + 1;
                            rq[tail] = nyr * W + nxr; tail = tail + 1;
                        end
                end
            end
        end
    endtask

    integer errors = 0, m, cycles, max_cycles = 0, reachable_total = 0;
    initial begin
        repeat (3) @(posedge clk);
        reset = 1'b0;
        for (m = 0; m <= 100; m = m + 1) begin
            if (m == 0) map_bits = TEAM_MAP;
            else begin
                for (y = 0; y < H; y = y + 1)
                    for (x = 0; x < W; x = x + 1)
                        map_bits[N - 1 - (y * W + x)] =
                            (x == 0 || y == 0 || x == W - 1 || y == H - 1) ? 1'b1 : (($random & 7) < 2);
            end
            src_x = 1 + ($random & 32'h7FFF) % 8;
            src_y = 1 + ($random & 32'h7FFF) % 8;
            if (m == 0) begin src_x = 5; src_y = 5; end
            reference_bfs;

            @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0;
            cycles = 1;
            while (!done) begin @(negedge clk); cycles = cycles + 1; end
            if (cycles > max_cycles) max_cycles = cycles;

            for (y = 0; y < H; y = y + 1)
                for (x = 0; x < W; x = x + 1) begin
                    qx = x; qy = y; #1;
                    if (qdist !== ref_dist[y * W + x][7:0]) begin
                        if (errors < 10) $display("FAIL map %0d cell (%0d,%0d): got %0d expected %0d", m, x, y, qdist, ref_dist[y * W + x]);
                        errors = errors + 1;
                    end
                    if (ref_dist[y * W + x] != 255) reachable_total = reachable_total + 1;
                end
        end
        if (errors == 0) $display("PASS tb_bfs_pathfinder: 101 maps, all 10,100 distances match; longest search %0d clocks", max_cycles);
        else             $display("FAIL tb_bfs_pathfinder: %0d wrong distances", errors);
        $finish;
    end
endmodule
