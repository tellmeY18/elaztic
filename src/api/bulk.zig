//! Bulk API response types and parsing for Elasticsearch.
//!
//! The Elasticsearch bulk API returns a JSON response where each item in the
//! `items` array is an object with exactly one key — the action type (`index`,
//! `create`, `update`, or `delete`) — whose value contains the per-action
//! result fields. This module provides typed representations and a parser for
//! that response format.
//!
//! String slices in `BulkItemResult` (e.g. `index`, `id`, `result`) point into
//! memory owned by the `BulkResponse`'s internal arena. They remain valid until
//! `deinit` is called.

const std = @import("std");

/// Result of a single action in a bulk response.
pub const BulkItemResult = struct {
    /// The action type that produced this result.
    action: Action,
    /// Target index name.
    index: ?[]const u8 = null,
    /// Document ID.
    id: ?[]const u8 = null,
    /// Document version after the operation.
    version: ?i64 = null,
    /// Result description (e.g. "created", "updated", "deleted", "not_found").
    result: ?[]const u8 = null,
    /// HTTP status code for this action.
    status: u16,
    /// Error type string if this action failed, null if successful.
    error_type: ?[]const u8 = null,
    /// Error reason if this action failed.
    error_reason: ?[]const u8 = null,

    /// The action type for a bulk operation.
    pub const Action = enum {
        index,
        create,
        update,
        delete,
    };

    /// Returns true if this action succeeded (2xx status).
    pub fn isSuccess(self: BulkItemResult) bool {
        return self.status >= 200 and self.status < 300;
    }
};

/// Parsed response from the Elasticsearch bulk API.
///
/// All string slices within the contained `BulkItemResult` entries point into
/// an internal arena. Call `deinit` to release all memory at once.
pub const BulkResponse = struct {
    /// Time in milliseconds the bulk request took on the server.
    took: u64,
    /// Whether any of the individual actions had errors.
    errors: bool,
    /// Per-action results. Backed by the internal arena — freed by `deinit`.
    items: []BulkItemResult,

    /// Arena that owns the `items` slice and all string data referenced by items.
    _arena: std.heap.ArenaAllocator,

    /// Free all owned memory (items slice, string data, and the original body
    /// if ownership was transferred via `parseBulkResponse`).
    pub fn deinit(self: *BulkResponse) void {
        self._arena.deinit();
        self.* = undefined;
    }

    /// Returns the count of items that failed (non-2xx status).
    pub fn failureCount(self: BulkResponse) usize {
        var count: usize = 0;
        for (self.items) |item| {
            if (!item.isSuccess()) count += 1;
        }
        return count;
    }

    /// Returns the count of items that succeeded (2xx status).
    pub fn successCount(self: BulkResponse) usize {
        return self.items.len - self.failureCount();
    }
};

/// Known action key strings and their corresponding enum values.
const action_keys = [_]struct { key: []const u8, action: BulkItemResult.Action }{
    .{ .key = "index", .action = .index },
    .{ .key = "create", .action = .create },
    .{ .key = "update", .action = .update },
    .{ .key = "delete", .action = .delete },
};

/// Extract a string value from an object by key, returning null if absent or not a string.
fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract an integer value from an object by key, cast to the requested type.
/// Returns null if absent or not an integer.
fn getOptionalInt(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| std.math.cast(T, i),
        else => null,
    };
}

/// Parse a single item object from the bulk response `items` array.
///
/// Each item is an object with exactly one key (the action type) whose value
/// is another object containing the per-action result fields.
fn parseItem(item_val: std.json.Value) error{MalformedJson}!BulkItemResult {
    const item_obj = switch (item_val) {
        .object => |obj| obj,
        else => return error.MalformedJson,
    };

    // Find the action key.
    for (action_keys) |ak| {
        const inner_val = item_obj.get(ak.key) orelse continue;
        const inner_obj = switch (inner_val) {
            .object => |obj| obj,
            else => return error.MalformedJson,
        };

        // "status" is required on every item result.
        const status = getOptionalInt(u16, inner_obj, "status") orelse return error.MalformedJson;

        // Extract optional error details. ES nests them as an "error" object
        // with "type" and "reason" fields.
        var err_type: ?[]const u8 = null;
        var err_reason: ?[]const u8 = null;
        if (inner_obj.get("error")) |err_val| {
            switch (err_val) {
                .object => |err_obj| {
                    err_type = getOptionalString(err_obj, "type");
                    err_reason = getOptionalString(err_obj, "reason");
                },
                // Some ES versions may return error as a plain string.
                .string => |s| {
                    err_reason = s;
                },
                else => {},
            }
        }

        return BulkItemResult{
            .action = ak.action,
            .index = getOptionalString(inner_obj, "_index"),
            .id = getOptionalString(inner_obj, "_id"),
            .version = getOptionalInt(i64, inner_obj, "_version"),
            .result = getOptionalString(inner_obj, "result"),
            .status = status,
            .error_type = err_type,
            .error_reason = err_reason,
        };
    }

    // No recognised action key found.
    return error.MalformedJson;
}

