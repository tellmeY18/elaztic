//! Bulk Indexing Example
//!
//! Demonstrates using the BulkIndexer to batch-index documents
//! with auto-flush on threshold.

const std = @import("std");
const elaztic = @import("elaztic");

const Concept = struct {
    id: u64,
    active: bool,
    module_id: u64,
    term: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try elaztic.ESClient.init(allocator, .{});
    defer client.deinit();

    const index = "elaztic-example-bulk-index";
    client.createIndex(index, .{
        .settings = .{ .number_of_shards = 1, .number_of_replicas = 0 },
    }) catch |err| {
        std.debug.print("Note: createIndex returned {}\n", .{err});
    };
    defer client.deleteIndex(index) catch {};

    // Create a bulk indexer with a low threshold to demonstrate auto-flush
    var indexer = client.bulkIndexer(.{ .max_docs = 100 });
    defer indexer.deinit();

    var timer = std.time.Timer.start() catch unreachable;

    // Index 500 documents
    const total_docs: usize = 500;
    for (0..total_docs) |i| {
        var term_buf: [32]u8 = undefined;
        const term_str = std.fmt.bufPrint(&term_buf, "Concept {d}", .{i}) catch unreachable;

        const doc = Concept{
            .id = 100000000 + i,
            .active = i % 5 != 0, // 80% active
            .module_id = 900000000000207008,
            .term = term_str,
        };

        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{doc.id}) catch unreachable;

        // Auto-flushes when max_docs (100) is reached
        var auto_result = try indexer.add(Concept, index, id_str, doc);
        if (auto_result) |*r| {
            std.debug.print("Auto-flush: {d} succeeded, {d} failed\n", .{ r.succeeded, r.failed });
            r.deinit();
        }
    }

    // Flush remaining documents
    var final_result = try indexer.flush();
    defer final_result.deinit();

    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    std.debug.print("\nBulk indexing complete:\n", .{});
    std.debug.print("  Total docs: {d}\n", .{total_docs});
    std.debug.print("  Final flush: {d} succeeded, {d} failed\n", .{
        final_result.succeeded,
        final_result.failed,
    });
    std.debug.print("  Time: {d}ms\n", .{elapsed_ms});

    if (final_result.hasFailures()) {
        std.debug.print("  WARNING: some documents failed to index\n", .{});
    }

    // Verify
    try client.refresh(index);
    const doc_count = try client.count(index, null);
    std.debug.print("  Verified doc count: {d}\n", .{doc_count});
}
