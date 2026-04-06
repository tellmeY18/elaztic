//! Comptime JSON serializer for Elasticsearch.
//!
//! Builds on `std.json` to produce ES-compatible JSON with the following conventions:
//! - Null optional fields are **omitted** (ES treats missing and `null` differently).
//! - Snake_case field names map 1:1 to ES field names — no transformation needed.
//! - `u64` values (SNOMED concept IDs) serialize as JSON numbers, not strings.
//! - Slices of `u64` are handled efficiently for large `terms` queries.
//! - Enums serialize as their lowercase name strings.
//!
//! Two entry-points are provided:
//! - `toJson`       — allocates and returns a caller-owned `[]u8`.
//! - `toJsonWriter` — streams directly into a `*std.io.Writer`.

const std = @import("std");
const Stringify = std.json.Stringify;

/// Options that control serialization behaviour.
///
/// The struct is intentionally kept small today but exists so that callers can
/// forward-compatibly pass options without source changes when new knobs are
/// added (e.g. pretty-printing, custom field renaming).
pub const SerializeOptions = struct {
    /// When `true`, emit human-readable JSON with newlines and indentation.
    pretty: bool = false,

    /// When `true`, omit struct fields whose value is `null`.
    /// Defaults to `true` because Elasticsearch distinguishes between a
    /// missing field and an explicit JSON `null`.
    omit_null_optional_fields: bool = true,
};

/// Default options used by the convenience helpers.
pub const default_options: SerializeOptions = .{};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Serialize `value` into a caller-owned JSON byte slice.
///
/// The returned memory is allocated with `allocator` and must be freed by the
/// caller via `allocator.free(result)`.
///
/// Supports structs (including nested), optionals, slices, enums, booleans,
/// all integer sizes, floats, and `[]const u8` strings.
///
/// Example:
/// ```
/// const json = try serialize.toJson(allocator, my_struct);
/// defer allocator.free(json);
/// ```
pub fn toJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toJsonWithOptions(allocator, value, default_options);
}

/// Like `toJson` but accepts explicit `SerializeOptions`.
pub fn toJsonWithOptions(allocator: std.mem.Allocator, value: anytype, options: SerializeOptions) ![]u8 {
    const std_opts = toStdJsonOptions(options);
    return Stringify.valueAlloc(allocator, value, std_opts);
}

/// Serialize `value` directly into a `*std.io.Writer`, producing no heap
/// allocations beyond whatever the writer itself performs.
pub fn toJsonWriter(writer: *std.io.Writer, value: anytype) !void {
    return toJsonWriterWithOptions(writer, value, default_options);
}

