const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Value unions
// ---------------------------------------------------------------------------

/// A single scalar value used in `term`, `prefix`, `wildcard`, and `range`
/// queries.  The set of alternatives mirrors the types Elasticsearch accepts
/// for those query clauses.
pub const TermValue = union(enum) {
    bool_val: bool,
    u64_val: u64,
    i64_val: i64,
    f64_val: f64,
    string_val: []const u8,

    pub fn toJsonValue(self: TermValue) std.json.Value {
        return switch (self) {
            .bool_val => |v| .{ .bool = v },
            .u64_val => |v| .{ .integer = @intCast(v) },
            .i64_val => |v| .{ .integer = v },
            .f64_val => |v| .{ .float = v },
            .string_val => |v| .{ .string = v },
        };
    }
};

/// Multiple values for a `terms` query.  Elasticsearch accepts homogeneous
/// arrays; we support the three flavours that matter for SNOMED workloads.
pub const TermsValues = union(enum) {
    u64_slice: []const u64,
    i64_slice: []const i64,
    string_slice: []const []const u8,
};

/// Scalar bound value in a `range` query.
pub const RangeValue = union(enum) {
    u64_val: u64,
    i64_val: i64,
    f64_val: f64,
    string_val: []const u8,

    pub fn toJsonValue(self: RangeValue) std.json.Value {
        return switch (self) {
            .u64_val => |v| .{ .integer = @intCast(v) },
            .i64_val => |v| .{ .integer = v },
            .f64_val => |v| .{ .float = v },
            .string_val => |v| .{ .string = v },
        };
    }
};

// ---------------------------------------------------------------------------
// Per-query-type payload structs
// ---------------------------------------------------------------------------

pub const TermQuery = struct {
    field_name: []const u8,
    value: TermValue,
};

pub const TermsQuery = struct {
    field_name: []const u8,
    values: TermsValues,
};

pub const MatchQuery = struct {
    field_name: []const u8,
    text: []const u8,
};

pub const MatchAllQuery = struct {};

pub const BoolOpts = struct {
    must: ?[]const Query = null,
    filter: ?[]const Query = null,
    should: ?[]const Query = null,
    must_not: ?[]const Query = null,
};

pub const BoolQuery = struct {
    opts: BoolOpts,
};

pub const RangeQuery = struct {
    field_name: []const u8,
    gt_val: ?RangeValue = null,
    gte_val: ?RangeValue = null,
    lt_val: ?RangeValue = null,
    lte_val: ?RangeValue = null,
};

pub const ExistsQuery = struct {
    field_name: []const u8,
};

pub const PrefixQuery = struct {
    field_name: []const u8,
    value: []const u8,
};

pub const IdsQuery = struct {
    values: []const []const u8,
};

pub const NestedQuery = struct {
    path: []const u8,
    query: *const Query,
};

pub const WildcardQuery = struct {
    field_name: []const u8,
    pattern: []const u8,
};

// ---------------------------------------------------------------------------
// RangeBuilder – returned by Query.range(), supports chaining
// ---------------------------------------------------------------------------

/// Builder for `range` queries.  Obtain one via `Query.range(field)`, chain
/// `.gt()` / `.gte()` / `.lt()` / `.lte()`, and finish with `.build()`.
pub const RangeBuilder = struct {
    field_name: []const u8,
    gt_val: ?RangeValue = null,
    gte_val: ?RangeValue = null,
    lt_val: ?RangeValue = null,
    lte_val: ?RangeValue = null,

    pub fn gt(self: RangeBuilder, value: anytype) RangeBuilder {
        var copy = self;
        copy.gt_val = toRangeValue(value);
        return copy;
    }

    pub fn gte(self: RangeBuilder, value: anytype) RangeBuilder {
        var copy = self;
        copy.gte_val = toRangeValue(value);
        return copy;
    }

    pub fn lt(self: RangeBuilder, value: anytype) RangeBuilder {
        var copy = self;
        copy.lt_val = toRangeValue(value);
        return copy;
    }

    pub fn lte(self: RangeBuilder, value: anytype) RangeBuilder {
        var copy = self;
        copy.lte_val = toRangeValue(value);
        return copy;
    }

    pub fn build(self: RangeBuilder) Query {
        return .{ .range_q = .{
            .field_name = self.field_name,
            .gt_val = self.gt_val,
            .gte_val = self.gte_val,
            .lt_val = self.lt_val,
            .lte_val = self.lte_val,
        } };
    }
};

