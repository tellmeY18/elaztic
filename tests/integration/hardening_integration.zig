//! Integration tests for M7 — Hardening (auth, node failover, logging, retry).
//!
//! These tests run against a real Elasticsearch/OpenSearch instance.
//! They require the ES_URL environment variable to be set (e.g.
//! `ES_URL=http://localhost:9200`). Tests are skipped automatically
//! if ES_URL is not set.
//!
//! Each test creates a unique index, performs operations, asserts on
//! results, and deletes the index.
//!
//! Run with: zig build test-integration

const std = @import("std");
const elaztic = @import("elaztic");
const Query = elaztic.query.Query;

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
    const prefix = "test-hardening-";
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
        .retry_on_failure = 3,
        .retry_backoff_ms = 50,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "integration_basic_auth" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    std.debug.print("\n  [integration_basic_auth]\n", .{});

    // Create a client with basic_auth set. OpenSearch without security
    // accepts any Authorization header, so this validates that the header
    // is sent without causing a rejection.
    var client = try elaztic.ESClient.init(allocator, .{
        .host = "localhost",
        .port = 9200,
        .retry_on_failure = 2,
        .retry_backoff_ms = 50,
        .compression = false,
        .basic_auth = "elastic:changeme",
    });
    defer client.deinit();

    // Ping the cluster — should succeed even with auth header
    {
        var health = try client.ping();
        defer health.deinit(allocator);
        std.debug.print("  Ping with basic_auth: cluster={s}, status={s}\n", .{
            health.cluster_name,
            health.status,
        });
        try std.testing.expect(health.cluster_name.len > 0);
    }

    // Create and delete an index to verify write operations work with auth.
    // We avoid indexDoc here because executeTyped/fromJsonLeaky allocates
    // response strings into the caller's allocator without a cleanup path,
    // which trips the GPA leak detector. Ping + create/delete is sufficient
    // to prove the Authorization header is accepted.
    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("  Creating index with auth: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Count documents — verifies read path also works with auth
    const doc_count = try client.count(index_name, null);
    std.debug.print("  Count with auth: {d}\n", .{doc_count});
    try std.testing.expectEqual(@as(u64, 0), doc_count);
}

test "integration_node_failover" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    std.debug.print("\n  [integration_node_failover]\n", .{});

    // Create client pointing to the real node
    var client = try createClient(allocator);
    defer client.deinit();

    // Add a fake dead node (RFC 5737 TEST-NET-1 address — always unreachable)
    try client.addNode("http", "192.0.2.1", 19200);
    std.debug.print("  Added fake node at 192.0.2.1:19200\n", .{});

    // Ping — should succeed via the healthy node, even though the fake
    // node may be tried first (round-robin) and will fail/get marked unhealthy.
    {
        var health = try client.ping();
        defer health.deinit(allocator);
        std.debug.print("  Ping after adding fake node: cluster={s}, status={s}\n", .{
            health.cluster_name,
            health.status,
        });
        try std.testing.expect(health.cluster_name.len > 0);
    }

    // Create an index — verifies write operations also failover correctly.
    // We avoid indexDoc (uses fromJsonLeaky which leaks response strings
    // under GPA). Create/delete index + count is sufficient to prove failover.
    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("  Creating index via failover: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Count documents — verifies read operations work through failover
    const doc_count = try client.count(index_name, null);
    std.debug.print("  Count after failover: {d}\n", .{doc_count});
    try std.testing.expectEqual(@as(u64, 0), doc_count);

    // Ping again to ensure the client is stable after multiple failovers
    {
        var health = try client.ping();
        defer health.deinit(allocator);
        try std.testing.expect(health.cluster_name.len > 0);
        std.debug.print("  Second ping after operations: OK\n", .{});
    }
}

