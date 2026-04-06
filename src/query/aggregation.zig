//! Aggregation DSL for Elasticsearch queries.
//!
//! This module provides a composable, type-safe way to build Elasticsearch
//! aggregations that serialize to `std.json.Value`. Aggregations can be nested
//! via `withSubAggs` to build arbitrarily deep aggregation trees.
//!
//! Supported aggregation types:
//! - **terms** — bucket aggregation on a keyword/numeric field
//! - **value_count** — single-value metric counting non-null values
//! - **top_hits** — returns the top matching documents per bucket
//!
//! ## Example
//!
//! ```zig
//! const aggs = &[_]Aggregation{
//!     Aggregation.termsAgg("by_module", "module_id", 10)
//!         .withSubAggs(&[_]Aggregation{
//!             Aggregation.topHits("top", 3),
//!         }),
//!     Aggregation.valueCount("total", "id"),
//! };
//! const json = try Aggregation.aggsToJson(aggs, allocator);
//! defer allocator.free(json);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents an Elasticsearch aggregation.
///
/// Each `Aggregation` carries a name (used as the JSON key), a typed
/// configuration (`AggType`), and optional sub-aggregations. Aggregations
/// are plain values — they do not allocate on construction and can be
/// composed freely at comptime or runtime.
pub const Aggregation = struct {
    /// The name of this aggregation (used as the JSON key in the `"aggs"` object).
    name: []const u8,
    /// The aggregation type and its configuration.
    agg_type: AggType,
    /// Optional sub-aggregations nested under this aggregation.
    sub_aggs: ?[]const Aggregation = null,

    /// Tagged union of supported aggregation types.
    pub const AggType = union(enum) {
        /// A terms bucket aggregation.
        terms_agg: TermsAgg,
        /// A value_count metric aggregation.
        value_count: ValueCountAgg,
        /// A top_hits metric aggregation.
        top_hits: TopHitsAgg,
    };

    /// Configuration for a terms bucket aggregation.
    ///
    /// Produces: `{"terms": {"field": "<field_name>", "size": <size>}}`
    pub const TermsAgg = struct {
        /// The document field to aggregate on.
        field_name: []const u8,
        /// Maximum number of buckets to return.
        size: u32 = 10,
    };

    /// Configuration for a value_count metric aggregation.
    ///
    /// Produces: `{"value_count": {"field": "<field_name>"}}`
    pub const ValueCountAgg = struct {
        /// The document field to count.
        field_name: []const u8,
    };

    /// Configuration for a top_hits metric aggregation.
    ///
    /// Produces: `{"top_hits": {"size": <size>}}`
    pub const TopHitsAgg = struct {
        /// Maximum number of top hits to return per bucket.
        size: u32 = 10,
    };

    // -----------------------------------------------------------------------
    // Constructors
    // -----------------------------------------------------------------------

    /// Creates a terms aggregation.
    ///
    /// Produces JSON of the form:
    /// `{"<name>": {"terms": {"field": "<field_name>", "size": <size>}}}`
    pub fn termsAgg(name: []const u8, field_name: []const u8, size: u32) Aggregation {
        return .{
            .name = name,
            .agg_type = .{ .terms_agg = .{ .field_name = field_name, .size = size } },
        };
    }

    /// Creates a value_count aggregation.
    ///
    /// Produces JSON of the form:
    /// `{"<name>": {"value_count": {"field": "<field_name>"}}}`
    pub fn valueCount(name: []const u8, field_name: []const u8) Aggregation {
        return .{
            .name = name,
            .agg_type = .{ .value_count = .{ .field_name = field_name } },
        };
    }

    /// Creates a top_hits aggregation.
    ///
    /// Produces JSON of the form:
    /// `{"<name>": {"top_hits": {"size": <size>}}}`
    pub fn topHits(name: []const u8, size: u32) Aggregation {
        return .{
            .name = name,
            .agg_type = .{ .top_hits = .{ .size = size } },
        };
    }

    /// Returns a copy of this aggregation with the given sub-aggregations attached.
    ///
    /// The returned `Aggregation` is identical to `self` except that its
    /// `sub_aggs` field points to the provided slice. The slice is not copied —
    /// the caller must ensure it outlives the returned value.
    pub fn withSubAggs(self: Aggregation, sub_aggs: []const Aggregation) Aggregation {
        return .{
            .name = self.name,
            .agg_type = self.agg_type,
            .sub_aggs = sub_aggs,
        };
    }

    // -----------------------------------------------------------------------
    // Serialization
    // -----------------------------------------------------------------------

    /// Serializes the inner body of this aggregation to a `std.json.Value`.
    ///
    /// Returns the object that sits on the *value* side of the name key.
    /// For a terms aggregation named `"by_module"`, this returns the value
    /// corresponding to `{"terms": {"field": "module_id", "size": 10}}`.
    /// The caller is responsible for wrapping it with the name key when
    /// building the full `"aggs"` object.
    ///
    /// If this aggregation has sub-aggregations, they are serialized under
    /// an `"aggs"` key within the returned object.
    pub const JsonError = Allocator.Error;

    pub fn toJsonValue(self: Aggregation, allocator: Allocator) JsonError!std.json.Value {
        var outer = std.json.ObjectMap.init(allocator);

        switch (self.agg_type) {
            .terms_agg => |ta| {
                var inner = std.json.ObjectMap.init(allocator);
                try inner.put("field", .{ .string = ta.field_name });
                try inner.put("size", .{ .integer = @intCast(ta.size) });
                try outer.put("terms", .{ .object = inner });
            },
            .value_count => |vc| {
                var inner = std.json.ObjectMap.init(allocator);
                try inner.put("field", .{ .string = vc.field_name });
                try outer.put("value_count", .{ .object = inner });
            },
            .top_hits => |th| {
                var inner = std.json.ObjectMap.init(allocator);
                try inner.put("size", .{ .integer = @intCast(th.size) });
                try outer.put("top_hits", .{ .object = inner });
            },
        }

        // Attach sub-aggregations if present.
        if (self.sub_aggs) |subs| {
            if (subs.len > 0) {
                const sub_value = try aggsToJsonValue(subs, allocator);
                try outer.put("aggs", sub_value);
            }
        }

        return .{ .object = outer };
    }

    /// Serializes a slice of aggregations to the full `"aggs"` object value.
    ///
    /// Each aggregation's `name` becomes a key in the returned JSON object,
    /// and its serialized body (from `toJsonValue`) becomes the corresponding
    /// value.
    ///
    /// For example, given `[termsAgg("by_module", "module_id", 10)]`, this
    /// returns:
    /// `{"by_module": {"terms": {"field": "module_id", "size": 10}}}`
    pub fn aggsToJsonValue(aggs: []const Aggregation, allocator: Allocator) JsonError!std.json.Value {
        var map = std.json.ObjectMap.init(allocator);
        for (aggs) |agg| {
            const val = try agg.toJsonValue(allocator);
            try map.put(agg.name, val);
        }
        return .{ .object = map };
    }

    /// Serializes a slice of aggregations to a caller-owned JSON byte string.
    ///
    /// Uses an arena internally for intermediate `std.json.Value` trees; only
    /// the final `[]u8` is allocated with the provided `allocator`. The caller
    /// must free the returned slice with `allocator.free(result)`.
    pub fn aggsToJson(aggs: []const Aggregation, allocator: Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const json_value = try aggsToJsonValue(aggs, arena.allocator());
        return std.json.Stringify.valueAlloc(allocator, json_value, .{});
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Helper: serialize an aggregation slice to JSON string and parse it back.
fn roundTripAggs(aggs: []const Aggregation) !std.json.Parsed(std.json.Value) {
    const json_bytes = try Aggregation.aggsToJson(aggs, testing.allocator);
    defer testing.allocator.free(json_bytes);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json_bytes, .{});
}

/// Helper: serialize a single aggregation's inner value to JSON string and parse it back.
fn roundTripSingle(agg: Aggregation) !std.json.Parsed(std.json.Value) {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try agg.toJsonValue(arena.allocator());
    const json_bytes = try std.json.Stringify.valueAlloc(testing.allocator, val, .{});
    defer testing.allocator.free(json_bytes);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json_bytes, .{});
}

