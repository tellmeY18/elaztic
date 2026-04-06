//! Bulk indexer for Elasticsearch.
//!
//! Batches documents into NDJSON and flushes to the `_bulk` endpoint when
//! thresholds (doc count or byte size) are exceeded. The internal buffer is
//! a single contiguous `ArrayList(u8)` — no per-document heap allocation.
//!
//! To avoid a circular import with `client.zig`, the indexer stores a pointer
//! to the `ConnectionPool` and a compression flag directly, rather than a
//! pointer to `ESClient`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ser = @import("../json/serialize.zig");
const bulk_parse = @import("bulk.zig");
const pool_mod = @import("../pool.zig");

/// Configuration for the bulk indexer.
pub const BulkConfig = struct {
    /// Maximum number of actions to buffer before auto-flushing.
    max_docs: usize = 1000,
    /// Maximum byte size of the NDJSON buffer before auto-flushing.
    max_bytes: usize = 5 * 1024 * 1024, // 5 MB
    /// Flush interval in milliseconds. Null = manual flush only.
    /// (Timer-based flush not yet implemented — reserved for future use.)
    flush_interval_ms: ?u64 = null,
};

/// Result of a bulk flush operation.
pub const BulkResult = struct {
    /// Total number of actions in this flush.
    total: usize,
    /// Number of actions that succeeded (2xx status).
    succeeded: usize,
    /// Number of actions that failed.
    failed: usize,
    /// Time in milliseconds the bulk request took on the server.
    took_ms: u64,
    /// Per-action results. Points into `_response` memory.
    items: []bulk_parse.BulkItemResult,
    /// Underlying `BulkResponse` that owns the items memory. Null for empty flushes.
    _response: ?bulk_parse.BulkResponse,

    /// Returns `true` if any actions failed.
    pub fn hasFailures(self: BulkResult) bool {
        return self.failed > 0;
    }

    /// Free all memory owned by this result.
    pub fn deinit(self: *BulkResult) void {
        if (self._response) |*resp| {
            resp.deinit();
        }
        self.* = undefined;
    }
};