/// Like `toJsonWriter` but accepts explicit `SerializeOptions`.
pub fn toJsonWriterWithOptions(writer: *std.io.Writer, value: anytype, options: SerializeOptions) !void {
    const std_opts = toStdJsonOptions(options);
    return Stringify.value(value, std_opts, writer);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Map our public `SerializeOptions` to `std.json.Stringify.Options`.
fn toStdJsonOptions(opts: SerializeOptions) Stringify.Options {
    return .{
        .whitespace = if (opts.pretty) .indent_2 else .minified,
        .emit_null_optional_fields = !opts.omit_null_optional_fields,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "serialize simple struct with all field types" {
    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
        term: []const u8,
        score: f64,
    };

    const concept = Concept{
        .id = 138875005,
        .active = true,
        .module_id = 900000000000207008,
        .term = "SNOMED CT Concept",
        .score = 1.5,
    };

    const json = try toJson(std.testing.allocator, concept);
    defer std.testing.allocator.free(json);

    // Parse back to verify structure.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(@as(i64, 138875005), obj.get("id").?.integer);
    try std.testing.expect(obj.get("active").?.bool);
    try std.testing.expectEqual(@as(i64, 900000000000207008), obj.get("module_id").?.integer);
    try std.testing.expectEqualStrings("SNOMED CT Concept", obj.get("term").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), obj.get("score").?.float, 0.001);
}

test "null optionals are omitted" {
    const Doc = struct {
        id: u64,
        title: ?[]const u8,
        description: ?[]const u8,
    };

    const doc = Doc{
        .id = 1,
        .title = "hello",
        .description = null,
    };

    const json = try toJson(std.testing.allocator, doc);
    defer std.testing.allocator.free(json);

    // `description` must not appear in the output at all.
    try std.testing.expect(std.mem.indexOf(u8, json, "description") == null);
    // `title` must be present.
    try std.testing.expect(std.mem.indexOf(u8, json, "title") != null);

    // Parse back and verify only two keys exist.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
}

test "serialize nested structs" {
    const Inner = struct {
        value: u32,
        label: []const u8,
    };

    const Outer = struct {
        name: []const u8,
        nested: Inner,
    };

    const obj = Outer{
        .name = "parent",
        .nested = .{
            .value = 42,
            .label = "child",
        },
    };

    const json = try toJson(std.testing.allocator, obj);
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("parent", root.get("name").?.string);

    const nested = root.get("nested").?.object;
    try std.testing.expectEqual(@as(i64, 42), nested.get("value").?.integer);
    try std.testing.expectEqualStrings("child", nested.get("label").?.string);
}

test "serialize slice of u64 (SNOMED concept IDs)" {
    const TermsQuery = struct {
        concept_id: []const u64,
    };

    const ids = [_]u64{
        900000000000207008,
        900000000000012004,
        138875005,
        404684003,
        123037004,
    };

    const query = TermsQuery{ .concept_id = &ids };

    const json = try toJson(std.testing.allocator, query);
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const arr = parsed.value.object.get("concept_id").?.array;
    try std.testing.expectEqual(@as(usize, 5), arr.items.len);
    try std.testing.expectEqual(@as(i64, 900000000000207008), arr.items[0].integer);
    try std.testing.expectEqual(@as(i64, 900000000000012004), arr.items[1].integer);
    try std.testing.expectEqual(@as(i64, 138875005), arr.items[2].integer);
}

test "serialize enum field" {
    const Status = enum {
        active,
        inactive,
        deprecated,
    };

    const Doc = struct {
        id: u64,
        status: Status,
    };

    const doc = Doc{
        .id = 1,
        .status = .active,
    };

    const json = try toJson(std.testing.allocator, doc);
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("active", parsed.value.object.get("status").?.string);
}

test "round-trip: serialize then parse" {
    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
        term: []const u8,
        effective_time: ?[]const u8,
        definition_status_id: ?u64,
    };

    const original = Concept{
        .id = 138875005,
        .active = true,
        .module_id = 900000000000207008,
        .term = "SNOMED CT Concept (SNOMED RT+CTV3)",
        .effective_time = "20020131",
        .definition_status_id = 900000000000074008,
    };

    const json = try toJson(std.testing.allocator, original);
    defer std.testing.allocator.free(json);

    // Parse the JSON back into a dynamic value tree and verify every field.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 138875005), obj.get("id").?.integer);
    try std.testing.expect(obj.get("active").?.bool);
    try std.testing.expectEqual(@as(i64, 900000000000207008), obj.get("module_id").?.integer);
    try std.testing.expectEqualStrings(
        "SNOMED CT Concept (SNOMED RT+CTV3)",
        obj.get("term").?.string,
    );
    try std.testing.expectEqualStrings("20020131", obj.get("effective_time").?.string);
    try std.testing.expectEqual(@as(i64, 900000000000074008), obj.get("definition_status_id").?.integer);
}

test "toJsonWriter produces identical output to toJson" {
    const Doc = struct {
        a: u32,
        b: []const u8,
    };

    const doc = Doc{ .a = 7, .b = "hi" };

    const allocated = try toJson(std.testing.allocator, doc);
    defer std.testing.allocator.free(allocated);

    var aw: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try toJsonWriter(&aw.writer, doc);

    try std.testing.expectEqualStrings(allocated, aw.written());
}

test "pretty-print option" {
    const Doc = struct {
        id: u64,
        active: bool,
    };

    const doc = Doc{ .id = 1, .active = true };

    const json = try toJsonWithOptions(
        std.testing.allocator,
        doc,
        .{ .pretty = true },
    );
    defer std.testing.allocator.free(json);

    // Pretty-printed output must contain newlines.
    try std.testing.expect(std.mem.indexOf(u8, json, "\n") != null);
}

test "omit_null_optional_fields = false keeps nulls" {
    const Doc = struct {
        id: u64,
        name: ?[]const u8,
    };

    const doc = Doc{ .id = 1, .name = null };

    const json = try toJsonWithOptions(
        std.testing.allocator,
        doc,
        .{ .omit_null_optional_fields = false },
    );
    defer std.testing.allocator.free(json);

    // "name" should be present as a JSON null.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":null") != null);
}
