//! Source filtering for Elasticsearch search requests.
//!
//! Elasticsearch supports three forms of `_source` control on search requests:
//!
//! 1. `"_source": false` — exclude source entirely from results
//! 2. `"_source": ["field1", "field2"]` — include only the listed fields
//! 3. `"_source": {"includes": [...], "excludes": [...]}` — full include/exclude control
//!
//! This module provides `SourceFilter`, a tagged union that models all three
//! forms and serializes to the corresponding `std.json.Value` tree.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Controls which `_source` fields are returned by Elasticsearch.
///
/// Three modes are supported:
/// - `.disabled` — `"_source": false` (no source in hits)
/// - `.includes` — `"_source": ["field1", "field2"]` (include list only)
/// - `.full` — `"_source": {"includes": [...], "excludes": [...]}` (full control)
///
/// Construct a value of this union and call `toJsonValue` to obtain the
/// `std.json.Value` tree, or `toJson` to obtain a caller-owned JSON byte
/// string suitable for embedding in a search request body.
pub const SourceFilter = union(enum) {
    /// Exclude `_source` entirely from search results.
    ///
    /// Produces: `"_source": false`
    disabled,

    /// Include only the specified fields in `_source`.
    ///
    /// Produces: `"_source": ["field1", "field2", ...]`
    includes: []const []const u8,

    /// Full include/exclude control over `_source` fields.
    ///
    /// Produces: `"_source": {"includes": [...], "excludes": [...]}`
    full: FullFilter,

    /// Configuration for the full include/exclude form of source filtering.
    pub const FullFilter = struct {
        /// Fields to include in `_source`. Defaults to empty (all included).
        includes: []const []const u8 = &.{},
        /// Fields to exclude from `_source`. Defaults to empty (none excluded).
        excludes: []const []const u8 = &.{},
    };

    /// Serialize this source filter to a `std.json.Value`.
    ///
    /// - `.disabled` → `false`
    /// - `.includes` → JSON array of field-name strings
    /// - `.full` → `{"includes": [...], "excludes": [...]}`
    ///
    /// All intermediate allocations use the provided `allocator`. When using
    /// an arena for the value tree (the common pattern), pass the arena's
    /// allocator here and the tree will be freed in bulk when the arena is
    /// deinitialized.
    pub fn toJsonValue(self: SourceFilter, allocator: Allocator) Allocator.Error!std.json.Value {
        switch (self) {
            .disabled => return .{ .bool = false },
            .includes => |fields| {
                var arr = try std.json.Array.initCapacity(allocator, fields.len);
                for (fields) |f| {
                    arr.appendAssumeCapacity(.{ .string = f });
                }
                return .{ .array = arr };
            },
            .full => |f| {
                var obj = std.json.ObjectMap.init(allocator);

                // includes
                var inc_arr = try std.json.Array.initCapacity(allocator, f.includes.len);
                for (f.includes) |name| {
                    inc_arr.appendAssumeCapacity(.{ .string = name });
                }
                try obj.put("includes", .{ .array = inc_arr });

                // excludes
                var exc_arr = try std.json.Array.initCapacity(allocator, f.excludes.len);
                for (f.excludes) |name| {
                    exc_arr.appendAssumeCapacity(.{ .string = name });
                }
                try obj.put("excludes", .{ .array = exc_arr });

                return .{ .object = obj };
            },
        }
    }

    /// Serialize this source filter to a caller-owned JSON byte string.
    ///
    /// Uses an arena internally for the intermediate `std.json.Value` tree;
    /// only the final `[]u8` is allocated with the provided `allocator`.
    /// The caller must free the returned slice with `allocator.free(result)`.
    pub fn toJson(self: SourceFilter, allocator: Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const json_value = try self.toJsonValue(arena.allocator());
        return std.json.Stringify.valueAlloc(allocator, json_value, .{});
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Helper: serialize a `SourceFilter` to JSON and parse it back for
/// structural assertions.
fn roundTrip(sf: SourceFilter) !std.json.Parsed(std.json.Value) {
    const json_bytes = try sf.toJson(testing.allocator);
    defer testing.allocator.free(json_bytes);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json_bytes, .{});
}

test "source filter disabled serializes to false" {
    const sf: SourceFilter = .disabled;
    const json_bytes = try sf.toJson(testing.allocator);
    defer testing.allocator.free(json_bytes);

    try testing.expectEqualStrings("false", json_bytes);

    var parsed = try roundTrip(sf);
    defer parsed.deinit();
    try testing.expect(parsed.value == .bool);
    try testing.expect(parsed.value.bool == false);
}

test "source filter includes serializes to array" {
    const sf: SourceFilter = .{ .includes = &.{ "id", "active" } };
    var parsed = try roundTrip(sf);
    defer parsed.deinit();

    try testing.expect(parsed.value == .array);
    const arr = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("id", arr[0].string);
    try testing.expectEqualStrings("active", arr[1].string);
}

test "source filter empty includes serializes to empty array" {
    const sf: SourceFilter = .{ .includes = &.{} };
    var parsed = try roundTrip(sf);
    defer parsed.deinit();

    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
}

test "source filter full form serializes to object" {
    const sf: SourceFilter = .{
        .full = .{
            .includes = &.{ "id", "active", "module_id" },
            .excludes = &.{"internal_tag"},
        },
    };
    var parsed = try roundTrip(sf);
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    // includes
    const inc = obj.get("includes").?;
    try testing.expect(inc == .array);
    try testing.expectEqual(@as(usize, 3), inc.array.items.len);
    try testing.expectEqualStrings("id", inc.array.items[0].string);
    try testing.expectEqualStrings("active", inc.array.items[1].string);
    try testing.expectEqualStrings("module_id", inc.array.items[2].string);

    // excludes
    const exc = obj.get("excludes").?;
    try testing.expect(exc == .array);
    try testing.expectEqual(@as(usize, 1), exc.array.items.len);
    try testing.expectEqualStrings("internal_tag", exc.array.items[0].string);
}

test "source filter full form with empty slices" {
    const sf: SourceFilter = .{ .full = .{} };
    var parsed = try roundTrip(sf);
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    const inc = obj.get("includes").?;
    try testing.expect(inc == .array);
    try testing.expectEqual(@as(usize, 0), inc.array.items.len);

    const exc = obj.get("excludes").?;
    try testing.expect(exc == .array);
    try testing.expectEqual(@as(usize, 0), exc.array.items.len);
}

test "source filter toJsonValue disabled does not allocate" {
    // .disabled produces a simple .{ .bool = false } — no allocator use.
    const val = try (SourceFilter{ .disabled = {} }).toJsonValue(testing.failing_allocator);
    try testing.expect(val == .bool);
    try testing.expect(val.bool == false);
}
