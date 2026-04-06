//! Point-in-Time (PIT) API types and iterator for Elasticsearch/OpenSearch.
//!
//! This module provides request/response types for the PIT lifecycle
//! (`PitOpenRequest`, `PitCloseRequest`) and a `PitSearchRequest` for
//! searching with a PIT context. The `PitIterator` pages through
//! arbitrarily large result sets using `search_after` without buffering
//! more than one page of hits in memory at a time.
//!
//! PIT is preferred over the scroll API for read-heavy queries because it
//! does not hold a search context open on every shard; instead, it uses
//! lightweight `search_after` pagination against a frozen point-in-time
//! snapshot.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pool_mod = @import("../pool.zig");
const deser = @import("../json/deserialize.zig");
const Query = @import("../query/builder.zig").Query;

// ---------------------------------------------------------------------------
// Sort specification
// ---------------------------------------------------------------------------

/// A single sort clause for Elasticsearch queries.
///
/// Each `SortField` specifies a field name and an order (`"asc"` or `"desc"`).
/// Multiple sort fields can be combined to form the `sort` array in a search
/// request.
pub const SortField = struct {
    /// The field to sort on (e.g. `"_doc"`, `"timestamp"`, `"_score"`).
    field: []const u8,
    /// Sort direction: `"asc"` or `"desc"`.
    order: []const u8,
};

// ---------------------------------------------------------------------------
// PIT Open
// ---------------------------------------------------------------------------

/// Request to open a Point-in-Time on an index.
///
/// Opening a PIT creates a lightweight, frozen snapshot of the index that
/// subsequent searches can target. The PIT is kept alive for the specified
/// `keep_alive` duration and must be explicitly closed when no longer needed.
pub const PitOpenRequest = struct {
    /// Target index name or pattern.
    index: []const u8,
    /// Keep-alive duration (e.g. `"5m"`, `"1h"`).
    keep_alive: []const u8,

    /// Returns the HTTP method for this request (`"POST"`).
    pub fn httpMethod(_: PitOpenRequest) []const u8 {
        return "POST";
    }

    /// Returns the HTTP path for this request.
    ///
    /// Produces `"/<index>/_search/point_in_time?keep_alive=<duration>"`
    /// which is the OpenSearch-compatible endpoint.
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpPath(self: PitOpenRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_search/point_in_time?keep_alive={s}", .{
            self.index,
            self.keep_alive,
        });
    }

    /// Returns the HTTP body for this request.
    ///
    /// PIT open requires no request body — always returns `null`.
    pub fn httpBody(_: PitOpenRequest, _: Allocator) !?[]u8 {
        return null;
    }
};

/// Response from opening a Point-in-Time.
///
/// Contains the opaque `pit_id` that must be passed to subsequent PIT search
/// requests and eventually to `PitCloseRequest` for cleanup.
pub const PitOpenResponse = struct {
    /// The opaque PIT identifier assigned by Elasticsearch.
    pit_id: []const u8,
};

// ---------------------------------------------------------------------------
// PIT Close
// ---------------------------------------------------------------------------

/// Request to close (delete) a Point-in-Time.
///
/// Closing a PIT releases the server-side resources associated with the
/// frozen snapshot. Always close PITs when iteration is complete to avoid
/// resource leaks on the cluster.
pub const PitCloseRequest = struct {
    /// The PIT identifier to close.
    pit_id: []const u8,

    /// Returns the HTTP method for this request (`"DELETE"`).
    pub fn httpMethod(_: PitCloseRequest) []const u8 {
        return "DELETE";
    }

    /// Returns the HTTP path for this request.
    ///
    /// Produces `"/_search/point_in_time"` (OpenSearch-compatible).
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpPath(_: PitCloseRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/_search/point_in_time", .{});
    }

    /// Builds the JSON request body: `{"pit_id": "<id>"}`.
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpBody(self: PitCloseRequest, allocator: Allocator) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var root = std.json.ObjectMap.init(aa);
        try root.put("pit_id", .{ .string = self.pit_id });

        const value: std.json.Value = .{ .object = root };
        const result = try std.json.Stringify.valueAlloc(allocator, value, .{});
        return @as(?[]u8, result);
    }
};

// ---------------------------------------------------------------------------
// PIT Search
// ---------------------------------------------------------------------------

