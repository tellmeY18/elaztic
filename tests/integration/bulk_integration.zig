//! Integration tests for the BulkIndexer against Elasticsearch (OpenSearch).
//!
//! Each test creates a unique index, performs bulk operations via `ESClient`
//! and `BulkIndexer`, asserts results, and tears down the index.
//!
//! Requires `ES_URL` to be set (e.g. `ES_URL=http://localhost:9200`).
//! Tests are skipped automatically if `ES_URL` is not set.

const std = @import("std");
const elaztic = @import("elaztic");

// ---------------------------------------------------------------------------
// Test document type
// ---------------------------------------------------------------------------

const Concept = struct {
    id: u64,
    active: bool,
    module_id: u64,
    term: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Check whether ES_URL is set. Returns the owned string or null (skips test).
fn getEsUrl(allocator: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "ES_URL") catch {
        std.debug.print("SKIP: ES_URL not set\n", .{});
        return null;
    };
}

/// Generate a unique index name using random hex characters.
fn generateIndexName(buf: []u8) []const u8 {
    const prefix = "test-bulk-";
    @memcpy(buf[0..prefix.len], prefix);

    const hex_chars = "0123456789abcdef";
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var pos: usize = prefix.len;
    for (random_bytes) |b| {
        if (pos + 2 > buf.len) break;
        buf[pos] = hex_chars[b >> 4];
        buf[pos + 1] = hex_chars[b & 0x0f];
        pos += 2;
    }
    return buf[0..pos];
}

/// Create an ESClient configured for localhost:9200, compression disabled.
fn createClient(allocator: std.mem.Allocator) !elaztic.ESClient {
    return try elaztic.ESClient.init(allocator, .{
        .host = "localhost",
        .port = 9200,
        .retry_on_failure = 1,
        .retry_backoff_ms = 10,
        .compression = false,
    });
}

/// Create a test index with a single shard (good for deterministic counts).
fn createTestIndex(client: *elaztic.ESClient, index: []const u8) !void {
    try client.createIndex(index, .{
        .settings = .{ .number_of_shards = 1, .number_of_replicas = 0 },
    });
}

/// Delete a test index, ignoring errors (best-effort cleanup).
fn deleteTestIndex(client: *elaztic.ESClient, index: []const u8) void {
    client.deleteIndex(index) catch {};
}

/// Refresh an index so recently indexed documents are searchable.
fn refreshIndex(client: *elaztic.ESClient, index: []const u8) !void {
    try client.refresh(index);
}

/// Count documents in an index.
fn countDocs(client: *elaztic.ESClient, index: []const u8) !u64 {
    return try client.count(index, null);
}

/// Build a test Concept for a given index.
fn makeConcept(i: usize) Concept {
    return Concept{
        .id = @as(u64, 100000000) + @as(u64, @intCast(i)),
        .active = (i % 2 == 0),
        .module_id = 900000000000207008,
        .term = "Test concept",
    };
}

/// Format a document ID string into a stack buffer.
fn formatId(buf: []u8, i: usize) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    fbs.writer().print("{d}", .{i}) catch return "0";
    return fbs.getWritten();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "integration_bulk_index_basic" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_bulk_index_basic] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Create bulk indexer with default config (won't auto-flush for 10 docs)
    var indexer = client.bulkIndexer(.{ .max_docs = 1000 });
    defer indexer.deinit();

    // Add 10 documents
    for (0..10) |i| {
        var id_buf: [32]u8 = undefined;
        const id = formatId(&id_buf, i + 1);
        const doc = makeConcept(i);
        const auto_result = try indexer.add(Concept, index_name, id, doc);
        // Should not auto-flush with max_docs=1000
        try std.testing.expect(auto_result == null);
    }

    try std.testing.expectEqual(@as(usize, 10), indexer.pendingCount());
    try std.testing.expect(indexer.pendingBytes() > 0);

    // Flush
    var result = try indexer.flush();
    defer result.deinit();

    std.debug.print("  bulk result: total={d} succeeded={d} failed={d} took={d}ms\n", .{
        result.total, result.succeeded, result.failed, result.took_ms,
    });

    try std.testing.expectEqual(@as(usize, 10), result.total);
    try std.testing.expectEqual(@as(usize, 10), result.succeeded);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expect(!result.hasFailures());

    // After flush, pending should be zero
    try std.testing.expectEqual(@as(usize, 0), indexer.pendingCount());

    // Refresh and count
    try refreshIndex(&client, index_name);
    const doc_count = try countDocs(&client, index_name);
    std.debug.print("  doc count: {d}\n", .{doc_count});
    try std.testing.expectEqual(@as(u64, 10), doc_count);
}