// ---------------------------------------------------------------------------
// Query – the top-level tagged union
// ---------------------------------------------------------------------------

/// Represents any Elasticsearch query DSL node.
/// Queries compose — a bool query contains other Query values.
pub const Query = union(enum) {
    term_q: TermQuery,
    terms_q: TermsQuery,
    match_q: MatchQuery,
    match_all: MatchAllQuery,
    bool_query: BoolQuery,
    range_q: RangeQuery,
    exists_q: ExistsQuery,
    prefix_q: PrefixQuery,
    ids_q: IdsQuery,
    nested_q: NestedQuery,
    wildcard_q: WildcardQuery,

    // -----------------------------------------------------------------------
    // Constructors
    // -----------------------------------------------------------------------

    /// `{"term": {"<field>": <value>}}`
    pub fn term(field_name: []const u8, value: anytype) Query {
        return .{ .term_q = .{
            .field_name = field_name,
            .value = toTermValue(value),
        } };
    }

    /// `{"terms": {"<field>": [...]}}` — handles large `[]u64` slices.
    pub fn terms(field_name: []const u8, values: anytype) Query {
        return .{ .terms_q = .{
            .field_name = field_name,
            .values = toTermsValues(values),
        } };
    }

    /// `{"match": {"<field>": "<text>"}}`
    pub fn match(field_name: []const u8, text: []const u8) Query {
        return .{ .match_q = .{
            .field_name = field_name,
            .text = text,
        } };
    }

    /// `{"match_all": {}}`
    pub fn matchAll() Query {
        return .{ .match_all = .{} };
    }

    /// `{"bool": {"must": [...], "filter": [...], ...}}`
    pub fn boolQuery(opts: BoolOpts) Query {
        return .{ .bool_query = .{ .opts = opts } };
    }

    /// Returns a `RangeBuilder` for chaining `.gt()` / `.gte()` / `.lt()` /
    /// `.lte()`, finished with `.build()`.
    pub fn range(field_name: []const u8) RangeBuilder {
        return .{ .field_name = field_name };
    }

    /// `{"exists": {"field": "<name>"}}`
    pub fn exists(field_name: []const u8) Query {
        return .{ .exists_q = .{ .field_name = field_name } };
    }

    /// `{"prefix": {"<field>": "<value>"}}`
    pub fn prefix(field_name: []const u8, value: []const u8) Query {
        return .{ .prefix_q = .{
            .field_name = field_name,
            .value = value,
        } };
    }

    /// `{"ids": {"values": [...]}}`
    pub fn ids(values: []const []const u8) Query {
        return .{ .ids_q = .{ .values = values } };
    }

    /// `{"nested": {"path": "...", "query": {...}}}`
    pub fn nested(path: []const u8, query: *const Query) Query {
        return .{ .nested_q = .{
            .path = path,
            .query = query,
        } };
    }

    /// `{"wildcard": {"<field>": "<pattern>"}}`
    pub fn wildcard(field_name: []const u8, pattern: []const u8) Query {
        return .{ .wildcard_q = .{
            .field_name = field_name,
            .pattern = pattern,
        } };
    }

    // -----------------------------------------------------------------------
    // Serialization
    // -----------------------------------------------------------------------

    /// Serialize this query to an `std.json.Value` object tree.
    /// All intermediate allocations are made through `allocator`; the caller
    /// is responsible for freeing (or, preferably, pass an arena).
    pub fn toJsonValue(self: Query, allocator: Allocator) Allocator.Error!std.json.Value {
        return switch (self) {
            .term_q => |q| try serializeTerm(allocator, q),
            .terms_q => |q| try serializeTerms(allocator, q),
            .match_q => |q| try serializeMatch(allocator, q),
            .match_all => try serializeMatchAll(allocator),
            .bool_query => |q| try serializeBool(allocator, q),
            .range_q => |q| try serializeRange(allocator, q),
            .exists_q => |q| try serializeExists(allocator, q),
            .prefix_q => |q| try serializePrefix(allocator, q),
            .ids_q => |q| try serializeIds(allocator, q),
            .nested_q => |q| try serializeNested(allocator, q),
            .wildcard_q => |q| try serializeWildcard(allocator, q),
        };
    }

    /// Serialize this query to a caller-owned JSON `[]u8`.
    /// The returned slice is allocated with `allocator`; all temporary
    /// memory used during tree construction is freed before returning.
    pub fn toJson(self: Query, allocator: Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const json_value = try self.toJsonValue(arena.allocator());
        return std.json.Stringify.valueAlloc(allocator, json_value, .{});
    }
};