/// Request to search using a Point-in-Time context.
///
/// When searching with a PIT, the index is not specified in the HTTP path —
/// it is implicit in the PIT snapshot. The `search_after` field enables
/// efficient deep pagination by providing the sort values of the last hit
/// from the previous page.
pub const PitSearchRequest = struct {
    /// The PIT identifier from a `PitOpenResponse`.
    pit_id: []const u8,
    /// Keep-alive extension for the PIT (refreshed on each request).
    keep_alive: []const u8,
    /// Optional query to filter results. When `null`, matches all documents.
    query: ?Query = null,
    /// Maximum number of hits per page.
    size: ?u32 = null,
    /// Sort specification. If `null`, defaults to `[{"_doc": "asc"}]`.
    sort: ?[]const SortField = null,
    /// Sort values from the last hit of the previous page (for pagination).
    search_after: ?[]const std.json.Value = null,

    /// Returns the HTTP method for this request (`"POST"`).
    pub fn httpMethod(_: PitSearchRequest) []const u8 {
        return "POST";
    }

    /// Returns the HTTP path for this request.
    ///
    /// Produces `"/_search"` — no index in the path when using PIT.
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpPath(_: PitSearchRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/_search", .{});
    }

    /// Builds the full JSON request body.
    ///
    /// Produces a JSON object with the following structure:
    /// ```json
    /// {
    ///   "pit": {"id": "...", "keep_alive": "..."},
    ///   "query": {...},
    ///   "size": N,
    ///   "sort": [{"field": "order"}, ...],
    ///   "search_after": [...]
    /// }
    /// ```
    ///
    /// Keys whose corresponding field is `null` are omitted. If `sort` is
    /// `null`, a default of `[{"_doc": "asc"}]` is used (most efficient for
    /// full-index scans in OpenSearch).
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpBody(self: PitSearchRequest, allocator: Allocator) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var root = std.json.ObjectMap.init(aa);

        // pit object
        {
            var pit_obj = std.json.ObjectMap.init(aa);
            try pit_obj.put("id", .{ .string = self.pit_id });
            try pit_obj.put("keep_alive", .{ .string = self.keep_alive });
            try root.put("pit", .{ .object = pit_obj });
        }

        // query
        if (self.query) |q| {
            const q_value = try q.toJsonValue(aa);
            try root.put("query", q_value);
        }

        // size
        if (self.size) |s| {
            try root.put("size", .{ .integer = @intCast(s) });
        }

        // sort
        {
            var sort_arr = std.json.Array.init(aa);
            if (self.sort) |sort_fields| {
                for (sort_fields) |sf| {
                    var sort_obj = std.json.ObjectMap.init(aa);
                    try sort_obj.put(sf.field, .{ .string = sf.order });
                    try sort_arr.append(.{ .object = sort_obj });
                }
            } else {
                // Default: [{"_doc": "asc"}]
                var default_sort = std.json.ObjectMap.init(aa);
                try default_sort.put("_doc", .{ .string = "asc" });
                try sort_arr.append(.{ .object = default_sort });
            }
            try root.put("sort", .{ .array = sort_arr });
        }

        // search_after
        if (self.search_after) |sa| {
            var sa_arr = std.json.Array.init(aa);
            for (sa) |v| {
                try sa_arr.append(v);
            }
            try root.put("search_after", .{ .array = sa_arr });
        }

        const value: std.json.Value = .{ .object = root };
        const result = try std.json.Stringify.valueAlloc(allocator, value, .{});
        return @as(?[]u8, result);
    }
};

// ---------------------------------------------------------------------------
// PIT Search Response types
// ---------------------------------------------------------------------------

/// A single hit inside a PIT search response.
///
/// Like `deser.Hit(T)` but includes an optional `sort` array containing the
/// sort values for this hit. These values are needed for `search_after`
/// pagination.
pub fn PitHit(comptime T: type) type {
    return struct {
        /// The index this hit belongs to.
        _index: ?[]const u8 = null,
        /// The document ID.
        _id: ?[]const u8 = null,
        /// The relevance score (may be `null` when sorting by a field other
        /// than `_score`).
        _score: ?f64 = null,
        /// The document body.
        _source: ?T = null,
        /// Sort values for this hit, used as `search_after` input for the
        /// next page.
        sort: ?[]const std.json.Value = null,
    };
}

/// The `hits` envelope inside a PIT search response.
pub fn PitHitsEnvelope(comptime T: type) type {
    return struct {
        /// Total hit count and relation (`"eq"` or `"gte"`).
        total: ?deser.TotalHits = null,
        /// The hits for this page.
        hits: []const PitHit(T) = &.{},
        /// Maximum score across all hits (may be `null`).
        max_score: ?f64 = null,
    };
}

