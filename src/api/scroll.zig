//! Scroll API types and iterator for Elasticsearch/OpenSearch.
//!
//! This module provides request/response types for the `_search/scroll`
//! endpoint and a `ScrollIterator` that pages through arbitrarily large
//! result sets one page at a time, never buffering more than two pages
//! in memory simultaneously.
//!
//! ## Usage
//!
//! ```zig
//! var it = try ScrollIterator(Concept).init(
//!     allocator, &pool, true, "concepts", query, .{ .size = 100 }, "1m",
//! );
//! defer it.deinit();
//!
//! while (try it.next()) |hits| {
//!     for (hits) |hit| {
//!         // process hit._source
//!     }
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const pool_mod = @import("../pool.zig");
const ConnectionPool = pool_mod.ConnectionPool;
const HttpResponse = pool_mod.HttpResponse;
const deser = @import("../json/deserialize.zig");
const HitsEnvelope = deser.HitsEnvelope;
const Hit = deser.Hit;
const Query = @import("../query/builder.zig").Query;
const search_api = @import("search.zig");
const SearchOptions = search_api.SearchOptions;
const SourceFilter = @import("../query/source_filter.zig").SourceFilter;
const Aggregation = @import("../query/aggregation.zig").Aggregation;

/// Request to initiate a scrolling search against an Elasticsearch index.
///
/// This sends the initial `POST /<index>/_search?scroll=<duration>` request.
/// The response includes a `_scroll_id` that must be used for subsequent
/// page fetches via `ScrollNextRequest`.
pub const ScrollSearchRequest = struct {
    /// Target index name or pattern (e.g. `"concepts-*"`).
    index: []const u8,
    /// Scroll context keep-alive duration (e.g. `"1m"`, `"5m"`).
    scroll: []const u8,
    /// The query to execute. If `null`, the `"query"` key is omitted from the
    /// request body (Elasticsearch defaults to `match_all`).
    query: ?Query = null,
    /// Additional search options (size, from, source filtering, aggregations).
    options: SearchOptions = .{},

    /// Returns the HTTP method for this request.
    ///
    /// Scroll search always uses `POST` so that a JSON body can be included.
    pub fn httpMethod(_: ScrollSearchRequest) []const u8 {
        return "POST";
    }

    /// Returns the HTTP path for this request.
    ///
    /// Produces `"/<index>/_search?scroll=<duration>"`. The returned slice is
    /// allocated with `allocator`; the caller owns it and must free it.
    pub fn httpPath(self: ScrollSearchRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_search?scroll={s}", .{ self.index, self.scroll });
    }

    /// Builds the full JSON request body.
    ///
    /// Produces the same body shape as a regular `SearchRequest`: query, size,
    /// from, `_source`, and aggs keys are included when their corresponding
    /// option is non-null. Returns a caller-owned `[]u8`.
    pub fn httpBody(self: ScrollSearchRequest, allocator: Allocator) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var root = std.json.ObjectMap.init(aa);

        // query
        if (self.query) |q| {
            const q_value = try q.toJsonValue(aa);
            try root.put("query", q_value);
        }

        // size
        if (self.options.size) |s| {
            try root.put("size", .{ .integer = @intCast(s) });
        }

        // from
        if (self.options.from) |f| {
            try root.put("from", .{ .integer = @intCast(f) });
        }

        // _source
        if (self.options.source) |src| {
            const src_value = try src.toJsonValue(aa);
            try root.put("_source", src_value);
        }

        // aggs
        if (self.options.aggs) |aggs| {
            const aggs_value = try Aggregation.aggsToJsonValue(aggs, aa);
            try root.put("aggs", aggs_value);
        }

        const value: std.json.Value = .{ .object = root };
        const result = try std.json.Stringify.valueAlloc(allocator, value, .{});
        return @as(?[]u8, result);
    }
};