/// Parse a raw JSON bulk response body into a `BulkResponse`.
///
/// Ownership of `body` is transferred to the returned `BulkResponse` on
/// success. All string slices in the returned items point into an internal
/// arena. Call `BulkResponse.deinit` to free everything.
///
/// On error, ownership is NOT transferred and the caller must free `body`.
pub fn parseBulkResponse(allocator: std.mem.Allocator, body: []u8) error{ MalformedJson, OutOfMemory }!BulkResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Parse using parseFromSliceLeaky — all allocations (including string
    // data inside Value nodes) go through our arena allocator, so string
    // slices remain valid as long as the arena is alive.
    // Note: Value.jsonParse uses .alloc_always, so all string data is
    // copied into the arena. `body` is only read during parsing.
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        @as([]const u8, body),
        .{},
    ) catch return error.MalformedJson;

    const root_obj = switch (parsed) {
        .object => |obj| obj,
        else => return error.MalformedJson,
    };

    // Extract "took" (integer, required).
    const took: u64 = blk: {
        const val = root_obj.get("took") orelse return error.MalformedJson;
        break :blk switch (val) {
            .integer => |i| std.math.cast(u64, i) orelse return error.MalformedJson,
            else => return error.MalformedJson,
        };
    };

    // Extract "errors" (boolean, required).
    const errors_flag: bool = blk: {
        const val = root_obj.get("errors") orelse return error.MalformedJson;
        break :blk switch (val) {
            .bool => |b| b,
            else => return error.MalformedJson,
        };
    };

    // Extract "items" (array, required).
    const items_array = blk: {
        const val = root_obj.get("items") orelse return error.MalformedJson;
        break :blk switch (val) {
            .array => |a| a,
            else => return error.MalformedJson,
        };
    };

    // Allocate the items slice from the arena.
    const items = arena.allocator().alloc(BulkItemResult, items_array.items.len) catch return error.OutOfMemory;

    for (items_array.items, 0..) |item_val, i| {
        items[i] = parseItem(item_val) catch return error.MalformedJson;
    }

    // All validation passed — take ownership of `body` by freeing it now.
    // String data has already been copied into the arena by the JSON parser,
    // so `body` is no longer referenced.
    allocator.free(body);

    return BulkResponse{
        .took = took,
        .errors = errors_flag,
        .items = items,
        ._arena = arena,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseBulkResponse — all successful items" {
    const allocator = std.testing.allocator;

    const json_str = "{\"took\":30,\"errors\":false,\"items\":[" ++
        "{\"index\":{\"_index\":\"test\",\"_id\":\"1\",\"_version\":1,\"result\":\"created\",\"status\":201}}," ++
        "{\"index\":{\"_index\":\"test\",\"_id\":\"2\",\"_version\":1,\"result\":\"created\",\"status\":201}}" ++
        "]}";

    const body = try allocator.dupe(u8, json_str);

    var resp = try parseBulkResponse(allocator, body);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u64, 30), resp.took);
    try std.testing.expectEqual(false, resp.errors);
    try std.testing.expectEqual(@as(usize, 2), resp.items.len);

    try std.testing.expectEqual(BulkItemResult.Action.index, resp.items[0].action);
    try std.testing.expectEqualStrings("test", resp.items[0].index.?);
    try std.testing.expectEqualStrings("1", resp.items[0].id.?);
    try std.testing.expectEqual(@as(i64, 1), resp.items[0].version.?);
    try std.testing.expectEqualStrings("created", resp.items[0].result.?);
    try std.testing.expectEqual(@as(u16, 201), resp.items[0].status);

    try std.testing.expectEqualStrings("2", resp.items[1].id.?);
    try std.testing.expectEqual(@as(u16, 201), resp.items[1].status);
}

