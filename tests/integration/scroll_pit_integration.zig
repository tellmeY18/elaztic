//! Integration tests for the Scroll and PIT APIs (M6).
//!
//! These tests run against a real Elasticsearch/OpenSearch instance.
//! They require the ES_URL environment variable to be set.
//! Tests are skipped automatically if ES_URL is not set.
//!
//! Run with: zig build test-integration

const std = @import("std");
const elaztic = @import("elaztic");
const Query = elaztic.query.Query;
const pit = elaztic.pit;
const deser = elaztic.deserialize;

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
    const prefix = "test-scroll-pit-";
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

/// Bulk-index `count` Concept documents into the given index.
/// If `active_all` is true, all docs have `active=true`.
/// If `active_all` is false, every other doc is inactive (even indices active, odd inactive).
fn indexDocs(client: *elaztic.ESClient, index: []const u8, count: u32, active_all: bool) !void {
    var indexer = client.bulkIndexer(.{ .max_docs = 500 });
    defer indexer.deinit();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const doc = Concept{
            .id = @as(u64, i) + 1,
            .active = if (active_all) true else (i % 2 == 0),
            .module_id = 900000000000207008,
            .term = "Test concept",
        };
        const result = try indexer.add(Concept, index, null, doc);
        if (result) |r| {
            var r_mut = r;
            r_mut.deinit();
        }
    }
    var final = try indexer.flush();
    final.deinit();
}

// ---------------------------------------------------------------------------
// Scroll tests
// ---------------------------------------------------------------------------

test "integration_scroll_basic" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_scroll_basic] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 25 documents
    try indexDocs(&client, index_name, 25, true);
    try refreshIndex(&client, index_name);

    // Scroll through with page size 10
    var iter = try client.scrollSearch(Concept, index_name, null, .{ .size = 10 }, "1m");
    defer iter.deinit();

    var total: usize = 0;
    var pages: usize = 0;
    while (try iter.next()) |hits| {
        pages += 1;
        total += hits.len;
        std.debug.print("  scroll page {d}: {d} hits\n", .{ pages, hits.len });
    }

    std.debug.print("  total hits: {d} across {d} pages\n", .{ total, pages });
    try std.testing.expectEqual(@as(usize, 25), total);
    try std.testing.expectEqual(@as(usize, 3), pages);
}

test "integration_scroll_with_query" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_scroll_with_query] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 20 docs with alternating active/inactive
    try indexDocs(&client, index_name, 20, false);
    try refreshIndex(&client, index_name);

    // Scroll with a term query for active=true only
    const q = Query.term("active", true);
    var iter = try client.scrollSearch(Concept, index_name, q, .{ .size = 5 }, "1m");
    defer iter.deinit();

    var total: usize = 0;
    var pages: usize = 0;
    while (try iter.next()) |hits| {
        pages += 1;
        total += hits.len;
        std.debug.print("  scroll page {d}: {d} hits\n", .{ pages, hits.len });

        // Verify all returned docs are active
        for (hits) |hit| {
            if (hit._source) |src| {
                try std.testing.expect(src.active);
            }
        }
    }

    std.debug.print("  total active hits: {d} across {d} pages\n", .{ total, pages });
    // 20 docs with alternating active: indices 0,2,4,6,8,10,12,14,16,18 = 10 active
    try std.testing.expectEqual(@as(usize, 10), total);
}

test "integration_scroll_empty_result" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_scroll_empty_result] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Refresh empty index
    try refreshIndex(&client, index_name);

    // Scroll on empty index
    var iter = try client.scrollSearch(Concept, index_name, null, .{ .size = 10 }, "1m");
    defer iter.deinit();

    // First next() should return null immediately
    const first_page = try iter.next();
    try std.testing.expect(first_page == null);

    std.debug.print("  empty scroll: OK (null on first next)\n", .{});
}

test "integration_scroll_single_page" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_scroll_single_page] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 5 docs
    try indexDocs(&client, index_name, 5, true);
    try refreshIndex(&client, index_name);

    // Scroll with size=10 — all 5 should fit in one page
    var iter = try client.scrollSearch(Concept, index_name, null, .{ .size = 10 }, "1m");
    defer iter.deinit();

    // First page should have all 5 hits
    const first_page = try iter.next();
    try std.testing.expect(first_page != null);
    try std.testing.expectEqual(@as(usize, 5), first_page.?.len);
    std.debug.print("  first page: {d} hits\n", .{first_page.?.len});

    // Second next() should return null
    const second_page = try iter.next();
    try std.testing.expect(second_page == null);

    std.debug.print("  single page scroll: OK\n", .{});
}