/// Request to fetch the next page of a scrolling search.
///
/// Sends `POST /_search/scroll` with the scroll context ID obtained from
/// a previous `ScrollSearchResponse` or `ScrollNextRequest` response.
pub const ScrollNextRequest = struct {
    /// The scroll context ID from the previous response's `_scroll_id` field.
    scroll_id: []const u8,
    /// Scroll context keep-alive duration (e.g. `"1m"`). This refreshes the
    /// timeout on each subsequent request.
    scroll: []const u8,

    /// Returns the HTTP method for this request.
    pub fn httpMethod(_: ScrollNextRequest) []const u8 {
        return "POST";
    }

    /// Returns the HTTP path for this request (`"/_search/scroll"`).
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpPath(_: ScrollNextRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/_search/scroll", .{});
    }

    /// Builds the JSON request body.
    ///
    /// Produces `{"scroll":"<duration>","scroll_id":"<id>"}`.
    /// Returns a caller-owned `[]u8`.
    pub fn httpBody(self: ScrollNextRequest, allocator: Allocator) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var root = std.json.ObjectMap.init(aa);
        try root.put("scroll", .{ .string = self.scroll });
        try root.put("scroll_id", .{ .string = self.scroll_id });

        const value: std.json.Value = .{ .object = root };
        const result = try std.json.Stringify.valueAlloc(allocator, value, .{});
        return @as(?[]u8, result);
    }
};

/// Request to clear a scroll context on the server.
///
/// Sends `DELETE /_search/scroll` with the scroll context ID. This frees
/// server-side resources associated with the scroll. Always call this when
/// done iterating (or let `ScrollIterator.deinit()` handle it).
pub const ClearScrollRequest = struct {
    /// The scroll context ID to clear.
    scroll_id: []const u8,

    /// Returns the HTTP method for this request.
    pub fn httpMethod(_: ClearScrollRequest) []const u8 {
        return "DELETE";
    }

    /// Returns the HTTP path for this request (`"/_search/scroll"`).
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpPath(_: ClearScrollRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/_search/scroll", .{});
    }

    /// Builds the JSON request body.
    ///
    /// Produces `{"scroll_id":"<id>"}`. Returns a caller-owned `[]u8`.
    pub fn httpBody(self: ClearScrollRequest, allocator: Allocator) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var root = std.json.ObjectMap.init(aa);
        try root.put("scroll_id", .{ .string = self.scroll_id });

        const value: std.json.Value = .{ .object = root };
        const result = try std.json.Stringify.valueAlloc(allocator, value, .{});
        return @as(?[]u8, result);
    }
};

/// Response from a scroll search (initial or subsequent page).
///
/// Extends the standard `SearchResponse` shape with a `_scroll_id` field
/// that must be passed to `ScrollNextRequest` to fetch the next page.
pub fn ScrollSearchResponse(comptime T: type) type {
    return struct {
        /// The scroll context ID for fetching the next page. This may change
        /// between responses — always use the most recently returned value.
        _scroll_id: ?[]const u8 = null,
        /// The hits envelope containing the current page of results.
        hits: HitsEnvelope(T),
        /// Milliseconds elapsed on the ES server side.
        took: ?u64 = null,
    };
}

