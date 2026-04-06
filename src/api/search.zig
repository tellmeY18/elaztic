//! Search and count request/response types for Elasticsearch.
//!
//! This module provides `SearchRequest` and `CountRequest`, which build the
//! HTTP method, path, and JSON body for the `_search` and `_count` endpoints.
//! A `CountResponse` struct is also provided for deserializing count results.
//!
//! Both request types serialize their bodies via `std.json.Value` trees,
//! delegating to the query DSL (`Query`), source filtering (`SourceFilter`),
//! and aggregation (`Aggregation`) modules for sub-trees.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Query = @import("../query/builder.zig").Query;
const SourceFilter = @import("../query/source_filter.zig").SourceFilter;
const Aggregation = @import("../query/aggregation.zig").Aggregation;

/// Options for building a search request.
///
/// All fields are optional — when left as `null`, the corresponding key is
/// omitted from the serialized request body, letting Elasticsearch use its
/// own defaults.
pub const SearchOptions = struct {
    /// Maximum number of hits to return.
    size: ?u32 = null,
    /// Offset into the result set (for pagination).
    from: ?u32 = null,
    /// Source filtering (include/exclude fields from `_source`).
    source: ?SourceFilter = null,
    /// Aggregations to include in the request.
    aggs: ?[]const Aggregation = null,
};

