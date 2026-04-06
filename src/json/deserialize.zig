//! Comptime JSON deserializer for Elasticsearch responses.
//!
//! Provides convenience wrappers around `std.json.parseFromSlice` that are
//! pre-configured for the conventions used by Elasticsearch's REST API:
//!
//! - Unknown fields are silently ignored (ES responses contain many fields
//!   a consumer typically does not care about).
//! - Optional struct fields map to `null` when the corresponding JSON key is
//!   absent.
//! - `u64` is used for SNOMED concept IDs (they exceed 32-bit range).
//! - Large `[]const u64` arrays are supported without per-element allocation
//!   overhead — `std.json` already handles this efficiently via arena
//!   allocation.
//! - `[]const u8` maps to JSON strings.
//!
//! ## Example
//!
//! ```zig
//! const Concept = struct {
//!     id: u64,
//!     active: bool,
//!     module_id: u64,
//!     term: ?[]const u8 = null,
//! };
//!
//! var parsed = try deserialize.fromJson(Concept, allocator, json_bytes);
//! defer parsed.deinit();
//!
//! const concept = parsed.value;
//! ```

const std = @import("std");

/// Default parse options tuned for Elasticsearch response payloads.
///
/// - `ignore_unknown_fields`: ES responses include many metadata fields that
///   client structs intentionally omit. Ignoring them avoids deserialization
///   errors and keeps Zig struct definitions minimal.
/// - `allocate`: `.alloc_always` ensures every string and slice is copied into
///   the arena, so the caller is free to discard the input buffer immediately
///   after parsing.
pub const es_parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

/// Parses a JSON byte slice into a value of type `T`.
///
/// The returned `std.json.Parsed(T)` owns all memory allocated during parsing
/// via an internal arena allocator. Call `.deinit()` when the value is no
/// longer needed to release all associated memory at once.
///
/// Unknown JSON fields that do not correspond to a Zig struct field are
/// silently skipped — this is essential for ES responses which routinely
/// contain fields the caller's struct does not model.
///
/// ## Parameters
///
/// - `T`: The target Zig type to deserialize into. Supports structs (including
///   nested), optionals (`?T`), slices (`[]const T`), enums (decoded from
///   lowercase JSON strings), booleans, integers, floats, and `[]const u8`.
/// - `allocator`: Backing allocator used to create the internal arena.
/// - `json_bytes`: Raw JSON input.
///
/// ## Errors
///
/// Returns `error.UnexpectedToken`, `error.SyntaxError`, or other
/// `std.json`-defined errors when the input is malformed or structurally
/// incompatible with `T`.
pub fn fromJson(comptime T: type, allocator: std.mem.Allocator, json_bytes: []const u8) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, json_bytes, es_parse_options);
}

/// Parses a JSON byte slice into a value of type `T`, allocating into the
/// provided allocator *without* wrapping the result in a `Parsed` container.
///
/// This is intended for callers that already manage memory via their own arena
/// (e.g. request-scoped arenas). All allocations performed during parsing —
/// including slices and strings — go directly into `allocator`. It is the
/// caller's responsibility to free or reset that allocator when appropriate.
///
/// Like `fromJson`, unknown fields are silently ignored.
///
/// ## Parameters
///
/// - `T`: The target Zig type.
/// - `allocator`: Allocator that will own all parsed memory.
/// - `json_bytes`: Raw JSON input.
pub fn fromJsonLeaky(comptime T: type, allocator: std.mem.Allocator, json_bytes: []const u8) std.json.ParseError(std.json.Scanner)!T {
    return std.json.parseFromSliceLeaky(T, allocator, json_bytes, es_parse_options);
}

// ---------------------------------------------------------------------------
// Elasticsearch response type helpers
// ---------------------------------------------------------------------------