test "terms aggregation" {
    const agg = Aggregation.termsAgg("by_module", "module_id", 10);
    var parsed = try roundTripSingle(agg);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Must have a "terms" key
    const terms_obj = root.get("terms").?.object;
    try testing.expectEqualStrings("module_id", terms_obj.get("field").?.string);
    try testing.expectEqual(@as(i64, 10), terms_obj.get("size").?.integer);

    // No sub-aggs
    try testing.expect(root.get("aggs") == null);
}

test "value_count aggregation" {
    const agg = Aggregation.valueCount("total_ids", "id");
    var parsed = try roundTripSingle(agg);
    defer parsed.deinit();

    const root = parsed.value.object;

    const vc_obj = root.get("value_count").?.object;
    try testing.expectEqualStrings("id", vc_obj.get("field").?.string);

    // value_count has no "size" key
    try testing.expect(vc_obj.get("size") == null);
}

test "top_hits aggregation" {
    const agg = Aggregation.topHits("top", 5);
    var parsed = try roundTripSingle(agg);
    defer parsed.deinit();

    const root = parsed.value.object;

    const th_obj = root.get("top_hits").?.object;
    try testing.expectEqual(@as(i64, 5), th_obj.get("size").?.integer);

    // top_hits has no "field" key
    try testing.expect(th_obj.get("field") == null);
}