/// Request to search an Elasticsearch index.
///
/// Construct a `SearchRequest` with an index name (or pattern) and optional
/// query/options, then call `httpMethod()`, `httpPath()`, and `httpBody()` to
/// obtain the components needed for the HTTP transport layer.
pub const SearchRequest = struct {
    /// Target index name or pattern (e.g. `"concepts-*"`).
    index: []const u8,
    /// The query to execute. If `null`, the `"query"` key is omitted from the
    /// request body entirely (Elasticsearch defaults to `match_all`).
    query: ?Query = null,
    /// Additional search options (size, from, source filtering, aggregations).
    options: SearchOptions = .{},

    /// Returns the HTTP method for this request.
    ///
    /// Search always uses `POST` so that a JSON body can be included.
    pub fn httpMethod(_: SearchRequest) []const u8 {
        return "POST";
    }

    /// Returns the HTTP path for this request (e.g. `"/my-index/_search"`).
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it
    /// and must free it when no longer needed.
    pub fn httpPath(self: SearchRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_search", .{self.index});
    }

    /// Builds the full JSON request body.
    ///
    /// Returns a caller-owned `[]u8` containing a JSON object with whichever
    /// keys are relevant:
    ///
    /// ```json
    /// {"query": {...}, "size": N, "from": N, "_source": ..., "aggs": {...}}
    /// ```
    ///
    /// Keys whose corresponding option is `null` are omitted entirely.
    /// Returns `null` only when there is nothing to serialize (no query, no
    /// options), though in practice the caller may still want to send an
    /// empty `{}` body — this method will return `"{}"` in that case.
    pub fn httpBody(self: SearchRequest, allocator: Allocator) !?[]u8 {
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

/// Request to count documents in an Elasticsearch index.
///
/// Construct a `CountRequest` with an index name (or pattern) and an optional
/// query, then call `httpMethod()`, `httpPath()`, and `httpBody()` to obtain
/// the HTTP components.
pub const CountRequest = struct {
    /// Target index name or pattern.
    index: []const u8,
    /// Optional query to filter the count. If `null`, counts all documents.
    query: ?Query = null,

    /// Returns the HTTP method for this request.
    ///
    /// Count uses `POST` when a query body is included, but `POST` is also
    /// valid for the no-body case, so we always return `"POST"`.
    pub fn httpMethod(_: CountRequest) []const u8 {
        return "POST";
    }

    /// Returns the HTTP path for this request (e.g. `"/my-index/_count"`).
    ///
    /// The returned slice is allocated with `allocator`; the caller owns it.
    pub fn httpPath(self: CountRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_count", .{self.index});
    }

    /// Builds the JSON request body, or returns `null` when there is no query.
    ///
    /// When a query is present, produces `{"query": {...}}`.
    /// When no query is set, returns `null` — the caller should send the
    /// request without a body (Elasticsearch counts all documents).
    pub fn httpBody(self: CountRequest, allocator: Allocator) !?[]u8 {
        if (self.query) |q| {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            var root = std.json.ObjectMap.init(aa);
            const q_value = try q.toJsonValue(aa);
            try root.put("query", q_value);
            const value: std.json.Value = .{ .object = root };
            const result = try std.json.Stringify.valueAlloc(allocator, value, .{});
            return @as(?[]u8, result);
        }
        return null;
    }
};

/// Response from the `_count` endpoint.
///
/// Elasticsearch returns `{"count": N, "_shards": {...}}`. Unknown fields
/// (such as `_shards` sub-fields not modelled here) are ignored during
/// deserialization when using the project's `deserialize.fromJson`.
pub const CountResponse = struct {
    /// The number of documents matching the query (or total documents).
    count: u64 = 0,
    /// Shard-level statistics for the count operation.
    _shards: ?ShardsInfo = null,

    /// Shard statistics returned alongside a count response.
    pub const ShardsInfo = struct {
        /// Total number of shards the request was executed on.
        total: ?u32 = null,
        /// Number of shards that completed successfully.
        successful: ?u32 = null,
        /// Number of shards that were skipped.
        skipped: ?u32 = null,
        /// Number of shards that failed.
        failed: ?u32 = null,
    };
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Helper: parse a JSON byte slice into a `std.json.Value` tree.
fn parseJson(json_bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json_bytes, .{});
}

test "search request path" {
    const req = SearchRequest{ .index = "my-index" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/my-index/_search", path);
}

test "search request method" {
    const req = SearchRequest{ .index = "x" };
    try testing.expectEqualStrings("POST", req.httpMethod());
}

test "search request body with query only" {
    const req = SearchRequest{
        .index = "concepts",
        .query = Query.term("active", true),
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

    // No size/from/_source/aggs keys.
    try testing.expect(root.get("size") == null);
    try testing.expect(root.get("from") == null);
    try testing.expect(root.get("_source") == null);
    try testing.expect(root.get("aggs") == null);
}

test "search request body with size and from" {
    const req = SearchRequest{
        .index = "concepts",
        .options = .{ .size = 25, .from = 50 },
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    try testing.expectEqual(@as(i64, 25), root.get("size").?.integer);
    try testing.expectEqual(@as(i64, 50), root.get("from").?.integer);

    // No query key.
    try testing.expect(root.get("query") == null);
}

test "search request body with source filter" {
    const req = SearchRequest{
        .index = "concepts",
        .options = .{
            .source = .{ .includes = &.{ "id", "active" } },
        },
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // _source should be an array of field names.
    const source_val = root.get("_source").?;
    try testing.expect(source_val == .array);
    const arr = source_val.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("id", arr[0].string);
    try testing.expectEqualStrings("active", arr[1].string);
}

test "search request body with aggregations" {
    const aggs = &[_]Aggregation{
        Aggregation.termsAgg("by_module", "module_id", 10),
    };

    const req = SearchRequest{
        .index = "concepts",
        .options = .{ .aggs = aggs },
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Must have an "aggs" key.
    const aggs_obj = root.get("aggs").?;
    try testing.expect(aggs_obj == .object);

    // The "by_module" aggregation must be present.
    const by_module = aggs_obj.object.get("by_module").?;
    try testing.expect(by_module == .object);
    const terms_inner = by_module.object.get("terms").?;
    try testing.expect(terms_inner == .object);
    try testing.expectEqualStrings("module_id", terms_inner.object.get("field").?.string);
    try testing.expectEqual(@as(i64, 10), terms_inner.object.get("size").?.integer);
}

test "search request body with all options" {
    const aggs = &[_]Aggregation{
        Aggregation.valueCount("total", "id"),
    };

    const req = SearchRequest{
        .index = "concepts",
        .query = Query.term("active", true),
        .options = .{
            .size = 10,
            .from = 20,
            .source = .{ .includes = &.{"id"} },
            .aggs = aggs,
        },
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // All keys must be present.
    try testing.expect(root.get("query") != null);
    try testing.expectEqual(@as(i64, 10), root.get("size").?.integer);
    try testing.expectEqual(@as(i64, 20), root.get("from").?.integer);
    try testing.expect(root.get("_source") != null);
    try testing.expect(root.get("aggs") != null);

    // Verify query structure.
    const query_obj = root.get("query").?.object;
    try testing.expect(query_obj.get("term") != null);

    // Verify _source is an array with one element.
    const source_arr = root.get("_source").?.array.items;
    try testing.expectEqual(@as(usize, 1), source_arr.len);
    try testing.expectEqualStrings("id", source_arr[0].string);

    // Verify aggs has the "total" key.
    const aggs_obj = root.get("aggs").?.object;
    try testing.expect(aggs_obj.get("total") != null);
}

test "search request body with null query" {
    const req = SearchRequest{
        .index = "concepts",
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // No query key should be present.
    try testing.expect(root.get("query") == null);
    // Body should still be valid JSON (an empty object).
    try testing.expect(root.count() == 0);
}

test "count request path" {
    const req = CountRequest{ .index = "my-index" };
    const path = try req.httpPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/my-index/_count", path);
}

test "count request body with query" {
    const req = CountRequest{
        .index = "concepts",
        .query = Query.term("active", true),
    };

    const body = (try req.httpBody(testing.allocator)).?;
    defer testing.allocator.free(body);

    var parsed = try parseJson(body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Must have a "query" key.
    const query_obj = root.get("query").?;
    try testing.expect(query_obj == .object);
    try testing.expect(query_obj.object.get("term") != null);
}

test "count request body without query" {
    const req = CountRequest{
        .index = "concepts",
    };

    const body = try req.httpBody(testing.allocator);
    // When no query is set, httpBody returns null.
    try testing.expect(body == null);
}

test "count response deserialization" {
    const deserialize = @import("../json/deserialize.zig");

    const json =
        \\{"count":42,"_shards":{"total":5,"successful":5,"skipped":0,"failed":0}}
    ;

    var parsed = try deserialize.fromJson(CountResponse, testing.allocator, json);
    defer parsed.deinit();

    const resp = parsed.value;
    try testing.expectEqual(@as(u64, 42), resp.count);

    const shards = resp._shards.?;
    try testing.expectEqual(@as(u32, 5), shards.total.?);
    try testing.expectEqual(@as(u32, 5), shards.successful.?);
    try testing.expectEqual(@as(u32, 0), shards.skipped.?);
    try testing.expectEqual(@as(u32, 0), shards.failed.?);
}
