//! Error types and handling for Elasticsearch operations.
//!
//! Defines the comprehensive error set for ES operations, with retry logic
//! for transient errors (429, 503) and no retries for client errors (4xx except 429).

const std = @import("std");

/// Elasticsearch-specific errors.
/// These map to common ES error conditions and HTTP status codes.
pub const ESError = error{
    /// Connection could not be established (e.g., network unreachable).
    ConnectionRefused,
    /// Connection timed out.
    ConnectionTimeout,
    /// Request timed out on the server side.
    RequestTimeout,
    /// Rate limited (HTTP 429).
    TooManyRequests,
    /// Index does not exist (HTTP 404).
    IndexNotFound,
    /// Document does not exist (HTTP 404).
    DocumentNotFound,
    /// Version conflict in update operations (HTTP 409).
    VersionConflict,
    /// Mapping conflict (HTTP 400).
    MappingConflict,
    /// Shard failure (HTTP 500+).
    ShardFailure,
    /// Cluster is unavailable (HTTP 503).
    ClusterUnavailable,
    /// Unexpected HTTP response status.
    UnexpectedResponse,
    /// Malformed JSON in response.
    MalformedJson,
};

/// Check if an error should trigger a retry.
/// Retries on 429 (TooManyRequests) and 503 (ClusterUnavailable).
/// Never retries on 4xx errors except 429.
pub fn shouldRetry(err: ESError) bool {
    return switch (err) {
        .TooManyRequests, .ClusterUnavailable => true,
        else => false,
    };
}

/// Parsed representation of an Elasticsearch error JSON response.
///
/// Elasticsearch returns errors in a well-defined JSON envelope with an
/// `error` object containing `type`, `reason`, and optionally `index` fields,
/// plus a top-level `status` code. This struct captures those fields and
/// retains ownership of the raw response body so that all string slices
/// remain valid for the lifetime of the envelope.
pub const ErrorEnvelope = struct {
    /// HTTP status code from the ES error envelope (e.g. 404, 409, 503).
    status: u16,
    /// The `error.type` field (e.g. `"index_not_found_exception"`).
    error_type: []const u8,
    /// The `error.reason` field (e.g. `"no such index [foo]"`).
    reason: []const u8,
    /// Optional index name from the `error.index` field, if present.
    index: ?[]const u8,
    /// Arena allocator that owns all string slices in this envelope.
    /// Created during parsing; all strings are copied into this arena.
    _arena: std.heap.ArenaAllocator,

    /// Frees all memory owned by this envelope (string slices and internal state).
    pub fn deinit(self: *ErrorEnvelope) void {
        self._arena.deinit();
        self.* = undefined;
    }

    /// Maps the ES `error.type` string to the corresponding `ESError` value.
    ///
    /// Known mappings:
    /// - `"index_not_found_exception"` → `IndexNotFound`
    /// - `"document_missing_exception"` → `DocumentNotFound`
    /// - `"version_conflict_engine_exception"` → `VersionConflict`
    /// - `"mapper_parsing_exception"` / `"illegal_argument_exception"` → `MappingConflict`
    /// - anything else → `UnexpectedResponse`
    pub fn toESError(self: ErrorEnvelope) ESError {
        const error_type = self.error_type;
        if (std.mem.eql(u8, error_type, "index_not_found_exception")) {
            return ESError.IndexNotFound;
        } else if (std.mem.eql(u8, error_type, "document_missing_exception")) {
            return ESError.DocumentNotFound;
        } else if (std.mem.eql(u8, error_type, "version_conflict_engine_exception")) {
            return ESError.VersionConflict;
        } else if (std.mem.eql(u8, error_type, "mapper_parsing_exception") or
            std.mem.eql(u8, error_type, "illegal_argument_exception"))
        {
            return ESError.MappingConflict;
        } else {
            return ESError.UnexpectedResponse;
        }
    }
};