test "parseBulkResponse — mixed success and failure items" {
    const allocator = std.testing.allocator;

    const json_str = "{\"took\":15,\"errors\":true,\"items\":[" ++
        "{\"index\":{\"_index\":\"test\",\"_id\":\"1\",\"_version\":1,\"result\":\"created\",\"status\":201}}," ++
        "{\"delete\":{\"_index\":\"test\",\"_id\":\"2\",\"_version\":1,\"result\":\"not_found\",\"status\":404}}," ++
        "{\"create\":{\"_index\":\"test\",\"_id\":\"3\",\"_version\":1,\"result\":\"created\",\"status\":201}}," ++
        "{\"update\":{\"_index\":\"test\",\"_id\":\"4\",\"status\":409,\"error\":{\"type\":\"version_conflict_engine_exception\",\"reason\":\"[4]: version conflict\"}}}" ++
        "]}";

    const body = try allocator.dupe(u8, json_str);

    var resp = try parseBulkResponse(allocator, body);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u64, 15), resp.took);
    try std.testing.expectEqual(true, resp.errors);
    try std.testing.expectEqual(@as(usize, 4), resp.items.len);

    // First item: index, 201 — success.
    try std.testing.expectEqual(BulkItemResult.Action.index, resp.items[0].action);
    try std.testing.expect(resp.items[0].isSuccess());

    // Second item: delete, 404 — failure.
    try std.testing.expectEqual(BulkItemResult.Action.delete, resp.items[1].action);
    try std.testing.expectEqual(@as(u16, 404), resp.items[1].status);
    try std.testing.expect(!resp.items[1].isSuccess());
    try std.testing.expectEqualStrings("not_found", resp.items[1].result.?);

    // Third item: create, 201 — success.
    try std.testing.expectEqual(BulkItemResult.Action.create, resp.items[2].action);
    try std.testing.expect(resp.items[2].isSuccess());

    // Fourth item: update, 409 — failure with error details.
    try std.testing.expectEqual(BulkItemResult.Action.update, resp.items[3].action);
    try std.testing.expectEqual(@as(u16, 409), resp.items[3].status);
    try std.testing.expect(!resp.items[3].isSuccess());
    try std.testing.expectEqualStrings("version_conflict_engine_exception", resp.items[3].error_type.?);
    try std.testing.expectEqualStrings("[4]: version conflict", resp.items[3].error_reason.?);
}

test "failureCount and successCount" {
    const allocator = std.testing.allocator;

    const json_str = "{\"took\":5,\"errors\":true,\"items\":[" ++
        "{\"index\":{\"_index\":\"t\",\"_id\":\"1\",\"status\":201}}," ++
        "{\"index\":{\"_index\":\"t\",\"_id\":\"2\",\"status\":400}}," ++
        "{\"index\":{\"_index\":\"t\",\"_id\":\"3\",\"status\":201}}," ++
        "{\"index\":{\"_index\":\"t\",\"_id\":\"4\",\"status\":429}}," ++
        "{\"index\":{\"_index\":\"t\",\"_id\":\"5\",\"status\":200}}" ++
        "]}";

    const body = try allocator.dupe(u8, json_str);

    var resp = try parseBulkResponse(allocator, body);
    defer resp.deinit();

    try std.testing.expectEqual(@as(usize, 5), resp.items.len);
    try std.testing.expectEqual(@as(usize, 2), resp.failureCount());
    try std.testing.expectEqual(@as(usize, 3), resp.successCount());
}