/// A generic Elasticsearch search response envelope.
///
/// `T` is the document type stored in `_source`. This struct captures the
/// outermost shape of an ES `_search` response, including the `hits.hits`
/// array and total hit count. Fields that are not modelled (e.g. `_shards`,
/// `timed_out`) are silently ignored during parsing.
pub fn SearchResponse(comptime T: type) type {
    return struct {
        hits: HitsEnvelope(T),

        /// Milliseconds elapsed on the ES server side.
        took: ?u64 = null,
    };
}

/// The `hits` object inside a search response.
pub fn HitsEnvelope(comptime T: type) type {
    return struct {
        total: ?TotalHits = null,
        hits: []const Hit(T) = &.{},
        max_score: ?f64 = null,
    };
}

/// Represents a single hit inside `hits.hits`.
pub fn Hit(comptime T: type) type {
    return struct {
        _index: ?[]const u8 = null,
        _id: ?[]const u8 = null,
        _score: ?f64 = null,
        _source: ?T = null,
    };
}

/// The `total` object inside `hits`, which may be an exact or lower-bound count.
pub const TotalHits = struct {
    value: u64 = 0,
    relation: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse simple struct from JSON" {
    const Concept = struct {
        id: u64,
        active: bool,
        term: []const u8,
    };

    const json =
        \\{"id": 123456, "active": true, "term": "Clinical finding"}
    ;

    var parsed = try fromJson(Concept, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 123456), parsed.value.id);
    try std.testing.expectEqual(true, parsed.value.active);
    try std.testing.expectEqualStrings("Clinical finding", parsed.value.term);
}

test "unknown fields are ignored" {
    const Small = struct {
        name: []const u8,
    };

    const json =
        \\{"name": "hello", "extra_field": 42, "another": [1,2,3], "nested": {"a": true}}
    ;

    var parsed = try fromJson(Small, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello", parsed.value.name);
}

test "optional fields — present and absent" {
    const WithOptionals = struct {
        required: u64,
        maybe_string: ?[]const u8 = null,
        maybe_number: ?u64 = null,
    };

    // Both optionals present.
    {
        const json =
            \\{"required": 1, "maybe_string": "yes", "maybe_number": 99}
        ;
        var parsed = try fromJson(WithOptionals, std.testing.allocator, json);
        defer parsed.deinit();

        try std.testing.expectEqual(@as(u64, 1), parsed.value.required);
        try std.testing.expectEqualStrings("yes", parsed.value.maybe_string.?);
        try std.testing.expectEqual(@as(u64, 99), parsed.value.maybe_number.?);
    }

    // Both optionals absent.
    {
        const json =
            \\{"required": 2}
        ;
        var parsed = try fromJson(WithOptionals, std.testing.allocator, json);
        defer parsed.deinit();

        try std.testing.expectEqual(@as(u64, 2), parsed.value.required);
        try std.testing.expect(parsed.value.maybe_string == null);
        try std.testing.expect(parsed.value.maybe_number == null);
    }

    // Explicit null.
    {
        const json =
            \\{"required": 3, "maybe_string": null}
        ;
        var parsed = try fromJson(WithOptionals, std.testing.allocator, json);
        defer parsed.deinit();

        try std.testing.expectEqual(@as(u64, 3), parsed.value.required);
        try std.testing.expect(parsed.value.maybe_string == null);
    }
}

test "nested structs" {
    const Inner = struct {
        value: u64,
        label: ?[]const u8 = null,
    };
    const Outer = struct {
        name: []const u8,
        inner: Inner,
    };

    const json =
        \\{"name": "container", "inner": {"value": 42, "label": "nested"}}
    ;

    var parsed = try fromJson(Outer, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("container", parsed.value.name);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.inner.value);
    try std.testing.expectEqualStrings("nested", parsed.value.inner.label.?);
}

test "arrays of u64 — SNOMED concept IDs" {
    const ConceptDoc = struct {
        id: u64,
        ancestors: []const u64,
    };

    const json =
        \\{
        \\  "id": 404684003,
        \\  "ancestors": [
        \\    900000000000207008,
        \\    900000000000012004,
        \\    138875005,
        \\    404684003,
        \\    64572001,
        \\    12345678901234567
        \\  ]
        \\}
    ;

    var parsed = try fromJson(ConceptDoc, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 404684003), parsed.value.id);
    try std.testing.expectEqual(@as(usize, 6), parsed.value.ancestors.len);
    try std.testing.expectEqual(@as(u64, 900000000000207008), parsed.value.ancestors[0]);
    try std.testing.expectEqual(@as(u64, 900000000000012004), parsed.value.ancestors[1]);
    try std.testing.expectEqual(@as(u64, 138875005), parsed.value.ancestors[2]);
    try std.testing.expectEqual(@as(u64, 12345678901234567), parsed.value.ancestors[5]);
}