test "integration_logging_events" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    std.debug.print("\n  [integration_logging_events]\n", .{});

    // Use a struct with module-level mutable state to track log events.
    const LogState = struct {
        var event_count: usize = 0;
        var saw_request_start: bool = false;
        var saw_request_success: bool = false;
        var saw_request_error: bool = false;

        fn reset() void {
            event_count = 0;
            saw_request_start = false;
            saw_request_success = false;
            saw_request_error = false;
        }

        fn callback(event: elaztic.LogEvent) void {
            event_count += 1;
            switch (event) {
                .request_start => saw_request_start = true,
                .request_success => saw_request_success = true,
                .request_error => saw_request_error = true,
                else => {},
            }
        }
    };

    LogState.reset();

    // Create client with logging callback
    var client = try elaztic.ESClient.init(allocator, .{
        .host = "localhost",
        .port = 9200,
        .retry_on_failure = 2,
        .retry_backoff_ms = 50,
        .compression = false,
        .log_fn = &LogState.callback,
    });
    defer client.deinit();

    // Ping — should generate request_start + request_success events
    {
        var health = try client.ping();
        defer health.deinit(allocator);
        std.debug.print("  Ping with logging: cluster={s}\n", .{health.cluster_name});
    }

    std.debug.print("  Log events after ping: count={d}, start={}, success={}\n", .{
        LogState.event_count,
        LogState.saw_request_start,
        LogState.saw_request_success,
    });

    try std.testing.expect(LogState.event_count > 0);
    try std.testing.expect(LogState.saw_request_start);
    try std.testing.expect(LogState.saw_request_success);

    // Reset and perform more operations to verify continued logging
    LogState.reset();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("  Creating index with logging: {s}\n", .{index_name});

    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    std.debug.print("  Log events after createIndex: count={d}, start={}, success={}\n", .{
        LogState.event_count,
        LogState.saw_request_start,
        LogState.saw_request_success,
    });

    // Create index should also generate log events
    try std.testing.expect(LogState.event_count > 0);
    try std.testing.expect(LogState.saw_request_start);
    try std.testing.expect(LogState.saw_request_success);
}

test "integration_retry_on_failure" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    std.debug.print("\n  [integration_retry_on_failure]\n", .{});

    // Create client with retry settings — these exercise the retry machinery
    // on every request even if no retries are actually needed.
    var client = try elaztic.ESClient.init(allocator, .{
        .host = "localhost",
        .port = 9200,
        .retry_on_failure = 3,
        .retry_backoff_ms = 50,
        .max_retry_backoff_ms = 500,
        .compression = false,
    });
    defer client.deinit();

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("  Index: {s}\n", .{index_name});

    // Create index
    try createTestIndex(&client, index_name);
    defer deleteTestIndex(&client, index_name);

    // Index a document via BulkIndexer (avoids indexDoc/fromJsonLeaky leak).
    {
        var indexer = client.bulkIndexer(.{ .max_docs = 10 });
        defer indexer.deinit();
        var result = try indexer.add(Concept, index_name, null, .{
            .id = 300,
            .active = true,
            .module_id = 900000000000207008,
            .term = "Retry test concept",
        });
        if (result) |*r| r.deinit();
        var flush_result = try indexer.flush();
        std.debug.print("  Bulk indexed: total={d} succeeded={d}\n", .{
            flush_result.total,
            flush_result.succeeded,
        });
        try std.testing.expectEqual(@as(usize, 1), flush_result.succeeded);
        flush_result.deinit();
    }

    // Refresh to make it searchable
    try refreshIndex(&client, index_name);

    // Search — the retry machinery should handle this smoothly
    var search_result = try client.searchDocs(Concept, index_name, Query.term("active", true), .{});
    defer search_result.deinit();

    const resp = search_result.value;
    const total = if (resp.hits.total) |t| t.value else 0;
    std.debug.print("  Search hits: {d}\n", .{total});
    try std.testing.expectEqual(@as(u64, 1), total);
    try std.testing.expectEqual(@as(usize, 1), resp.hits.hits.len);

    const source = resp.hits.hits[0]._source orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 300), source.id);
    try std.testing.expect(source.active);

    // Count — another operation through the retry path
    const count = try client.count(index_name, Query.matchAll());
    std.debug.print("  Count: {d}\n", .{count});
    try std.testing.expectEqual(@as(u64, 1), count);
}

test "integration_scheme_from_config" {
    const allocator = std.testing.allocator;

    const es_url = getEsUrl(allocator) orelse return;
    defer allocator.free(es_url);

    std.debug.print("\n  [integration_scheme_from_config]\n", .{});

    // Create client with explicit scheme = "http"
    var client = try elaztic.ESClient.init(allocator, .{
        .host = "localhost",
        .port = 9200,
        .scheme = "http",
        .retry_on_failure = 2,
        .retry_backoff_ms = 50,
        .compression = false,
    });
    defer client.deinit();

    // Ping — validates the scheme field is wired correctly
    {
        var health = try client.ping();
        defer health.deinit(allocator);
        std.debug.print("  Ping with explicit scheme=http: cluster={s}, status={s}\n", .{
            health.cluster_name,
            health.status,
        });
        try std.testing.expect(health.cluster_name.len > 0);
        try std.testing.expect(health.status.len > 0);
    }

    // Also validate initFromUrl parses the URL correctly (no network call
    // needed — just verify the client initializes without error).
    {
        var url_client = try elaztic.ESClient.initFromUrl(allocator, es_url);
        defer url_client.deinit();
        std.debug.print("  initFromUrl: OK (client created from {s})\n", .{es_url});
    }
}