test "integration_bulk_auto_flush" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_bulk_auto_flush] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Create bulk indexer with max_docs=5 to trigger auto-flush
    var indexer = client.bulkIndexer(.{ .max_docs = 5 });
    defer indexer.deinit();

    var auto_flush_result: ?elaztic.BulkResult = null;

    // Add 7 documents — auto-flush should trigger at doc 5
    for (0..7) |i| {
        var id_buf: [32]u8 = undefined;
        const id = formatId(&id_buf, i + 1);
        const doc = makeConcept(i);
        const maybe_result = try indexer.add(Concept, index_name, id, doc);
        if (maybe_result) |r| {
            // Auto-flush triggered — should happen at doc 5
            std.debug.print("  auto-flush at doc {d}: total={d} succeeded={d}\n", .{
                i + 1, r.total, r.succeeded,
            });
            try std.testing.expectEqual(@as(usize, 5), r.total);
            try std.testing.expectEqual(@as(usize, 5), r.succeeded);
            auto_flush_result = r;
        }
    }

    // Auto-flush must have happened
    try std.testing.expect(auto_flush_result != null);
    auto_flush_result.?.deinit();

    // 2 docs should remain pending
    try std.testing.expectEqual(@as(usize, 2), indexer.pendingCount());

    // Flush remaining
    var remaining_result = try indexer.flush();
    defer remaining_result.deinit();

    std.debug.print("  remaining flush: total={d} succeeded={d}\n", .{
        remaining_result.total, remaining_result.succeeded,
    });
    try std.testing.expectEqual(@as(usize, 2), remaining_result.total);
    try std.testing.expectEqual(@as(usize, 2), remaining_result.succeeded);

    // Refresh and verify total count
    try refreshIndex(&client, index_name);
    const doc_count = try countDocs(&client, index_name);
    std.debug.print("  doc count: {d}\n", .{doc_count});
    try std.testing.expectEqual(@as(u64, 7), doc_count);
}

test "integration_bulk_mixed_actions" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_bulk_mixed_actions] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Phase 1: Bulk index 3 documents
    {
        var indexer = client.bulkIndexer(.{ .max_docs = 1000 });
        defer indexer.deinit();

        _ = try indexer.add(Concept, index_name, "1", Concept{
            .id = 100000001,
            .active = true,
            .module_id = 900000000000207008,
            .term = "Concept one",
        });
        _ = try indexer.add(Concept, index_name, "2", Concept{
            .id = 100000002,
            .active = true,
            .module_id = 900000000000207008,
            .term = "Concept two",
        });
        _ = try indexer.add(Concept, index_name, "3", Concept{
            .id = 100000003,
            .active = false,
            .module_id = 900000000000207008,
            .term = "Concept three",
        });

        var result = try indexer.flush();
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 3), result.total);
        try std.testing.expectEqual(@as(usize, 3), result.succeeded);
    }

    try refreshIndex(&client, index_name);
    const count_after_insert = try countDocs(&client, index_name);
    std.debug.print("  count after initial insert: {d}\n", .{count_after_insert});
    try std.testing.expectEqual(@as(u64, 3), count_after_insert);

    // Phase 2: Delete doc "1", add doc "4" in a single bulk
    {
        var indexer = client.bulkIndexer(.{ .max_docs = 1000 });
        defer indexer.deinit();

        _ = try indexer.addDelete(index_name, "1");
        _ = try indexer.add(Concept, index_name, "4", Concept{
            .id = 100000004,
            .active = true,
            .module_id = 900000000000207008,
            .term = "Concept four",
        });

        var result = try indexer.flush();
        defer result.deinit();

        std.debug.print("  mixed actions result: total={d} succeeded={d} failed={d}\n", .{
            result.total, result.succeeded, result.failed,
        });
        try std.testing.expectEqual(@as(usize, 2), result.total);
        try std.testing.expectEqual(@as(usize, 2), result.succeeded);
        try std.testing.expectEqual(@as(usize, 0), result.failed);
    }

    try refreshIndex(&client, index_name);
    const count_after_mixed = try countDocs(&client, index_name);
    std.debug.print("  count after mixed actions: {d}\n", .{count_after_mixed});
    // Deleted 1, added 1: 3 - 1 + 1 = 3
    try std.testing.expectEqual(@as(u64, 3), count_after_mixed);
}

