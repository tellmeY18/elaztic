const std = @import("std");
const elaztic = @import("elaztic");

const BenchDoc = struct {
    id: u64,
    active: bool,
    module_id: u64,
    term: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configuration
    const doc_count: usize = 50_000;
    const batch_size: usize = 1000;

    std.debug.print("Bulk benchmark: {d} docs, batch size {d}\n", .{ doc_count, batch_size });

    // Create client
    var client = try elaztic.ESClient.init(allocator, .{
        .host = "localhost",
        .port = 9200,
        .retry_on_failure = 1,
        .retry_backoff_ms = 100,
        .compression = false,
    });
    defer client.deinit();

    // Create index
    const index = "bench-bulk";
    client.deleteIndex(index) catch {}; // clean up from previous run
    try client.createIndex(index, .{
        .settings = .{ .number_of_shards = 1, .number_of_replicas = 0 },
    });
    defer client.deleteIndex(index) catch {};

    // Benchmark
    var indexer = client.bulkIndexer(.{
        .max_docs = batch_size,
        .max_bytes = 10 * 1024 * 1024,
    });
    defer indexer.deinit();

    const start = std.time.nanoTimestamp();
    var total_flushed: usize = 0;
    var flush_count: usize = 0;
    var total_es_ms: u64 = 0;

    for (0..doc_count) |i| {
        var id_buf: [32]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&id_buf);
        fbs.writer().print("{d}", .{i}) catch unreachable;
        const id = fbs.getWritten();

        const doc = BenchDoc{
            .id = @as(u64, 100000000) + @as(u64, @intCast(i)),
            .active = (i % 2 == 0),
            .module_id = 900000000000207008,
            .term = "Benchmark concept for throughput testing",
        };

        if (try indexer.add(BenchDoc, index, id, doc)) |result| {
            total_flushed += result.total;
            total_es_ms += result.took_ms;
            flush_count += 1;
            var r = result;
            r.deinit();
        }
    }

    // Final flush
    if (indexer.pendingCount() > 0) {
        var result = try indexer.flush();
        total_flushed += result.total;
        total_es_ms += result.took_ms;
        flush_count += 1;
        result.deinit();
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_ms = elapsed_ns / 1_000_000;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const throughput = @as(f64, @floatFromInt(doc_count)) / elapsed_s;

    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("Total docs indexed: {d}\n", .{total_flushed});
    std.debug.print("Total flushes: {d}\n", .{flush_count});
    std.debug.print("Wall-clock time: {d}ms\n", .{elapsed_ms});
    std.debug.print("ES server time: {d}ms\n", .{total_es_ms});
    std.debug.print("Throughput: {d:.0} docs/sec\n", .{throughput});
    std.debug.print("Avg latency per flush: {d:.1}ms\n", .{@as(f64, @floatFromInt(total_es_ms)) / @as(f64, @floatFromInt(flush_count))});

    // Verify count
    try client.refresh(index);
    const count = try client.count(index, null);
    std.debug.print("Verified count: {d}\n", .{count});
}