/// An iterator that pages through scroll search results one page at a time.
///
/// Only two pages are ever held in memory simultaneously: the page whose hits
/// were most recently returned to the caller, and the page that was just
/// prefetched. When `next()` is called again, the older page is freed.
///
/// The caller **must** call `deinit()` when done to clear the server-side
/// scroll context and free all remaining memory.
///
/// Returned hit slices are valid until the next call to `next()` or `deinit()`.
pub fn ScrollIterator(comptime T: type) type {
    return struct {
        const Self = @This();
        const Response = ScrollSearchResponse(T);

        /// Allocator used for parsing responses and building request paths/bodies.
        allocator: Allocator,
        /// Connection pool used to send HTTP requests.
        pool: *ConnectionPool,
        /// Whether to use gzip compression on requests.
        compression: bool,
        /// Scroll keep-alive duration string (e.g. `"1m"`).
        scroll_duration: []const u8,
        /// The most recent scroll context ID from the server (owned copy).
        scroll_id: ?[]u8,
        /// The current (prefetched) page of results, or `null` if exhausted.
        current_page: ?std.json.Parsed(Response),
        /// The previous page whose hits were returned to the caller. Kept
        /// alive so the returned hit slice remains valid until the next
        /// `next()` call.
        previous_page: ?std.json.Parsed(Response),
        /// Whether the iterator has been exhausted.
        done: bool,

        /// Initialise a scroll iterator by sending the initial scroll search.
        ///
        /// This sends `POST /<index>/_search?scroll=<duration>` with the given
        /// query and options, parses the first page of results, and returns an
        /// iterator ready for use.
        ///
        /// If the initial response contains no hits, the iterator is
        /// immediately marked as done.
        pub fn init(
            allocator: Allocator,
            pool: *ConnectionPool,
            compression: bool,
            index: []const u8,
            query: ?Query,
            options: SearchOptions,
            scroll_duration: []const u8,
        ) !Self {
            // Build the initial scroll search request.
            const req = ScrollSearchRequest{
                .index = index,
                .scroll = scroll_duration,
                .query = query,
                .options = options,
            };

            const path = try req.httpPath(allocator);
            defer allocator.free(path);

            const body = try req.httpBody(allocator);
            defer if (body) |b| allocator.free(b);

            // Send the request.
            var http_response = try pool.sendRequest(
                allocator,
                req.httpMethod(),
                path,
                body,
                compression,
            );
            defer http_response.deinit(allocator);

            // Parse the response.
            const parsed = try deser.fromJson(Response, allocator, http_response.body);

            // Copy scroll_id into separately-owned memory so it outlives
            // the parsed response arena.
            const sid: ?[]u8 = if (parsed.value._scroll_id) |id|
                try allocator.dupe(u8, id)
            else
                null;

            // Check if there are any hits.
            const has_hits = parsed.value.hits.hits.len > 0;

            return .{
                .allocator = allocator,
                .pool = pool,
                .compression = compression,
                .scroll_duration = scroll_duration,
                .scroll_id = sid,
                .current_page = parsed,
                .previous_page = null,
                .done = !has_hits,
            };
        }

        /// Returns the next page of hits, or `null` when the result set is
        /// exhausted.
        ///
        /// The returned slice is valid until the next call to `next()` or
        /// `deinit()`. The caller must not store references to the slice
        /// beyond that lifetime.
        ///
        /// On each call, the previously returned page is freed and a new
        /// page is prefetched from the server.
        pub fn next(self: *Self) !?[]const Hit(T) {
            // Free the previous page (whose hits the caller has finished with).
            if (self.previous_page) |*prev| {
                prev.deinit();
                self.previous_page = null;
            }

            // If exhausted, nothing more to return.
            if (self.done) return null;

            // Take the current page — its hits are what we'll return.
            const current = self.current_page orelse return null;
            const hits = current.value.hits.hits;

            // If this page has no hits, we're done.
            if (hits.len == 0) {
                self.done = true;
                var page = self.current_page.?;
                page.deinit();
                self.current_page = null;
                return null;
            }

            // Move current to previous (keeps hits alive for the caller).
            self.previous_page = current;
            self.current_page = null;

            // Prefetch the next page using the scroll_id.
            if (self.scroll_id) |sid| {
                const scroll_req = ScrollNextRequest{
                    .scroll_id = sid,
                    .scroll = self.scroll_duration,
                };

                const path = try scroll_req.httpPath(self.allocator);
                defer self.allocator.free(path);

                const body = try scroll_req.httpBody(self.allocator);
                defer if (body) |b| self.allocator.free(b);

                var http_response = try self.pool.sendRequest(
                    self.allocator,
                    scroll_req.httpMethod(),
                    path,
                    body,
                    self.compression,
                );
                defer http_response.deinit(self.allocator);

                var parsed = try deser.fromJson(Response, self.allocator, http_response.body);

                // Update scroll_id (may change between responses).
                // Free old copy and allocate a new one.
                if (parsed.value._scroll_id) |new_sid| {
                    if (self.scroll_id) |old| self.allocator.free(old);
                    self.scroll_id = self.allocator.dupe(u8, new_sid) catch null;
                }

                // If the new page has no hits, mark as done but don't free
                // yet — we still need the current page's hits alive.
                if (parsed.value.hits.hits.len == 0) {
                    self.done = true;
                    parsed.deinit();
                } else {
                    self.current_page = parsed;
                }
            } else {
                // No scroll_id means we can't fetch more pages.
                self.done = true;
            }

            return hits;
        }

        /// Clean up the iterator, clearing the server-side scroll context
        /// and freeing all remaining parsed data.
        ///
        /// Errors from the `DELETE /_search/scroll` request are silently
        /// ignored — this is intentional, as `deinit` is typically called
        /// in a `defer` block where error propagation is not possible.
        pub fn deinit(self: *Self) void {
            // Free parsed pages first (before clearing scroll context),
            // because scroll_id is an independent copy.
            if (self.previous_page) |*prev| {
                prev.deinit();
                self.previous_page = null;
            }
            if (self.current_page) |*curr| {
                curr.deinit();
                self.current_page = null;
            }

            // Clear the server-side scroll context (best-effort).
            if (self.scroll_id) |sid| {
                self.clearScrollContext(sid);
                self.allocator.free(sid);
                self.scroll_id = null;
            }

            self.done = true;
        }

        /// Sends a `DELETE /_search/scroll` request to clear the scroll
        /// context. Errors are silently ignored.
        fn clearScrollContext(self: *Self, sid: []const u8) void {
            const clear_req = ClearScrollRequest{ .scroll_id = sid };

            const path = clear_req.httpPath(self.allocator) catch return;
            defer self.allocator.free(path);

            const body = clear_req.httpBody(self.allocator) catch return;
            defer if (body) |b| self.allocator.free(b);

            var http_response = self.pool.sendRequest(
                self.allocator,
                clear_req.httpMethod(),
                path,
                body,
                self.compression,
            ) catch return;
            http_response.deinit(self.allocator);
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Helper: parse a JSON byte slice into a `std.json.Value` tree.
fn parseJson(json_bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json_bytes, .{});
}

test "scroll search request method" {
    const req = ScrollSearchRequest{ .index = "concepts", .scroll = "1m" };
    try testing.expectEqualStrings("POST", req.httpMethod());
}

test "scroll search request path" {
    const req = ScrollSearchRequest{ .index = "concepts", .scroll = "1m" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/concepts/_search?scroll=1m", path);
}

test "scroll search request path with pattern index" {
    const req = ScrollSearchRequest{ .index = "concepts-*", .scroll = "5m" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/concepts-*/_search?scroll=5m", path);
}

test "scroll search request body with query and size" {
    const req = ScrollSearchRequest{
        .index = "concepts",
        .scroll = "1m",
        .query = Query.term("active", true),
        .options = .{ .size = 100 },
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Must have a "query" key containing a "term" object.
    const query_obj = root.get("query").?;
    try testing.expect(query_obj == .object);
    try testing.expect(query_obj.object.get("term") != null);

    // Must have a "size" key.
    try testing.expectEqual(@as(i64, 100), root.get("size").?.integer);

    // No from/_source/aggs keys.
    try testing.expect(root.get("from") == null);
    try testing.expect(root.get("_source") == null);
    try testing.expect(root.get("aggs") == null);
}

test "scroll search request body with no query" {
    const req = ScrollSearchRequest{
        .index = "concepts",
        .scroll = "1m",
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // No query key should be present — empty body.
    try testing.expect(root.get("query") == null);
    try testing.expect(root.count() == 0);
}

test "scroll search request body with all options" {
    const aggs = &[_]Aggregation{
        Aggregation.valueCount("total", "id"),
    };

    const req = ScrollSearchRequest{
        .index = "concepts",
        .scroll = "2m",
        .query = Query.matchAll(),
        .options = .{
            .size = 50,
            .from = 10,
            .source = .{ .includes = &.{"id"} },
            .aggs = aggs,
        },
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    try testing.expect(root.get("query") != null);
    try testing.expectEqual(@as(i64, 50), root.get("size").?.integer);
    try testing.expectEqual(@as(i64, 10), root.get("from").?.integer);
    try testing.expect(root.get("_source") != null);
    try testing.expect(root.get("aggs") != null);
}

test "scroll next request method" {
    const req = ScrollNextRequest{ .scroll_id = "abc123", .scroll = "1m" };
    try testing.expectEqualStrings("POST", req.httpMethod());
}

test "scroll next request path" {
    const req = ScrollNextRequest{ .scroll_id = "abc123", .scroll = "1m" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/_search/scroll", path);
}

test "scroll next request body" {
    const req = ScrollNextRequest{
        .scroll_id = "DXF1ZXJ5QW5kRmV0Y2gBAAAAAAAAAD4WYm9laVYtZndUQlNsdDcwakFMNjU1QQ==",
        .scroll = "1m",
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    try testing.expectEqualStrings("1m", root.get("scroll").?.string);
    try testing.expectEqualStrings(
        "DXF1ZXJ5QW5kRmV0Y2gBAAAAAAAAAD4WYm9laVYtZndUQlNsdDcwakFMNjU1QQ==",
        root.get("scroll_id").?.string,
    );
}

test "clear scroll request method" {
    const req = ClearScrollRequest{ .scroll_id = "abc123" };
    try testing.expectEqualStrings("DELETE", req.httpMethod());
}

test "clear scroll request path" {
    const req = ClearScrollRequest{ .scroll_id = "abc123" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/_search/scroll", path);
}

test "clear scroll request body" {
    const req = ClearScrollRequest{
        .scroll_id = "DXF1ZXJ5QW5kRmV0Y2gBAAAAAAAAAD4WYm9laVYtZndUQlNsdDcwakFMNjU1QQ==",
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    try testing.expectEqualStrings(
        "DXF1ZXJ5QW5kRmV0Y2gBAAAAAAAAAD4WYm9laVYtZndUQlNsdDcwakFMNjU1QQ==",
        root.get("scroll_id").?.string,
    );
    // Should only contain scroll_id.
    try testing.expectEqual(@as(usize, 1), root.count());
}

test "scroll search response deserialization" {
    const Concept = struct {
        id: u64,
        active: bool,
    };

    const json =
        \\{
        \\  "_scroll_id": "DXF1ZXJ5QW5kRmV0Y2gBAAAAAAAAAD4WYm9laVYtZndUQlNsdDcwakFMNjU1QQ==",
        \\  "took": 12,
        \\  "timed_out": false,
        \\  "hits": {
        \\    "total": {"value": 100, "relation": "eq"},
        \\    "hits": [
        \\      {
        \\        "_index": "concepts",
        \\        "_id": "12345",
        \\        "_score": 1.0,
        \\        "_source": {"id": 12345, "active": true}
        \\      },
        \\      {
        \\        "_index": "concepts",
        \\        "_id": "67890",
        \\        "_score": 1.0,
        \\        "_source": {"id": 67890, "active": false}
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var parsed = try deser.fromJson(ScrollSearchResponse(Concept), testing.allocator, json);
    defer parsed.deinit();

    const resp = parsed.value;

    try testing.expectEqualStrings(
        "DXF1ZXJ5QW5kRmV0Y2gBAAAAAAAAAD4WYm9laVYtZndUQlNsdDcwakFMNjU1QQ==",
        resp._scroll_id.?,
    );
    try testing.expectEqual(@as(u64, 12), resp.took.?);
    try testing.expectEqual(@as(u64, 100), resp.hits.total.?.value);
    try testing.expectEqual(@as(usize, 2), resp.hits.hits.len);

    try testing.expectEqual(@as(u64, 12345), resp.hits.hits[0]._source.?.id);
    try testing.expectEqual(true, resp.hits.hits[0]._source.?.active);
    try testing.expectEqual(@as(u64, 67890), resp.hits.hits[1]._source.?.id);
    try testing.expectEqual(false, resp.hits.hits[1]._source.?.active);
}

test "scroll search response with no scroll_id" {
    const Simple = struct {
        id: u64,
    };

    const json =
        \\{
        \\  "took": 1,
        \\  "hits": {
        \\    "total": {"value": 0, "relation": "eq"},
        \\    "hits": []
        \\  }
        \\}
    ;

    var parsed = try deser.fromJson(ScrollSearchResponse(Simple), testing.allocator, json);
    defer parsed.deinit();

    try testing.expect(parsed.value._scroll_id == null);
    try testing.expectEqual(@as(usize, 0), parsed.value.hits.hits.len);
}