test "integration_bulk_large_batch" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_bulk_large_batch] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Bulk index 1000 documents in one flush
    var indexer = client.bulkIndexer(.{ .max_docs = 2000 }); // high threshold to prevent auto-flush
    defer indexer.deinit();

    for (0..1000) |i| {
        var id_buf: [32]u8 = undefined;
        const id = formatId(&id_buf, i + 1);
        const doc = makeConcept(i);
        const auto_result = try indexer.add(Concept, index_name, id, doc);
        try std.testing.expect(auto_result == null);
    }

    try std.testing.expectEqual(@as(usize, 1000), indexer.pendingCount());

    var result = try indexer.flush();
    defer result.deinit();

    std.debug.print("  large batch result: total={d} succeeded={d} failed={d} took={d}ms\n", .{
        result.total, result.succeeded, result.failed, result.took_ms,
    });

    try std.testing.expectEqual(@as(usize, 1000), result.total);
    try std.testing.expectEqual(@as(usize, 1000), result.succeeded);
    try std.testing.expectEqual(@as(usize, 0), result.failed);

    // Refresh and count
    try refreshIndex(&client, index_name);
    const doc_count = try countDocs(&client, index_name);
    std.debug.print("  doc count: {d}\n", .{doc_count});
    try std.testing.expectEqual(@as(u64, 1000), doc_count);
}

test "integration_bulk_byte_threshold" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_bulk_byte_threshold] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Create bulk indexer with a very low byte threshold so auto-flush triggers
    // on size rather than doc count. Each doc + action line is roughly ~150 bytes,
    // so 500 bytes should trigger after a few docs.
    var indexer = client.bulkIndexer(.{
        .max_docs = 10000, // very high — won't trigger on count
        .max_bytes = 500, // very low — will trigger on size
    });
    defer indexer.deinit();

    var auto_flush_count: usize = 0;

    for (0..10) |i| {
        var id_buf: [32]u8 = undefined;
        const id = formatId(&id_buf, i + 1);
        const doc = makeConcept(i);
        const maybe_result = try indexer.add(Concept, index_name, id, doc);
        if (maybe_result) |r| {
            std.debug.print("  byte-threshold auto-flush at doc {d}: total={d} bytes_before={d}\n", .{
                i + 1, r.total, 0, // buffer was already reset
            });
            auto_flush_count += 1;
            var result_copy = r;
            result_copy.deinit();
        }
    }

    // Auto-flush must have triggered at least once due to the 500-byte limit
    std.debug.print("  auto-flush triggered {d} time(s)\n", .{auto_flush_count});
    try std.testing.expect(auto_flush_count > 0);

    // Flush any remaining
    var final_result = try indexer.flush();
    defer final_result.deinit();

    // Refresh and verify all 10 docs made it
    try refreshIndex(&client, index_name);
    const doc_count = try countDocs(&client, index_name);
    std.debug.print("  doc count: {d}\n", .{doc_count});
    try std.testing.expectEqual(@as(u64, 10), doc_count);
}

test "integration_bulk_empty_flush" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    std.debug.print("\n  [integration_bulk_empty_flush]\n", .{});

    // Create bulk indexer — no index needed since we won't send anything
    var indexer = client.bulkIndexer(.{});
    defer indexer.deinit();

    try std.testing.expectEqual(@as(usize, 0), indexer.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), indexer.pendingBytes());

    // Flush with nothing pending — should return zero result, no error
    var result = try indexer.flush();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.total);
    try std.testing.expectEqual(@as(usize, 0), result.succeeded);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(u64, 0), result.took_ms);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
    try std.testing.expect(!result.hasFailures());
    try std.testing.expect(result._response == null);

    std.debug.print("  empty flush: OK (no error, zero result)\n", .{});
}