/// A bulk indexer that batches documents and flushes them to the `_bulk` endpoint.
///
/// Documents are serialized into NDJSON (newline-delimited JSON) inside a
/// single `ArrayList(u8)` buffer. When the number of buffered actions reaches
/// `config.max_docs`, or the buffer byte-size reaches `config.max_bytes`, the
/// indexer automatically flushes the buffer to Elasticsearch via the
/// `ConnectionPool`.
///
/// The caller is responsible for calling `flush()` before `deinit()` if any
/// pending actions remain — `deinit` does **not** auto-flush.
pub const BulkIndexer = struct {
    /// Allocator used for the NDJSON buffer and intermediate serialization.
    allocator: Allocator,
    /// Connection pool used to send the `_bulk` request.
    pool: *pool_mod.ConnectionPool,
    /// Whether to request gzip compression on the HTTP transport.
    compression: bool,
    /// Thresholds that govern auto-flushing behaviour.
    config: BulkConfig,
    /// Internal NDJSON buffer. Grows as documents are added.
    buffer: std.ArrayList(u8),
    /// Number of actions (index / delete) currently buffered.
    action_count: usize,

    /// Create a new bulk indexer.
    ///
    /// The indexer does **not** own `connection_pool` — the caller must ensure
    /// the pool outlives the indexer.
    pub fn init(
        allocator: Allocator,
        connection_pool: *pool_mod.ConnectionPool,
        compression: bool,
        config: BulkConfig,
    ) BulkIndexer {
        return .{
            .allocator = allocator,
            .pool = connection_pool,
            .compression = compression,
            .config = config,
            .buffer = .{},
            .action_count = 0,
        };
    }

    /// Free the internal buffer.
    ///
    /// Does **not** auto-flush — the caller must call `flush()` first if any
    /// pending actions should be sent.
    pub fn deinit(self: *BulkIndexer) void {
        self.buffer.deinit(self.allocator);
    }

    /// Number of buffered actions not yet flushed.
    pub fn pendingCount(self: BulkIndexer) usize {
        return self.action_count;
    }

    /// Byte size of the buffered NDJSON payload.
    pub fn pendingBytes(self: BulkIndexer) usize {
        return self.buffer.items.len;
    }

    /// Add a document to the bulk buffer. Serializes `doc` to JSON via
    /// `serialize.toJson`.
    ///
    /// Returns a `BulkResult` if auto-flush was triggered, `null` otherwise.
    pub fn add(self: *BulkIndexer, comptime T: type, index: []const u8, id: ?[]const u8, doc: T) !?BulkResult {
        const json_bytes = try ser.toJson(self.allocator, doc);
        defer self.allocator.free(json_bytes);
        return self.addRaw(index, id, json_bytes);
    }

    /// Add pre-serialized JSON to the bulk buffer (no double-serialization).
    ///
    /// Returns a `BulkResult` if auto-flush was triggered, `null` otherwise.
    pub fn addRaw(self: *BulkIndexer, index: []const u8, id: ?[]const u8, json_bytes: []const u8) !?BulkResult {
        try self.appendActionLine("index", index, id);
        try self.appendSourceLine(json_bytes);
        self.action_count += 1;
        return try self.autoFlushIfNeeded();
    }

    /// Add a delete action to the bulk buffer (no source line).
    ///
    /// Returns a `BulkResult` if auto-flush was triggered, `null` otherwise.
    pub fn addDelete(self: *BulkIndexer, index: []const u8, id: []const u8) !?BulkResult {
        try self.appendActionLine("delete", index, id);
        self.action_count += 1;
        return try self.autoFlushIfNeeded();
    }

    /// Flush all buffered actions to Elasticsearch.
    ///
    /// If nothing is pending, returns a zero-valued result immediately
    /// (no network call).
    pub fn flush(self: *BulkIndexer) !BulkResult {
        if (self.action_count == 0) {
            return BulkResult{
                .total = 0,
                .succeeded = 0,
                .failed = 0,
                .took_ms = 0,
                .items = &.{},
                ._response = null,
            };
        }

        const ndjson_body = self.buffer.items;
        const count = self.action_count;

        const response = try self.pool.sendRequest(
            self.allocator,
            "POST",
            "/_bulk",
            ndjson_body,
            self.compression,
        );

        // Reset buffer after sending — even on parse failure we don't
        // want to re-send the same batch.
        self.buffer.clearRetainingCapacity();
        self.action_count = 0;

        if (response.status_code >= 200 and response.status_code < 300) {
            // `parseBulkResponse` takes ownership of `response.body` on
            // success (it frees the slice after copying data into its arena).
            var bulk_response = bulk_parse.parseBulkResponse(self.allocator, response.body) catch {
                return error.MalformedJson;
            };

            const total = bulk_response.items.len;
            const failed = bulk_response.failureCount();

            return BulkResult{
                .total = total,
                .succeeded = total - failed,
                .failed = failed,
                .took_ms = bulk_response.took,
                .items = bulk_response.items,
                ._response = bulk_response,
            };
        } else {
            // On non-2xx we own the body — free it and report an error that
            // includes the count of actions that were dropped.
            _ = count;
            self.allocator.free(response.body);
            return error.UnexpectedResponse;
        }
    }

    // -----------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------

    /// Trigger an automatic flush when either threshold is exceeded.
    fn autoFlushIfNeeded(self: *BulkIndexer) !?BulkResult {
        if (self.action_count >= self.config.max_docs or
            self.buffer.items.len >= self.config.max_bytes)
        {
            return try self.flush();
        }
        return null;
    }

    /// Append the NDJSON action/metadata line.
    ///
    /// Format: `{"<action>":{"_index":"<index>"[,"_id":"<id>"]}}\n`
    fn appendActionLine(self: *BulkIndexer, action: []const u8, index: []const u8, id: ?[]const u8) !void {
        const w = self.buffer.writer(self.allocator);
        try w.writeAll("{\"");
        try w.writeAll(action);
        try w.writeAll("\":{\"_index\":\"");
        try w.writeAll(index);
        try w.writeAll("\"");
        if (id) |doc_id| {
            try w.writeAll(",\"_id\":\"");
            try w.writeAll(doc_id);
            try w.writeAll("\"");
        }
        try w.writeAll("}}\n");
    }

    /// Append the source document JSON line followed by a newline.
    fn appendSourceLine(self: *BulkIndexer, json_bytes: []const u8) !void {
        const w = self.buffer.writer(self.allocator);
        try w.writeAll(json_bytes);
        try w.writeAll("\n");
    }
};

// ===========================================================================
// Unit tests
// ===========================================================================

fn makeTestPool(allocator: Allocator) !pool_mod.ConnectionPool {
    return try pool_mod.ConnectionPool.init(allocator, .{
        .host = "localhost",
        .port = 9200,
        .retry_on_failure = 1,
        .retry_backoff_ms = 10,
    });
}