test "realistic ES search response" {
    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
        term: ?[]const u8 = null,
    };

    const json =
        \\{
        \\  "took": 5,
        \\  "timed_out": false,
        \\  "_shards": {"total": 5, "successful": 5, "skipped": 0, "failed": 0},
        \\  "hits": {
        \\    "total": {"value": 2, "relation": "eq"},
        \\    "max_score": 1.0,
        \\    "hits": [
        \\      {
        \\        "_index": "concepts-v1",
        \\        "_id": "404684003",
        \\        "_score": 1.0,
        \\        "_source": {
        \\          "id": 404684003,
        \\          "active": true,
        \\          "module_id": 900000000000207008,
        \\          "term": "Clinical finding"
        \\        }
        \\      },
        \\      {
        \\        "_index": "concepts-v1",
        \\        "_id": "138875005",
        \\        "_score": 0.8,
        \\        "_source": {
        \\          "id": 138875005,
        \\          "active": true,
        \\          "module_id": 900000000000207008
        \\        }
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var parsed = try fromJson(SearchResponse(Concept), std.testing.allocator, json);
    defer parsed.deinit();

    const resp = parsed.value;

    // Top-level fields.
    try std.testing.expectEqual(@as(u64, 5), resp.took.?);

    // Total hits.
    try std.testing.expectEqual(@as(u64, 2), resp.hits.total.?.value);
    try std.testing.expectEqualStrings("eq", resp.hits.total.?.relation.?);

    // Individual hits.
    try std.testing.expectEqual(@as(usize, 2), resp.hits.hits.len);

    const hit0 = resp.hits.hits[0];
    try std.testing.expectEqualStrings("concepts-v1", hit0._index.?);
    try std.testing.expectEqualStrings("404684003", hit0._id.?);
    try std.testing.expectEqual(@as(u64, 404684003), hit0._source.?.id);
    try std.testing.expectEqual(true, hit0._source.?.active);
    try std.testing.expectEqual(@as(u64, 900000000000207008), hit0._source.?.module_id);
    try std.testing.expectEqualStrings("Clinical finding", hit0._source.?.term.?);

    const hit1 = resp.hits.hits[1];
    try std.testing.expectEqual(@as(u64, 138875005), hit1._source.?.id);
    // term was absent in the second hit's _source.
    try std.testing.expect(hit1._source.?.term == null);
}

test "malformed JSON returns error" {
    const Simple = struct {
        id: u64,
    };

    const bad_json = "{{not json at all";

    const result = fromJson(Simple, std.testing.allocator, bad_json);
    try std.testing.expectError(error.SyntaxError, result);
}

test "fromJsonLeaky with arena allocator" {
    const Tag = struct {
        name: []const u8,
        weight: f64,
    };

    const json =
        \\{"name": "disorder", "weight": 0.95}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tag = try fromJsonLeaky(Tag, arena.allocator(), json);

    try std.testing.expectEqualStrings("disorder", tag.name);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), tag.weight, 0.001);
}

test "enum from lowercase string" {
    const Status = enum {
        active,
        inactive,
        retired,
    };
    const Record = struct {
        status: Status,
    };

    const json =
        \\{"status": "active"}
    ;

    var parsed = try fromJson(Record, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(Status.active, parsed.value.status);
}