test "integration_scroll_large_dataset" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_scroll_large_dataset] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 500 documents
    try indexDocs(&client, index_name, 500, true);
    try refreshIndex(&client, index_name);

    // Scroll with page size 50
    var iter = try client.scrollSearch(Concept, index_name, null, .{ .size = 50 }, "1m");
    defer iter.deinit();

    var total: usize = 0;
    var pages: usize = 0;
    while (try iter.next()) |hits| {
        pages += 1;
        total += hits.len;
    }

    std.debug.print("  total hits: {d} across {d} pages\n", .{ total, pages });
    try std.testing.expectEqual(@as(usize, 500), total);
    try std.testing.expectEqual(@as(usize, 10), pages);
}

test "integration_scroll_auto_clear" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_scroll_auto_clear] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 25 docs
    try indexDocs(&client, index_name, 25, true);
    try refreshIndex(&client, index_name);

    // Start scroll with size=10
    var iter = try client.scrollSearch(Concept, index_name, null, .{ .size = 10 }, "1m");

    // Get only the first page
    const first_page = try iter.next();
    try std.testing.expect(first_page != null);
    try std.testing.expectEqual(@as(usize, 10), first_page.?.len);
    std.debug.print("  got first page: {d} hits\n", .{first_page.?.len});

    // Call deinit without consuming all pages — should clear scroll context without error
    iter.deinit();

    std.debug.print("  auto-clear on partial scroll: OK\n", .{});
}

// ---------------------------------------------------------------------------
// PIT tests
// ---------------------------------------------------------------------------

test "integration_pit_open_close" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_pit_open_close] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Refresh so the index is ready
    try refreshIndex(&client, index_name);

    // Open PIT
    const pit_id = try client.openPit(index_name, "5m");
    defer allocator.free(pit_id);

    std.debug.print("  pit_id length: {d}\n", .{pit_id.len});
    try std.testing.expect(pit_id.len > 0);

    // Close PIT — should not error
    try client.closePit(pit_id);

    std.debug.print("  open/close PIT: OK\n", .{});
}

test "integration_pit_basic" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_pit_basic] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 25 documents
    try indexDocs(&client, index_name, 25, true);
    try refreshIndex(&client, index_name);

    // PIT search with page size 10
    var iter = try client.pitSearch(Concept, index_name, null, 10, "1m");
    defer iter.deinit();

    var total: usize = 0;
    var pages: usize = 0;
    while (try iter.next()) |hits| {
        pages += 1;
        total += hits.len;
        std.debug.print("  PIT page {d}: {d} hits\n", .{ pages, hits.len });
    }

    std.debug.print("  total PIT hits: {d} across {d} pages\n", .{ total, pages });
    try std.testing.expectEqual(@as(usize, 25), total);
}

test "integration_pit_with_query" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_pit_with_query] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 20 docs with alternating active/inactive
    try indexDocs(&client, index_name, 20, false);
    try refreshIndex(&client, index_name);

    // PIT search with term query for active=true only, page size 5
    const q = Query.term("active", true);
    var iter = try client.pitSearch(Concept, index_name, q, 5, "1m");
    defer iter.deinit();

    var total: usize = 0;
    var pages: usize = 0;
    while (try iter.next()) |hits| {
        pages += 1;
        total += hits.len;
        std.debug.print("  PIT page {d}: {d} hits\n", .{ pages, hits.len });

        // Verify all returned docs are active
        for (hits) |hit| {
            if (hit._source) |src| {
                try std.testing.expect(src.active);
            }
        }
    }

    std.debug.print("  total active PIT hits: {d} across {d} pages\n", .{ total, pages });
    // 20 docs with alternating active: indices 0,2,4,6,8,10,12,14,16,18 = 10 active
    try std.testing.expectEqual(@as(usize, 10), total);
}

test "integration_pit_empty_result" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_pit_empty_result] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Refresh empty index
    try refreshIndex(&client, index_name);

    // PIT search on empty index
    var iter = try client.pitSearch(Concept, index_name, null, 10, "1m");
    defer iter.deinit();

    // First next() should return null immediately
    const first_page = try iter.next();
    try std.testing.expect(first_page == null);

    std.debug.print("  empty PIT search: OK (null on first next)\n", .{});
}

test "integration_pit_auto_close" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    var client = try createClient(allocator);
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_pit_auto_close] index: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index 25 docs
    try indexDocs(&client, index_name, 25, true);
    try refreshIndex(&client, index_name);

    // PIT search with page size 10
    var iter = try client.pitSearch(Concept, index_name, null, 10, "1m");

    // Get only the first page
    const first_page = try iter.next();
    try std.testing.expect(first_page != null);
    std.debug.print("  got first PIT page: {d} hits\n", .{first_page.?.len});

    // Call deinit without consuming all pages — should close PIT without error
    iter.deinit();

    std.debug.print("  auto-close on partial PIT iteration: OK\n", .{});
}