test "bulk indexer init and deinit" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    try std.testing.expectEqual(@as(usize, 0), indexer.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), indexer.pendingBytes());
}

test "bulk indexer addRaw builds correct NDJSON" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    const result = try indexer.addRaw("test", "1", "{\"id\":1}");
    try std.testing.expect(result == null); // no auto-flush

    const expected =
        "{\"index\":{\"_index\":\"test\",\"_id\":\"1\"}}\n" ++
        "{\"id\":1}\n";
    try std.testing.expectEqualStrings(expected, indexer.buffer.items);
}

test "bulk indexer addDelete builds correct NDJSON" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    const result = try indexer.addDelete("test", "1");
    try std.testing.expect(result == null);

    const expected = "{\"delete\":{\"_index\":\"test\",\"_id\":\"1\"}}\n";
    try std.testing.expectEqualStrings(expected, indexer.buffer.items);
}

test "bulk indexer pending count tracks adds" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    _ = try indexer.addRaw("idx", "a", "{}");
    _ = try indexer.addRaw("idx", "b", "{}");
    _ = try indexer.addRaw("idx", "c", "{}");

    try std.testing.expectEqual(@as(usize, 3), indexer.pendingCount());
    try std.testing.expect(indexer.pendingBytes() > 0);
}

test "bulk indexer add without id" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    _ = try indexer.addRaw("test", null, "{\"x\":1}");

    const expected =
        "{\"index\":{\"_index\":\"test\"}}\n" ++
        "{\"x\":1}\n";
    try std.testing.expectEqualStrings(expected, indexer.buffer.items);

    // Verify there is no `_id` key at all.
    try std.testing.expect(std.mem.indexOf(u8, indexer.buffer.items, "_id") == null);
}

test "bulk indexer mixed actions" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    _ = try indexer.addRaw("products", "42", "{\"name\":\"widget\"}");
    _ = try indexer.addDelete("products", "99");

    try std.testing.expectEqual(@as(usize, 2), indexer.pendingCount());

    const expected =
        "{\"index\":{\"_index\":\"products\",\"_id\":\"42\"}}\n" ++
        "{\"name\":\"widget\"}\n" ++
        "{\"delete\":{\"_index\":\"products\",\"_id\":\"99\"}}\n";
    try std.testing.expectEqualStrings(expected, indexer.buffer.items);
}

test "bulk indexer empty flush returns zero result" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    var result = try indexer.flush();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.total);
    try std.testing.expectEqual(@as(usize, 0), result.succeeded);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(u64, 0), result.took_ms);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
    try std.testing.expect(!result.hasFailures());
    try std.testing.expect(result._response == null);
}

test "bulk indexer NDJSON ends with newline" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    _ = try indexer.addRaw("idx", "1", "{\"a\":1}");
    _ = try indexer.addDelete("idx", "2");

    const buf = indexer.buffer.items;
    try std.testing.expect(buf.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), buf[buf.len - 1]);
}

test "bulk indexer add with typed doc" {
    var pool_inst = try makeTestPool(std.testing.allocator);
    defer pool_inst.deinit();

    var indexer = BulkIndexer.init(std.testing.allocator, &pool_inst, false, .{});
    defer indexer.deinit();

    const Concept = struct {
        id: u64,
        active: bool,
    };

    const doc = Concept{ .id = 138875005, .active = true };
    const result = try indexer.add(Concept, "concepts", "138875005", doc);
    try std.testing.expect(result == null);

    // The action line must reference the correct index and id.
    const buf = indexer.buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"_index\":\"concepts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"_id\":\"138875005\"") != null);

    // The source line must contain the serialized struct fields.
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"id\":138875005") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"active\":true") != null);

    try std.testing.expectEqual(@as(usize, 1), indexer.pendingCount());
}

test "bulk result hasFailures" {
    // No failures.
    {
        var result = BulkResult{
            .total = 5,
            .succeeded = 5,
            .failed = 0,
            .took_ms = 42,
            .items = &.{},
            ._response = null,
        };
        try std.testing.expect(!result.hasFailures());

        // deinit is safe even with null _response.
        result.deinit();
    }

    // Has failures.
    {
        var result = BulkResult{
            .total = 5,
            .succeeded = 3,
            .failed = 2,
            .took_ms = 100,
            .items = &.{},
            ._response = null,
        };
        try std.testing.expect(result.hasFailures());
        result.deinit();
    }
}