/// Response from a PIT-based search request.
///
/// Wraps the standard search response shape with an additional `pit_id` field
/// that may contain a refreshed PIT identifier.
pub fn PitSearchResponse(comptime T: type) type {
    return struct {
        /// Refreshed PIT identifier. Elasticsearch may return a new PIT ID
        /// on each search; callers should always use the latest value.
        pit_id: ?[]const u8 = null,
        /// The hits envelope.
        hits: PitHitsEnvelope(T),
        /// Server-side elapsed time in milliseconds.
        took: ?u64 = null,
    };
}

// ---------------------------------------------------------------------------
// PIT Iterator
// ---------------------------------------------------------------------------

/// An iterator that pages through search results using PIT + `search_after`.
///
/// `PitIterator` opens a Point-in-Time snapshot on initialization, sends the
/// first search, and then yields pages of hits via `next()`. Each page is
/// fetched on demand; at most one page of hits is live in memory at any time
/// (the previous page is freed when the next is fetched).
///
/// Call `deinit()` to close the server-side PIT and free all owned memory.
/// PIT close errors during `deinit()` are silently ignored to avoid masking
/// the caller's primary error path.
///
/// ## Usage
///
/// ```zig
/// var it = try PitIterator(Concept).init(allocator, &pool, true, "concepts", query, 100, "1m");
/// defer it.deinit();
///
/// while (try it.next()) |hits| {
///     for (hits) |hit| {
///         // process hit._source, hit._id, etc.
///     }
/// }
/// ```
pub fn PitIterator(comptime T: type) type {
    return struct {
        const Self = @This();
        const Response = PitSearchResponse(T);
        const HitType = PitHit(T);

        /// Allocator used for all owned memory.
        allocator: Allocator,
        /// Connection pool for sending HTTP requests.
        pool: *pool_mod.ConnectionPool,
        /// Whether to use gzip compression for requests.
        compression: bool,
        /// The current PIT identifier (owned copy).
        pit_id: ?[]const u8,
        /// Keep-alive duration string (not owned — expected to be static or
        /// to outlive the iterator).
        keep_alive: []const u8,
        /// Optional query filter.
        query: ?Query,
        /// Number of hits per page.
        page_size: u32,
        /// Sort values from the last hit of the most recent page.
        last_sort_values: ?[]const std.json.Value,
        /// The currently loaded page (owned via `std.json.Parsed`).
        current_parsed: ?std.json.Parsed(Response),
        /// The previously loaded page, kept alive until the next `next()`
        /// call so that the caller's hit slice references remain valid.
        previous_parsed: ?std.json.Parsed(Response),
        /// Set to `true` when no more pages are available.
        done: bool,
        /// Separately allocated buffer holding the current `pit_id` string.
        /// Required because the PIT ID may be refreshed by the server on
        /// each search response.
        pit_id_buf: ?[]u8,

        /// Initialise a PIT iterator.
        ///
        /// Opens a PIT on `index`, sends the initial search, and returns an
        /// iterator ready to yield the first page via `next()`.
        ///
        /// The caller must call `deinit()` to close the PIT and free memory.
        pub fn init(
            allocator: Allocator,
            pool_ptr: *pool_mod.ConnectionPool,
            compression: bool,
            index: []const u8,
            query: ?Query,
            page_size: u32,
            keep_alive: []const u8,
        ) !Self {
            // 1. Open PIT
            const open_path = try std.fmt.allocPrint(allocator, "/{s}/_search/point_in_time?keep_alive={s}", .{
                index,
                keep_alive,
            });
            defer allocator.free(open_path);

            var open_resp = try pool_ptr.sendRequest(allocator, "POST", open_path, null, compression);
            defer open_resp.deinit(allocator);

            if (open_resp.status_code < 200 or open_resp.status_code >= 300) {
                return error.UnexpectedResponse;
            }

            // Parse PIT open response to get pit_id.
            var open_arena = std.heap.ArenaAllocator.init(allocator);
            defer open_arena.deinit();
            const open_result = try deser.fromJsonLeaky(PitOpenResponse, open_arena.allocator(), open_resp.body);

            // Copy pit_id into our own allocation.
            const pid_buf = try allocator.dupe(u8, open_result.pit_id);
            errdefer allocator.free(pid_buf);

            // 2. Send initial search.
            var self = Self{
                .allocator = allocator,
                .pool = pool_ptr,
                .compression = compression,
                .pit_id = pid_buf,
                .keep_alive = keep_alive,
                .query = query,
                .page_size = page_size,
                .last_sort_values = null,
                .current_parsed = null,
                .previous_parsed = null,
                .done = false,
                .pit_id_buf = pid_buf,
            };

            try self.fetchPage(null);

            // Check if the first page is empty — if so, mark done immediately.
            if (self.current_parsed) |cp| {
                if (cp.value.hits.hits.len == 0) {
                    self.done = true;
                }
            } else {
                self.done = true;
            }

            return self;
        }

        /// Returns the next page of hits, or `null` when all results have
        /// been consumed.
        ///
        /// The returned slice is valid until the *next* call to `next()` or
        /// `deinit()`. Do not store references to hits across `next()` calls.
        pub fn next(self: *Self) !?[]const HitType {
            // Free the previous page — its hit references are no longer valid.
            if (self.previous_parsed) |*pp| {
                pp.deinit();
                self.previous_parsed = null;
            }

            if (self.done) return null;

            const cp = self.current_parsed orelse return null;
            const hits = cp.value.hits.hits;

            if (hits.len == 0) {
                self.done = true;
                return null;
            }

            // Extract sort values from the last hit for search_after.
            const last_hit = hits[hits.len - 1];
            const sort_vals = last_hit.sort;

            // Move current to previous (caller's hit slice stays alive).
            self.previous_parsed = self.current_parsed;
            self.current_parsed = null;

            // Fetch the next page.
            try self.fetchPage(sort_vals);

            // Update pit_id if the server refreshed it.
            if (self.current_parsed) |next_cp| {
                if (next_cp.value.pit_id) |new_pid| {
                    if (self.pit_id_buf) |old_buf| {
                        // Only reallocate if the ID actually changed.
                        if (!std.mem.eql(u8, old_buf, new_pid)) {
                            self.allocator.free(old_buf);
                            const new_buf = try self.allocator.dupe(u8, new_pid);
                            self.pit_id_buf = new_buf;
                            self.pit_id = new_buf;
                        }
                    }
                }

                // If the next page has no hits, mark done.
                if (next_cp.value.hits.hits.len == 0) {
                    self.done = true;
                }
            }

            return hits;
        }

        /// Release all resources and close the server-side PIT.
        ///
        /// PIT close errors are silently ignored so that `deinit()` never
        /// fails — this prevents masking the caller's primary error path.
        pub fn deinit(self: *Self) void {
            // Free parsed responses.
            if (self.current_parsed) |*cp| {
                cp.deinit();
                self.current_parsed = null;
            }
            if (self.previous_parsed) |*pp| {
                pp.deinit();
                self.previous_parsed = null;
            }

            // Close the PIT on the server (best-effort).
            if (self.pit_id) |pid| {
                self.closePitOnServer(pid);
            }

            // Free owned pit_id buffer.
            if (self.pit_id_buf) |buf| {
                self.allocator.free(buf);
                self.pit_id_buf = null;
                self.pit_id = null;
            }
        }

        // -- Private helpers ------------------------------------------------

        /// Send a PIT search request and store the parsed response as
        /// `current_parsed`.
        fn fetchPage(self: *Self, search_after: ?[]const std.json.Value) !void {
            const req = PitSearchRequest{
                .pit_id = self.pit_id orelse return error.InvalidPitState,
                .keep_alive = self.keep_alive,
                .query = self.query,
                .size = self.page_size,
                .sort = null, // uses default [{"_doc": "asc"}]
                .search_after = search_after,
            };

            const path = try req.httpPath(self.allocator);
            defer self.allocator.free(path);

            const body = try req.httpBody(self.allocator);
            defer if (body) |b| self.allocator.free(b);

            var resp = try self.pool.sendRequest(self.allocator, req.httpMethod(), path, body, self.compression);
            defer resp.deinit(self.allocator);

            if (resp.status_code < 200 or resp.status_code >= 300) {
                return error.UnexpectedResponse;
            }

            const parsed = try deser.fromJson(Response, self.allocator, resp.body);
            self.current_parsed = parsed;
        }

        /// Best-effort close of a PIT on the server. Errors are ignored.
        fn closePitOnServer(self: *Self, pid: []const u8) void {
            const close_req = PitCloseRequest{ .pit_id = pid };

            const path = close_req.httpPath(self.allocator) catch return;
            defer self.allocator.free(path);

            const body = close_req.httpBody(self.allocator) catch return;
            defer if (body) |b| self.allocator.free(b);

            var resp = self.pool.sendRequest(self.allocator, close_req.httpMethod(), path, body, self.compression) catch return;
            resp.deinit(self.allocator);
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

// ---------------------------------------------------------------------------
// PitOpenRequest tests
// ---------------------------------------------------------------------------

test "pit open request method" {
    const req = PitOpenRequest{ .index = "concepts", .keep_alive = "5m" };
    try testing.expectEqualStrings("POST", req.httpMethod());
}

test "pit open request path" {
    const req = PitOpenRequest{ .index = "concepts", .keep_alive = "5m" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/concepts/_search/point_in_time?keep_alive=5m", path);
}

test "pit open request path with pattern index" {
    const req = PitOpenRequest{ .index = "concepts-*", .keep_alive = "1m" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/concepts-*/_search/point_in_time?keep_alive=1m", path);
}

test "pit open request body is null" {
    const req = PitOpenRequest{ .index = "concepts", .keep_alive = "5m" };
    const body = try req.httpBody(testing.allocator);
    try testing.expect(body == null);
}

// ---------------------------------------------------------------------------
// PitCloseRequest tests
// ---------------------------------------------------------------------------

test "pit close request method" {
    const req = PitCloseRequest{ .pit_id = "abc123" };
    try testing.expectEqualStrings("DELETE", req.httpMethod());
}

test "pit close request path" {
    const req = PitCloseRequest{ .pit_id = "abc123" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/_search/point_in_time", path);
}

test "pit close request body contains pit_id" {
    const req = PitCloseRequest{ .pit_id = "abc123xyz" };
    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("abc123xyz", root.get("pit_id").?.string);
}

// ---------------------------------------------------------------------------
// PitSearchRequest tests
// ---------------------------------------------------------------------------

test "pit search request method" {
    const req = PitSearchRequest{ .pit_id = "pit1", .keep_alive = "1m" };
    try testing.expectEqualStrings("POST", req.httpMethod());
}

test "pit search request path has no index" {
    const req = PitSearchRequest{ .pit_id = "pit1", .keep_alive = "1m" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/_search", path);
}

test "pit search request body minimal" {
    const req = PitSearchRequest{
        .pit_id = "my-pit-id",
        .keep_alive = "2m",
    };
    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // pit object
    const pit_obj = root.get("pit").?.object;
    try testing.expectEqualStrings("my-pit-id", pit_obj.get("id").?.string);
    try testing.expectEqualStrings("2m", pit_obj.get("keep_alive").?.string);

    // Default sort: [{"_doc": "asc"}]
    const sort_arr = root.get("sort").?.array.items;
    try testing.expectEqual(@as(usize, 1), sort_arr.len);
    try testing.expectEqualStrings("asc", sort_arr[0].object.get("_doc").?.string);

    // No query, size, or search_after.
    try testing.expect(root.get("query") == null);
    try testing.expect(root.get("size") == null);
    try testing.expect(root.get("search_after") == null);
}

test "pit search request body with all options" {
    const sort_fields = &[_]SortField{
        .{ .field = "timestamp", .order = "desc" },
        .{ .field = "_doc", .order = "asc" },
    };

    const search_after_vals = &[_]std.json.Value{
        .{ .integer = 1234567890 },
        .{ .integer = 42 },
    };

    const req = PitSearchRequest{
        .pit_id = "full-pit-id",
        .keep_alive = "5m",
        .query = Query.term("active", true),
        .size = 50,
        .sort = sort_fields,
        .search_after = search_after_vals,
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // pit object
    const pit_obj = root.get("pit").?.object;
    try testing.expectEqualStrings("full-pit-id", pit_obj.get("id").?.string);
    try testing.expectEqualStrings("5m", pit_obj.get("keep_alive").?.string);

    // query
    const query_obj = root.get("query").?;
    try testing.expect(query_obj == .object);
    try testing.expect(query_obj.object.get("term") != null);

    // size
    try testing.expectEqual(@as(i64, 50), root.get("size").?.integer);

    // sort — custom fields
    const sort_arr = root.get("sort").?.array.items;
    try testing.expectEqual(@as(usize, 2), sort_arr.len);
    try testing.expectEqualStrings("desc", sort_arr[0].object.get("timestamp").?.string);
    try testing.expectEqualStrings("asc", sort_arr[1].object.get("_doc").?.string);

    // search_after
    const sa_arr = root.get("search_after").?.array.items;
    try testing.expectEqual(@as(usize, 2), sa_arr.len);
    try testing.expectEqual(@as(i64, 1234567890), sa_arr[0].integer);
    try testing.expectEqual(@as(i64, 42), sa_arr[1].integer);
}

test "pit search request body with size only" {
    const req = PitSearchRequest{
        .pit_id = "sized-pit",
        .keep_alive = "1m",
        .size = 100,
    };
    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    try testing.expectEqual(@as(i64, 100), root.get("size").?.integer);
    // Default sort should still be present.
    try testing.expect(root.get("sort") != null);
}

// ---------------------------------------------------------------------------
// Response deserialization tests
// ---------------------------------------------------------------------------

test "pit open response deserialization" {
    const json =
        \\{"pit_id":"abc123_opaque_token"}
    ;

    var parsed = try deser.fromJson(PitOpenResponse, testing.allocator, json);
    defer parsed.deinit();

    try testing.expectEqualStrings("abc123_opaque_token", parsed.value.pit_id);
}

test "pit search response deserialization" {
    const Concept = struct {
        id: u64,
        active: bool,
    };

    const json =
        \\{
        \\  "pit_id": "refreshed-pit-id",
        \\  "took": 3,
        \\  "hits": {
        \\    "total": {"value": 2, "relation": "eq"},
        \\    "max_score": null,
        \\    "hits": [
        \\      {
        \\        "_index": "concepts-v1",
        \\        "_id": "100",
        \\        "_score": null,
        \\        "_source": {"id": 100, "active": true},
        \\        "sort": [0]
        \\      },
        \\      {
        \\        "_index": "concepts-v1",
        \\        "_id": "200",
        \\        "_score": null,
        \\        "_source": {"id": 200, "active": false},
        \\        "sort": [1]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var parsed = try deser.fromJson(PitSearchResponse(Concept), testing.allocator, json);
    defer parsed.deinit();

    const resp = parsed.value;

    try testing.expectEqualStrings("refreshed-pit-id", resp.pit_id.?);
    try testing.expectEqual(@as(u64, 3), resp.took.?);
    try testing.expectEqual(@as(u64, 2), resp.hits.total.?.value);
    try testing.expectEqualStrings("eq", resp.hits.total.?.relation.?);

    const hits = resp.hits.hits;
    try testing.expectEqual(@as(usize, 2), hits.len);

    // First hit
    try testing.expectEqualStrings("100", hits[0]._id.?);
    try testing.expectEqual(@as(u64, 100), hits[0]._source.?.id);
    try testing.expectEqual(true, hits[0]._source.?.active);
    try testing.expect(hits[0].sort != null);
    try testing.expectEqual(@as(usize, 1), hits[0].sort.?.len);

    // Second hit
    try testing.expectEqualStrings("200", hits[1]._id.?);
    try testing.expectEqual(@as(u64, 200), hits[1]._source.?.id);
    try testing.expectEqual(false, hits[1]._source.?.active);
    try testing.expect(hits[1].sort != null);
}

test "pit search response with no hits" {
    const Simple = struct { id: u64 };

    const json =
        \\{
        \\  "pit_id": "empty-pit",
        \\  "took": 1,
        \\  "hits": {
        \\    "total": {"value": 0, "relation": "eq"},
        \\    "hits": []
        \\  }
        \\}
    ;

    var parsed = try deser.fromJson(PitSearchResponse(Simple), testing.allocator, json);
    defer parsed.deinit();

    try testing.expectEqualStrings("empty-pit", parsed.value.pit_id.?);
    try testing.expectEqual(@as(usize, 0), parsed.value.hits.hits.len);
}

test "pit search response without pit_id field" {
    const Simple = struct { id: u64 };

    const json =
        \\{
        \\  "took": 2,
        \\  "hits": {
        \\    "total": {"value": 1, "relation": "eq"},
        \\    "hits": [
        \\      {
        \\        "_id": "1",
        \\        "_source": {"id": 1},
        \\        "sort": [0]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var parsed = try deser.fromJson(PitSearchResponse(Simple), testing.allocator, json);
    defer parsed.deinit();

    try testing.expect(parsed.value.pit_id == null);
    try testing.expectEqual(@as(usize, 1), parsed.value.hits.hits.len);
}