// ---------------------------------------------------------------------------
// Helpers – comptime value coercion
// ---------------------------------------------------------------------------

fn toTermValue(value: anytype) TermValue {
    const T = @TypeOf(value);
    if (T == bool) return .{ .bool_val = value };
    if (T == comptime_int) {
        if (value < 0) {
            return .{ .i64_val = @as(i64, value) };
        }
        return .{ .u64_val = @as(u64, value) };
    }
    if (T == comptime_float) return .{ .f64_val = @as(f64, value) };

    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness == .signed) {
                return .{ .i64_val = @intCast(value) };
            } else {
                return .{ .u64_val = @intCast(value) };
            }
        },
        .float => return .{ .f64_val = @floatCast(value) },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return .{ .string_val = value };
            }
            // *const [N]u8  →  []const u8
            if (ptr.size == .one) {
                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8) {
                    return .{ .string_val = value };
                }
            }
        },
        else => {},
    }
    @compileError("Unsupported term value type: " ++ @typeName(T));
}

fn toTermsValues(values: anytype) TermsValues {
    const T = @TypeOf(values);
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u64) return .{ .u64_slice = values };
                if (ptr.child == i64) return .{ .i64_slice = values };
                if (ptr.child == []const u8) return .{ .string_slice = values };
            }
        },
        else => {},
    }
    @compileError("Unsupported terms values type: " ++ @typeName(T));
}

fn toRangeValue(value: anytype) RangeValue {
    const T = @TypeOf(value);
    if (T == comptime_int) {
        if (value < 0) {
            return .{ .i64_val = @as(i64, value) };
        }
        return .{ .u64_val = @as(u64, value) };
    }
    if (T == comptime_float) return .{ .f64_val = @as(f64, value) };

    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness == .signed) {
                return .{ .i64_val = @intCast(value) };
            } else {
                return .{ .u64_val = @intCast(value) };
            }
        },
        .float => return .{ .f64_val = @floatCast(value) },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return .{ .string_val = value };
            }
            if (ptr.size == .one) {
                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8) {
                    return .{ .string_val = value };
                }
            }
        },
        else => {},
    }
    @compileError("Unsupported range value type: " ++ @typeName(T));
}

// ---------------------------------------------------------------------------
// JSON object helpers
// ---------------------------------------------------------------------------

/// Create a new `std.json.ObjectMap`.
fn newObject(allocator: Allocator) std.json.ObjectMap {
    return std.json.ObjectMap.init(allocator);
}

/// Wrap an `ObjectMap` in a `Value.object`.
fn objectValue(map: std.json.ObjectMap) std.json.Value {
    return .{ .object = map };
}

/// Wrap a single key/value pair in an object.
fn wrapObject(allocator: Allocator, key: []const u8, val: std.json.Value) !std.json.Value {
    var map = newObject(allocator);
    try map.put(key, val);
    return objectValue(map);
}

// ---------------------------------------------------------------------------
// Per-query-type serializers
// ---------------------------------------------------------------------------

fn serializeTerm(allocator: Allocator, q: TermQuery) !std.json.Value {
    const inner = try wrapObject(allocator, q.field_name, q.value.toJsonValue());
    return wrapObject(allocator, "term", inner);
}

fn serializeTerms(allocator: Allocator, q: TermsQuery) !std.json.Value {
    const arr_val: std.json.Value = switch (q.values) {
        .u64_slice => |slice| blk: {
            var arr = try std.json.Array.initCapacity(allocator, slice.len);
            for (slice) |v| {
                arr.appendAssumeCapacity(.{ .integer = @intCast(v) });
            }
            break :blk .{ .array = arr };
        },
        .i64_slice => |slice| blk: {
            var arr = try std.json.Array.initCapacity(allocator, slice.len);
            for (slice) |v| {
                arr.appendAssumeCapacity(.{ .integer = v });
            }
            break :blk .{ .array = arr };
        },
        .string_slice => |slice| blk: {
            var arr = try std.json.Array.initCapacity(allocator, slice.len);
            for (slice) |v| {
                arr.appendAssumeCapacity(.{ .string = v });
            }
            break :blk .{ .array = arr };
        },
    };

    const inner = try wrapObject(allocator, q.field_name, arr_val);
    return wrapObject(allocator, "terms", inner);
}