test "isSuccess — boundary status codes" {
    // 199 is not success.
    const item_199 = BulkItemResult{ .action = .index, .status = 199 };
    try std.testing.expect(!item_199.isSuccess());

    // 200 is success.
    const item_200 = BulkItemResult{ .action = .index, .status = 200 };
    try std.testing.expect(item_200.isSuccess());

    // 201 is success.
    const item_201 = BulkItemResult{ .action = .create, .status = 201 };
    try std.testing.expect(item_201.isSuccess());

    // 299 is success.
    const item_299 = BulkItemResult{ .action = .update, .status = 299 };
    try std.testing.expect(item_299.isSuccess());

    // 300 is not success.
    const item_300 = BulkItemResult{ .action = .delete, .status = 300 };
    try std.testing.expect(!item_300.isSuccess());

    // 404 is not success.
    const item_404 = BulkItemResult{ .action = .delete, .status = 404 };
    try std.testing.expect(!item_404.isSuccess());

    // 500 is not success.
    const item_500 = BulkItemResult{ .action = .index, .status = 500 };
    try std.testing.expect(!item_500.isSuccess());
}

test "parseBulkResponse — error details in failed item" {
    const allocator = std.testing.allocator;

    const json_str = "{\"took\":10,\"errors\":true,\"items\":[" ++
        "{\"index\":{\"_index\":\"products\",\"_id\":\"abc\",\"status\":400," ++
        "\"error\":{\"type\":\"mapper_parsing_exception\"," ++
        "\"reason\":\"failed to parse field [price] of type [float]\"}}}" ++
        "]}";

    const body = try allocator.dupe(u8, json_str);

    var resp = try parseBulkResponse(allocator, body);
    defer resp.deinit();

    try std.testing.expectEqual(true, resp.errors);
    try std.testing.expectEqual(@as(usize, 1), resp.items.len);

    const item = resp.items[0];
    try std.testing.expectEqual(BulkItemResult.Action.index, item.action);
    try std.testing.expectEqual(@as(u16, 400), item.status);
    try std.testing.expect(!item.isSuccess());
    try std.testing.expectEqualStrings("mapper_parsing_exception", item.error_type.?);
    try std.testing.expectEqualStrings("failed to parse field [price] of type [float]", item.error_reason.?);
    try std.testing.expectEqualStrings("products", item.index.?);
    try std.testing.expectEqualStrings("abc", item.id.?);
    // No version or result on a failed item.
    try std.testing.expectEqual(@as(?i64, null), item.version);
    try std.testing.expectEqual(@as(?[]const u8, null), item.result);
}

test "parseBulkResponse — malformed JSON returns error" {
    const allocator = std.testing.allocator;

    // Completely invalid JSON.
    {
        const body = try allocator.dupe(u8, "not json at all");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }

    // Valid JSON but missing "took".
    {
        const body = try allocator.dupe(u8, "{\"errors\":false,\"items\":[]}");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }

    // Valid JSON but missing "errors".
    {
        const body = try allocator.dupe(u8, "{\"took\":1,\"items\":[]}");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }

    // Valid JSON but missing "items".
    {
        const body = try allocator.dupe(u8, "{\"took\":1,\"errors\":false}");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }

    // "items" is not an array.
    {
        const body = try allocator.dupe(u8, "{\"took\":1,\"errors\":false,\"items\":\"bad\"}");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }

    // Item missing action key.
    {
        const body = try allocator.dupe(u8, "{\"took\":1,\"errors\":false,\"items\":[{\"unknown\":{\"status\":200}}]}");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }

    // Item action value is not an object.
    {
        const body = try allocator.dupe(u8, "{\"took\":1,\"errors\":false,\"items\":[{\"index\":\"bad\"}]}");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }

    // Item missing required "status" field.
    {
        const body = try allocator.dupe(u8, "{\"took\":1,\"errors\":false,\"items\":[{\"index\":{\"_id\":\"1\"}}]}");
        try std.testing.expectError(error.MalformedJson, parseBulkResponse(allocator, body));
        allocator.free(body);
    }
}

test "parseBulkResponse — empty items array" {
    const allocator = std.testing.allocator;

    const json_str = "{\"took\":0,\"errors\":false,\"items\":[]}";
    const body = try allocator.dupe(u8, json_str);

    var resp = try parseBulkResponse(allocator, body);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u64, 0), resp.took);
    try std.testing.expectEqual(false, resp.errors);
    try std.testing.expectEqual(@as(usize, 0), resp.items.len);
    try std.testing.expectEqual(@as(usize, 0), resp.failureCount());
    try std.testing.expectEqual(@as(usize, 0), resp.successCount());
}