test "terms with sub-aggregation" {
    const sub = Aggregation.topHits("top", 3);
    const agg = Aggregation.termsAgg("by_module", "module_id", 10)
        .withSubAggs(&[_]Aggregation{sub});

    var parsed = try roundTripSingle(agg);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Outer terms config still present.
    const terms_obj = root.get("terms").?.object;
    try testing.expectEqualStrings("module_id", terms_obj.get("field").?.string);
    try testing.expectEqual(@as(i64, 10), terms_obj.get("size").?.integer);

    // Sub-aggregations present under "aggs".
    const sub_aggs = root.get("aggs").?.object;
    const top_obj = sub_aggs.get("top").?.object;
    const th_inner = top_obj.get("top_hits").?.object;
    try testing.expectEqual(@as(i64, 3), th_inner.get("size").?.integer);
}

test "multiple aggregations" {
    const aggs = &[_]Aggregation{
        Aggregation.termsAgg("by_module", "module_id", 10),
        Aggregation.valueCount("total_ids", "id"),
        Aggregation.topHits("top_docs", 5),
    };

    var parsed = try roundTripAggs(aggs);
    defer parsed.deinit();

    const root = parsed.value.object;

    // All three aggregation names must be present as keys.
    try testing.expect(root.get("by_module") != null);
    try testing.expect(root.get("total_ids") != null);
    try testing.expect(root.get("top_docs") != null);

    // Verify inner types are correct.
    try testing.expect(root.get("by_module").?.object.get("terms") != null);
    try testing.expect(root.get("total_ids").?.object.get("value_count") != null);
    try testing.expect(root.get("top_docs").?.object.get("top_hits") != null);
}

test "aggsToJson serializes correctly" {
    const sub = Aggregation.topHits("top", 3);
    const aggs = &[_]Aggregation{
        Aggregation.termsAgg("by_module", "module_id", 10)
            .withSubAggs(&[_]Aggregation{sub}),
        Aggregation.valueCount("count_active", "active"),
    };

    const json_bytes = try Aggregation.aggsToJson(aggs, testing.allocator);
    defer testing.allocator.free(json_bytes);

    // Parse the raw JSON string to verify it is valid JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // "by_module" with nested sub-agg "top"
    const by_module = root.get("by_module").?.object;
    const terms_inner = by_module.get("terms").?.object;
    try testing.expectEqualStrings("module_id", terms_inner.get("field").?.string);
    try testing.expectEqual(@as(i64, 10), terms_inner.get("size").?.integer);

    const nested_aggs = by_module.get("aggs").?.object;
    const top_agg = nested_aggs.get("top").?.object;
    try testing.expect(top_agg.get("top_hits") != null);
    try testing.expectEqual(@as(i64, 3), top_agg.get("top_hits").?.object.get("size").?.integer);

    // "count_active" value_count
    const count_active = root.get("count_active").?.object;
    const vc_inner = count_active.get("value_count").?.object;
    try testing.expectEqualStrings("active", vc_inner.get("field").?.string);
}