fn serializeMatch(allocator: Allocator, q: MatchQuery) !std.json.Value {
    const inner = try wrapObject(allocator, q.field_name, .{ .string = q.text });
    return wrapObject(allocator, "match", inner);
}

fn serializeMatchAll(allocator: Allocator) !std.json.Value {
    var empty = newObject(allocator);
    _ = &empty;
    return wrapObject(allocator, "match_all", objectValue(empty));
}

fn serializeExists(allocator: Allocator, q: ExistsQuery) !std.json.Value {
    const inner = try wrapObject(allocator, "field", .{ .string = q.field_name });
    return wrapObject(allocator, "exists", inner);
}

fn serializePrefix(allocator: Allocator, q: PrefixQuery) !std.json.Value {
    const inner = try wrapObject(allocator, q.field_name, .{ .string = q.value });
    return wrapObject(allocator, "prefix", inner);
}

fn serializeWildcard(allocator: Allocator, q: WildcardQuery) !std.json.Value {
    const inner = try wrapObject(allocator, q.field_name, .{ .string = q.pattern });
    return wrapObject(allocator, "wildcard", inner);
}

fn serializeIds(allocator: Allocator, q: IdsQuery) !std.json.Value {
    var arr = try std.json.Array.initCapacity(allocator, q.values.len);
    for (q.values) |v| {
        arr.appendAssumeCapacity(.{ .string = v });
    }
    const inner = try wrapObject(allocator, "values", .{ .array = arr });
    return wrapObject(allocator, "ids", inner);
}

fn serializeNested(allocator: Allocator, q: NestedQuery) !std.json.Value {
    var inner = newObject(allocator);
    try inner.put("path", .{ .string = q.path });
    try inner.put("query", try q.query.toJsonValue(allocator));
    return wrapObject(allocator, "nested", objectValue(inner));
}

fn serializeRange(allocator: Allocator, q: RangeQuery) !std.json.Value {
    var bounds = newObject(allocator);
    if (q.gt_val) |v| try bounds.put("gt", v.toJsonValue());
    if (q.gte_val) |v| try bounds.put("gte", v.toJsonValue());
    if (q.lt_val) |v| try bounds.put("lt", v.toJsonValue());
    if (q.lte_val) |v| try bounds.put("lte", v.toJsonValue());

    const inner = try wrapObject(allocator, q.field_name, objectValue(bounds));
    return wrapObject(allocator, "range", inner);
}

fn serializeBool(allocator: Allocator, q: BoolQuery) !std.json.Value {
    var inner = newObject(allocator);

    if (q.opts.must) |clauses| {
        try inner.put("must", try serializeQueryArray(allocator, clauses));
    }
    if (q.opts.filter) |clauses| {
        try inner.put("filter", try serializeQueryArray(allocator, clauses));
    }
    if (q.opts.should) |clauses| {
        try inner.put("should", try serializeQueryArray(allocator, clauses));
    }
    if (q.opts.must_not) |clauses| {
        try inner.put("must_not", try serializeQueryArray(allocator, clauses));
    }

    return wrapObject(allocator, "bool", objectValue(inner));
}