/// Parses a raw JSON body from an Elasticsearch error response into an `ErrorEnvelope`.
///
/// Ownership of `body` is transferred to the returned `ErrorEnvelope` (stored in
/// `_raw_body`). The caller must not free `body` after a successful call — instead,
/// call `ErrorEnvelope.deinit` when the envelope is no longer needed.
///
/// Returns `error.MalformedJson` if the JSON cannot be parsed or does not contain
/// the expected `error.type`, `error.reason`, and `status` fields.
pub fn parseErrorEnvelope(allocator: std.mem.Allocator, body: []u8) ESError!ErrorEnvelope {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), @as([]const u8, body), .{}) catch {
        return ESError.MalformedJson;
    };

    // Root must be an object.
    const root_obj = switch (root) {
        .object => |obj| obj,
        else => return ESError.MalformedJson,
    };

    // Extract top-level "status" (integer).
    const status_val = root_obj.get("status") orelse return ESError.MalformedJson;
    const status: u16 = switch (status_val) {
        .integer => |i| std.math.cast(u16, i) orelse return ESError.MalformedJson,
        else => return ESError.MalformedJson,
    };

    // Extract "error" object.
    const error_val = root_obj.get("error") orelse return ESError.MalformedJson;
    const error_obj = switch (error_val) {
        .object => |obj| obj,
        else => return ESError.MalformedJson,
    };

    // Extract "error.type" (string).
    const type_val = error_obj.get("type") orelse return ESError.MalformedJson;
    const error_type: []const u8 = switch (type_val) {
        .string => |s| s,
        else => return ESError.MalformedJson,
    };

    // Extract "error.reason" (string).
    const reason_val = error_obj.get("reason") orelse return ESError.MalformedJson;
    const reason: []const u8 = switch (reason_val) {
        .string => |s| s,
        else => return ESError.MalformedJson,
    };

    // Extract optional "error.index" (string or absent).
    const index: ?[]const u8 = if (error_obj.get("index")) |idx_val| switch (idx_val) {
        .string => |s| s,
        else => null,
    } else null;

    // All string slices are allocated in the arena via parseFromSliceLeaky.
    // Free the original body since the data has been copied into the arena.
    allocator.free(body);

    return ErrorEnvelope{
        .status = status,
        .error_type = error_type,
        .reason = reason,
        .index = index,
        ._arena = arena,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseErrorEnvelope — index_not_found_exception" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{"error":{"root_cause":[{"type":"index_not_found_exception","reason":"no such index [foo]","index":"foo"}],"type":"index_not_found_exception","reason":"no such index [foo]","index":"foo"},"status":404}
    ;

    const body = try allocator.dupe(u8, json_str);
    // body ownership transfers to envelope on success.

    var envelope = try parseErrorEnvelope(allocator, body);
    defer envelope.deinit();

    try std.testing.expectEqual(@as(u16, 404), envelope.status);
    try std.testing.expectEqualStrings("index_not_found_exception", envelope.error_type);
    try std.testing.expectEqualStrings("no such index [foo]", envelope.reason);
    try std.testing.expectEqualStrings("foo", envelope.index.?);
    try std.testing.expectEqual(ESError.IndexNotFound, envelope.toESError());
}

test "parseErrorEnvelope — version_conflict_engine_exception" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{"error":{"root_cause":[{"type":"version_conflict_engine_exception","reason":"[1]: version conflict"}],"type":"version_conflict_engine_exception","reason":"[1]: version conflict"},"status":409}
    ;

    const body = try allocator.dupe(u8, json_str);

    var envelope = try parseErrorEnvelope(allocator, body);
    defer envelope.deinit();

    try std.testing.expectEqual(@as(u16, 409), envelope.status);
    try std.testing.expectEqualStrings("version_conflict_engine_exception", envelope.error_type);
    try std.testing.expectEqualStrings("[1]: version conflict", envelope.reason);
    try std.testing.expectEqual(@as(?[]const u8, null), envelope.index);
    try std.testing.expectEqual(ESError.VersionConflict, envelope.toESError());
}

test "toESError — all known mappings" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { json: []const u8, expected: ESError }{
        .{
            .json =
            \\{"error":{"type":"index_not_found_exception","reason":"r"},"status":404}
            ,
            .expected = ESError.IndexNotFound,
        },
        .{
            .json =
            \\{"error":{"type":"document_missing_exception","reason":"r"},"status":404}
            ,
            .expected = ESError.DocumentNotFound,
        },
        .{
            .json =
            \\{"error":{"type":"version_conflict_engine_exception","reason":"r"},"status":409}
            ,
            .expected = ESError.VersionConflict,
        },
        .{
            .json =
            \\{"error":{"type":"mapper_parsing_exception","reason":"r"},"status":400}
            ,
            .expected = ESError.MappingConflict,
        },
        .{
            .json =
            \\{"error":{"type":"illegal_argument_exception","reason":"r"},"status":400}
            ,
            .expected = ESError.MappingConflict,
        },
        .{
            .json =
            \\{"error":{"type":"some_unknown_exception","reason":"r"},"status":500}
            ,
            .expected = ESError.UnexpectedResponse,
        },
    };

    for (cases) |case| {
        const body = try allocator.dupe(u8, case.json);
        var envelope = try parseErrorEnvelope(allocator, body);
        defer envelope.deinit();
        try std.testing.expectEqual(case.expected, envelope.toESError());
    }
}

test "parseErrorEnvelope — malformed JSON returns MalformedJson" {
    const allocator = std.testing.allocator;

    // Completely invalid JSON.
    {
        const body = try allocator.dupe(u8, "not json at all");
        try std.testing.expectError(ESError.MalformedJson, parseErrorEnvelope(allocator, body));
        allocator.free(body); // ownership was NOT transferred on error
    }

    // Valid JSON but missing "error" key.
    {
        const body = try allocator.dupe(u8,
            \\{"status":404}
        );
        try std.testing.expectError(ESError.MalformedJson, parseErrorEnvelope(allocator, body));
        allocator.free(body);
    }

    // Valid JSON but "error" is a string, not an object.
    {
        const body = try allocator.dupe(u8,
            \\{"error":"something bad","status":500}
        );
        try std.testing.expectError(ESError.MalformedJson, parseErrorEnvelope(allocator, body));
        allocator.free(body);
    }

    // Missing "error.type".
    {
        const body = try allocator.dupe(u8,
            \\{"error":{"reason":"r"},"status":404}
        );
        try std.testing.expectError(ESError.MalformedJson, parseErrorEnvelope(allocator, body));
        allocator.free(body);
    }

    // Missing "status".
    {
        const body = try allocator.dupe(u8,
            \\{"error":{"type":"t","reason":"r"}}
        );
        try std.testing.expectError(ESError.MalformedJson, parseErrorEnvelope(allocator, body));
        allocator.free(body);
    }
}
