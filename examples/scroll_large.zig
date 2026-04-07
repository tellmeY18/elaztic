//! Scroll Large Result Set Example
//!
//! Demonstrates using ScrollIterator and PitIterator to page through
//! large result sets without buffering everything in memory.

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

    const index = "elaztic-example-scroll";
    client.createIndex(index, .{
        .settings = .{ .number_of_shards = 1, .number_of_replicas = 0 },
    }) catch |err| {
        std.debug.print("Note: createIndex returned {}\n", .{err});
    };
    defer client.deleteIndex(index) catch {};

    // Bulk-index 200 documents
    std.debug.print("Indexing 200 documents...\n", .{});
    var indexer = client.bulkIndexer(.{ .max_docs = 500 });
    defer indexer.deinit();

    for (0..200) |i| {
        var term_buf: [32]u8 = undefined;
        const term_str = std.fmt.bufPrint(&term_buf, "Concept {d}", .{i}) catch unreachable;

        const doc = Concept{
            .id = 200000000 + i,
            .active = true,
            .module_id = 900000000000207008,
            .term = term_str,
        };

        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{doc.id}) catch unreachable;

        // BulkIndexer.add takes (comptime T, index, id, doc) — serializes internally
        var auto_result = try indexer.add(Concept, index, id_str, doc);
        if (auto_result) |*r| r.deinit();
    }

    var flush_result = try indexer.flush();
    flush_result.deinit();
    try client.refresh(index);

    // --- Scroll through all results ---
    std.debug.print("\n=== ScrollIterator (page size = 50) ===\n", .{});
    {
        var iter = try client.scrollSearch(Concept, index, null, .{ .size = 50 }, "1m");
        defer iter.deinit(); // auto-clears server-side scroll context

        var page: usize = 0;
        var total_hits: usize = 0;

        while (try iter.next()) |hits| {
            page += 1;
            total_hits += hits.len;
            std.debug.print("  Page {d}: {d} hits\n", .{ page, hits.len });
        }

        std.debug.print("  Total: {d} hits across {d} pages\n", .{ total_hits, page });
    }

    // --- PIT-based iteration ---
    std.debug.print("\n=== PitIterator (page size = 50) ===\n", .{});
    {
        var iter = try client.pitSearch(Concept, index, null, 50, "5m");
        defer iter.deinit(); // auto-closes PIT

        var page: usize = 0;
        var total_hits: usize = 0;

        while (try iter.next()) |hits| {
            page += 1;
            total_hits += hits.len;
            std.debug.print("  Page {d}: {d} hits\n", .{ page, hits.len });
        }

        std.debug.print("  Total: {d} hits across {d} pages\n", .{ total_hits, page });
    }
}