fn serializeQueryArray(allocator: Allocator, queries: []const Query) !std.json.Value {
    var arr = try std.json.Array.initCapacity(allocator, queries.len);
    for (queries) |q| {
        arr.appendAssumeCapacity(try q.toJsonValue(allocator));
    }
    return .{ .array = arr };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Result of a roundtrip serialisation: holds both the parsed JSON tree and
/// the raw JSON bytes so they can be freed together via `deinit`.
const RoundtripResult = struct {
    parsed: std.json.Parsed(std.json.Value),
    json: []const u8,

    fn deinit(self: *const RoundtripResult) void {
        const allocator = testing.allocator;
        self.parsed.deinit();
        allocator.free(self.json);
    }
};

/// Helper: serialise a Query to JSON, parse it back, and return the parsed
/// value for assertions.  Uses a test arena so the caller doesn't need to
/// worry about freeing.
fn roundtrip(q: Query) !RoundtripResult {
    const allocator = testing.allocator;
    const json = try q.toJson(allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    return .{ .parsed = parsed, .json = json };
}

/// Get an object value from a parsed json Value by key.
fn getObj(val: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (val) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

// ---- term queries --------------------------------------------------------

test "term query with bool" {
    const q = Query.term("active", true);
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const term_obj = getObj(root, "term") orelse return error.MissingKey;
    const field_val = getObj(term_obj, "active") orelse return error.MissingKey;
    try testing.expectEqual(true, field_val.bool);
}

test "term query with u64" {
    const q = Query.term("module_id", @as(u64, 900000000000207008));
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const term_obj = getObj(root, "term") orelse return error.MissingKey;
    const field_val = getObj(term_obj, "module_id") orelse return error.MissingKey;
    try testing.expectEqual(@as(i64, 900000000000207008), field_val.integer);
}

test "term query with string" {
    const q = Query.term("status", "active");
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const term_obj = getObj(root, "term") orelse return error.MissingKey;
    const field_val = getObj(term_obj, "status") orelse return error.MissingKey;
    try testing.expectEqualStrings("active", field_val.string);
}

test "terms query with u64 slice" {
    const concept_ids: []const u64 = &.{
        900000000000207008,
        900000000000012004,
        138875005,
        404684003,
    };
    const q = Query.terms("concept_id", concept_ids);
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const terms_obj = getObj(root, "terms") orelse return error.MissingKey;
    const arr_val = getObj(terms_obj, "concept_id") orelse return error.MissingKey;
    const arr = arr_val.array;
    try testing.expectEqual(@as(usize, 4), arr.items.len);
    try testing.expectEqual(@as(i64, 900000000000207008), arr.items[0].integer);
    try testing.expectEqual(@as(i64, 138875005), arr.items[2].integer);
}

test "terms query with string slice" {
    const vals: []const []const u8 = &.{ "a", "b", "c" };
    const q = Query.terms("tag", vals);
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const terms_obj = getObj(root, "terms") orelse return error.MissingKey;
    const arr_val = getObj(terms_obj, "tag") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 3), arr_val.array.items.len);
    try testing.expectEqualStrings("b", arr_val.array.items[1].string);
}

// ---- match query ---------------------------------------------------------

test "match query" {
    const q = Query.match("term", "clinical finding");
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const match_obj = getObj(root, "match") orelse return error.MissingKey;
    const field_val = getObj(match_obj, "term") orelse return error.MissingKey;
    try testing.expectEqualStrings("clinical finding", field_val.string);
}

// ---- match_all query -----------------------------------------------------

test "match_all query" {
    const q = Query.matchAll();
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const ma_obj = getObj(root, "match_all") orelse return error.MissingKey;
    // match_all is an empty object
    try testing.expectEqual(@as(usize, 0), ma_obj.object.count());
}

// ---- bool query ----------------------------------------------------------

test "bool query with must and filter" {
    const must_clauses = [_]Query{
        Query.term("active", true),
    };
    const filter_clauses = [_]Query{
        Query.term("module_id", @as(u64, 900000000000207008)),
    };

    const q = Query.boolQuery(.{
        .must = &must_clauses,
        .filter = &filter_clauses,
    });
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const bool_obj = getObj(root, "bool") orelse return error.MissingKey;

    // must is an array with one element
    const must_arr = (getObj(bool_obj, "must") orelse return error.MissingKey).array;
    try testing.expectEqual(@as(usize, 1), must_arr.items.len);

    // The first must clause is a term query on "active"
    const first_must = must_arr.items[0];
    const term_inner = getObj(first_must, "term") orelse return error.MissingKey;
    const active_val = getObj(term_inner, "active") orelse return error.MissingKey;
    try testing.expectEqual(true, active_val.bool);

    // filter is an array with one element
    const filter_arr = (getObj(bool_obj, "filter") orelse return error.MissingKey).array;
    try testing.expectEqual(@as(usize, 1), filter_arr.items.len);

    // should and must_not are absent
    try testing.expect(getObj(bool_obj, "should") == null);
    try testing.expect(getObj(bool_obj, "must_not") == null);
}

// ---- range query ---------------------------------------------------------

test "range query with gte" {
    const q = Query.range("module_id").gte(@as(u64, 900000000000207008)).build();
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const range_obj = getObj(root, "range") orelse return error.MissingKey;
    const field_obj = getObj(range_obj, "module_id") orelse return error.MissingKey;
    const gte_val = getObj(field_obj, "gte") orelse return error.MissingKey;
    try testing.expectEqual(@as(i64, 900000000000207008), gte_val.integer);
    // gt, lt, lte should be absent
    try testing.expect(getObj(field_obj, "gt") == null);
    try testing.expect(getObj(field_obj, "lt") == null);
    try testing.expect(getObj(field_obj, "lte") == null);
}

test "range query with gt and lt" {
    const q = Query.range("effective_time")
        .gt("20200101")
        .lt("20210101")
        .build();
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const range_obj = getObj(root, "range") orelse return error.MissingKey;
    const field_obj = getObj(range_obj, "effective_time") orelse return error.MissingKey;
    try testing.expectEqualStrings("20200101", (getObj(field_obj, "gt") orelse return error.MissingKey).string);
    try testing.expectEqualStrings("20210101", (getObj(field_obj, "lt") orelse return error.MissingKey).string);
}

// ---- exists query --------------------------------------------------------

test "exists query" {
    const q = Query.exists("description");
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const exists_obj = getObj(root, "exists") orelse return error.MissingKey;
    const field_val = getObj(exists_obj, "field") orelse return error.MissingKey;
    try testing.expectEqualStrings("description", field_val.string);
}

// ---- prefix query --------------------------------------------------------

test "prefix query" {
    const q = Query.prefix("term", "clin");
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const prefix_obj = getObj(root, "prefix") orelse return error.MissingKey;
    const field_val = getObj(prefix_obj, "term") orelse return error.MissingKey;
    try testing.expectEqualStrings("clin", field_val.string);
}

// ---- ids query -----------------------------------------------------------

test "ids query" {
    const vals: []const []const u8 = &.{ "1", "42", "100" };
    const q = Query.ids(vals);
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const ids_obj = getObj(root, "ids") orelse return error.MissingKey;
    const arr_val = getObj(ids_obj, "values") orelse return error.MissingKey;
    const arr = arr_val.array;
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqualStrings("1", arr.items[0].string);
    try testing.expectEqualStrings("42", arr.items[1].string);
    try testing.expectEqualStrings("100", arr.items[2].string);
}

// ---- wildcard query ------------------------------------------------------

test "wildcard query" {
    const q = Query.wildcard("term", "clin*");
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const wc_obj = getObj(root, "wildcard") orelse return error.MissingKey;
    const field_val = getObj(wc_obj, "term") orelse return error.MissingKey;
    try testing.expectEqualStrings("clin*", field_val.string);
}

// ---- nested query --------------------------------------------------------

test "nested query" {
    const inner_q = Query.term("descriptions.lang", "en");
    const q = Query.nested("descriptions", &inner_q);
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const nested_obj = getObj(root, "nested") orelse return error.MissingKey;
    const path_val = getObj(nested_obj, "path") orelse return error.MissingKey;
    try testing.expectEqualStrings("descriptions", path_val.string);

    const query_obj = getObj(nested_obj, "query") orelse return error.MissingKey;
    const term_obj = getObj(query_obj, "term") orelse return error.MissingKey;
    const lang_val = getObj(term_obj, "descriptions.lang") orelse return error.MissingKey;
    try testing.expectEqualStrings("en", lang_val.string);
}

// ---- deeply nested bool --------------------------------------------------

test "deeply nested bool" {
    // Outer bool: must=[term(active, true)], should=[inner bool]
    // Inner bool: must_not=[exists("retired")], filter=[range(module_id).gte(900...)]

    const inner_must_not = [_]Query{
        Query.exists("retired"),
    };
    const inner_filter = [_]Query{
        Query.range("module_id").gte(@as(u64, 900000000000207008)).build(),
    };
    const inner_bool = Query.boolQuery(.{
        .must_not = &inner_must_not,
        .filter = &inner_filter,
    });

    const outer_must = [_]Query{
        Query.term("active", true),
    };
    const outer_should = [_]Query{
        inner_bool,
    };
    const q = Query.boolQuery(.{
        .must = &outer_must,
        .should = &outer_should,
    });

    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const outer_bool_obj = getObj(root, "bool") orelse return error.MissingKey;

    // outer must
    const must_arr = (getObj(outer_bool_obj, "must") orelse return error.MissingKey).array;
    try testing.expectEqual(@as(usize, 1), must_arr.items.len);

    // outer should — contains the inner bool
    const should_arr = (getObj(outer_bool_obj, "should") orelse return error.MissingKey).array;
    try testing.expectEqual(@as(usize, 1), should_arr.items.len);

    const inner_bool_wrapper = should_arr.items[0];
    const inner_bool_obj = getObj(inner_bool_wrapper, "bool") orelse return error.MissingKey;

    // inner must_not
    const mn_arr = (getObj(inner_bool_obj, "must_not") orelse return error.MissingKey).array;
    try testing.expectEqual(@as(usize, 1), mn_arr.items.len);
    const exists_q = getObj(mn_arr.items[0], "exists") orelse return error.MissingKey;
    try testing.expectEqualStrings("retired", (getObj(exists_q, "field") orelse return error.MissingKey).string);

    // inner filter — range query
    const f_arr = (getObj(inner_bool_obj, "filter") orelse return error.MissingKey).array;
    try testing.expectEqual(@as(usize, 1), f_arr.items.len);
    const range_q = getObj(f_arr.items[0], "range") orelse return error.MissingKey;
    const mid_obj = getObj(range_q, "module_id") orelse return error.MissingKey;
    const gte_v = getObj(mid_obj, "gte") orelse return error.MissingKey;
    try testing.expectEqual(@as(i64, 900000000000207008), gte_v.integer);
}

// ---- term query with comptime_int (negative) -----------------------------

test "term query with negative i64" {
    const q = Query.term("offset", @as(i64, -42));
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const term_obj = getObj(root, "term") orelse return error.MissingKey;
    const field_val = getObj(term_obj, "offset") orelse return error.MissingKey;
    try testing.expectEqual(@as(i64, -42), field_val.integer);
}

// ---- range query with all four bounds ------------------------------------

test "range query with all bounds" {
    const q = Query.range("score")
        .gt(@as(i64, 10))
        .gte(@as(i64, 10))
        .lt(@as(i64, 100))
        .lte(@as(i64, 100))
        .build();
    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const range_obj = getObj(root, "range") orelse return error.MissingKey;
    const field_obj = getObj(range_obj, "score") orelse return error.MissingKey;
    try testing.expectEqual(@as(i64, 10), (getObj(field_obj, "gt") orelse return error.MissingKey).integer);
    try testing.expectEqual(@as(i64, 10), (getObj(field_obj, "gte") orelse return error.MissingKey).integer);
    try testing.expectEqual(@as(i64, 100), (getObj(field_obj, "lt") orelse return error.MissingKey).integer);
    try testing.expectEqual(@as(i64, 100), (getObj(field_obj, "lte") orelse return error.MissingKey).integer);
}

// ---- bool query with all four clauses ------------------------------------

test "bool query with all clause types" {
    const must = [_]Query{Query.term("active", true)};
    const filter = [_]Query{Query.exists("module_id")};
    const should = [_]Query{Query.match("term", "heart")};
    const must_not = [_]Query{Query.term("retired", true)};

    const q = Query.boolQuery(.{
        .must = &must,
        .filter = &filter,
        .should = &should,
        .must_not = &must_not,
    });

    const rt = try roundtrip(q);
    defer rt.deinit();

    const root = rt.parsed.value;
    const bool_obj = getObj(root, "bool") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 1), (getObj(bool_obj, "must") orelse return error.MissingKey).array.items.len);
    try testing.expectEqual(@as(usize, 1), (getObj(bool_obj, "filter") orelse return error.MissingKey).array.items.len);
    try testing.expectEqual(@as(usize, 1), (getObj(bool_obj, "should") orelse return error.MissingKey).array.items.len);
    try testing.expectEqual(@as(usize, 1), (getObj(bool_obj, "must_not") orelse return error.MissingKey).array.items.len);
}
