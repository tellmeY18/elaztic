//! Document CRUD request and response types for Elasticsearch.
//!
//! Provides typed request structs for indexing, getting, and deleting documents,
//! each with methods to produce the HTTP method, path, and optional body for
//! the Elasticsearch REST API. Response types are generic over the document type
//! so that `_source` is deserialized into the caller's struct.

const std = @import("std");
const Allocator = std.mem.Allocator;
const deserialize = @import("../json/deserialize.zig");

/// Options for indexing a document.
pub const IndexDocOptions = struct {
    /// Optional document ID. If null, Elasticsearch auto-generates one.
    id: ?[]const u8 = null,
};

/// Request to index (create or update) a document in Elasticsearch.
///
/// When `id` is provided the request uses PUT (upsert semantics);
/// when `id` is null the request uses POST and ES generates the ID.
pub const IndexDocRequest = struct {
    /// Target index name.
    index: []const u8,
    /// Optional document ID. `null` means ES auto-generates one.
    id: ?[]const u8 = null,
    /// Serialized document body (JSON bytes, caller-owned).
    body: []const u8,

    /// Returns the HTTP method — `"PUT"` when an ID is given, `"POST"` otherwise.
    pub fn httpMethod(self: IndexDocRequest) []const u8 {
        return if (self.id != null) "PUT" else "POST";
    }

    /// Returns the HTTP path for this request.
    ///
    /// With ID:    `/<index>/_doc/<id>`
    /// Without ID: `/<index>/_doc`
    ///
    /// The returned slice is allocated with `allocator` and must be freed by the caller.
    pub fn httpPath(self: IndexDocRequest, allocator: Allocator) ![]u8 {
        if (self.id) |doc_id| {
            return std.fmt.allocPrint(allocator, "/{s}/_doc/{s}", .{ self.index, doc_id });
        } else {
            return std.fmt.allocPrint(allocator, "/{s}/_doc", .{self.index});
        }
    }

    /// Returns a copy of the document body.
    ///
    /// The returned slice is allocated with `allocator` and must be freed by the caller.
    pub fn httpBody(self: IndexDocRequest, allocator: Allocator) !?[]u8 {
        return try allocator.dupe(u8, self.body);
    }
};

/// Request to get a document by ID from Elasticsearch.
pub const GetDocRequest = struct {
    /// Target index name.
    index: []const u8,
    /// Document ID to retrieve.
    id: []const u8,

    /// Returns the HTTP method (`"GET"`).
    pub fn httpMethod(_: GetDocRequest) []const u8 {
        return "GET";
    }

    /// Returns the HTTP path: `/<index>/_doc/<id>`.
    ///
    /// The returned slice is allocated with `allocator` and must be freed by the caller.
    pub fn httpPath(self: GetDocRequest, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_doc/{s}", .{ self.index, self.id });
    }

    /// Get requests have no body — always returns `null`.
    pub fn httpBody(_: GetDocRequest, _: Allocator) !?[]u8 {
        return null;
    }
};

/// Request to delete a document by ID from Elasticsearch.
pub const DeleteDocRequest = struct {
    /// Target index name.
    index: []const u8,
    /// Document ID to delete.
    id: []const u8,

    /// Returns the HTTP method (`"DELETE"`).
    pub fn httpMethod(_: DeleteDocRequest) []const u8 {
        return "DELETE";
    }

    /// Returns the HTTP path: `/<index>/_doc/<id>`.
    ///
    /// The returned slice is allocated with `allocator` and must be freed by the caller.
    pub fn httpPath(self: DeleteDocRequest, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_doc/{s}", .{ self.index, self.id });
    }

    /// Delete requests have no body — always returns `null`.
    pub fn httpBody(_: DeleteDocRequest, _: Allocator) !?[]u8 {
        return null;
    }
};

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Response from a get-document request, generic over the `_source` document type.
///
/// Elasticsearch returns a JSON envelope containing index metadata alongside
/// the `_source` document body. `T` determines the struct that `_source` is
/// deserialized into.
pub fn GetDocResponse(comptime T: type) type {
    return struct {
        /// Index the document was retrieved from.
        _index: ?[]const u8 = null,
        /// Document ID.
        _id: ?[]const u8 = null,
        /// Document version (monotonically increasing on updates).
        _version: ?u64 = null,
        /// Whether the document was found.
        found: bool = false,
        /// The document body, present only when `found` is `true`.
        _source: ?T = null,
    };
}

/// Response from an index-document request.
pub const IndexDocResponse = struct {
    /// Index the document was written to.
    _index: ?[]const u8 = null,
    /// Assigned document ID (auto-generated when not specified in the request).
    _id: ?[]const u8 = null,
    /// Document version after the write.
    _version: ?u64 = null,
    /// Write result — `"created"` for new documents, `"updated"` for existing ones.
    result: ?[]const u8 = null,
};

/// Response from a delete-document request.
pub const DeleteDocResponse = struct {
    /// Index the document was deleted from.
    _index: ?[]const u8 = null,
    /// Document ID that was deleted.
    _id: ?[]const u8 = null,
    /// Document version after the delete.
    _version: ?u64 = null,
    /// Delete result — `"deleted"` on success, `"not_found"` when absent.
    result: ?[]const u8 = null,
};

// ===========================================================================
// Tests
// ===========================================================================

test "IndexDocRequest.httpMethod — PUT with ID, POST without" {
    const with_id = IndexDocRequest{
        .index = "concepts",
        .id = "123",
        .body = "{}",
    };
    try std.testing.expectEqualStrings("PUT", with_id.httpMethod());

    const without_id = IndexDocRequest{
        .index = "concepts",
        .body = "{}",
    };
    try std.testing.expectEqualStrings("POST", without_id.httpMethod());
}

test "IndexDocRequest.httpPath — with and without ID" {
    const allocator = std.testing.allocator;

    // With ID
    {
        const req = IndexDocRequest{
            .index = "concepts",
            .id = "abc-123",
            .body = "{}",
        };
        const path = try req.httpPath(allocator);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("/concepts/_doc/abc-123", path);
    }

    // Without ID
    {
        const req = IndexDocRequest{
            .index = "concepts",
            .body = "{}",
        };
        const path = try req.httpPath(allocator);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("/concepts/_doc", path);
    }
}

test "IndexDocRequest.httpBody — returns duped body" {
    const allocator = std.testing.allocator;

    const original_body = "{\"id\":1,\"active\":true}";
    const req = IndexDocRequest{
        .index = "concepts",
        .id = "1",
        .body = original_body,
    };

    const body = (try req.httpBody(allocator)).?;
    defer allocator.free(body);

    try std.testing.expectEqualStrings(original_body, body);
    // Must be a distinct allocation, not the same pointer.
    try std.testing.expect(body.ptr != original_body.ptr);
}

test "GetDocRequest.httpMethod — always GET" {
    const req = GetDocRequest{ .index = "concepts", .id = "1" };
    try std.testing.expectEqualStrings("GET", req.httpMethod());
}

test "GetDocRequest.httpPath — correct path" {
    const allocator = std.testing.allocator;
    const req = GetDocRequest{ .index = "my-index", .id = "doc-42" };

    const path = try req.httpPath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/my-index/_doc/doc-42", path);
}

test "GetDocRequest.httpBody — always null" {
    const allocator = std.testing.allocator;
    const req = GetDocRequest{ .index = "idx", .id = "1" };

    const body = try req.httpBody(allocator);
    try std.testing.expect(body == null);
}

test "DeleteDocRequest.httpMethod — always DELETE" {
    const req = DeleteDocRequest{ .index = "concepts", .id = "1" };
    try std.testing.expectEqualStrings("DELETE", req.httpMethod());
}

test "DeleteDocRequest.httpPath — correct path" {
    const allocator = std.testing.allocator;
    const req = DeleteDocRequest{ .index = "my-index", .id = "doc-99" };

    const path = try req.httpPath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/my-index/_doc/doc-99", path);
}

test "DeleteDocRequest.httpBody — always null" {
    const allocator = std.testing.allocator;
    const req = DeleteDocRequest{ .index = "idx", .id = "1" };

    const body = try req.httpBody(allocator);
    try std.testing.expect(body == null);
}

test "GetDocResponse deserialization — found document" {
    const TestDoc = struct {
        id: u64,
        active: bool,
        name: []const u8,
    };

    const json =
        \\{"_index":"test","_id":"1","_version":1,"found":true,"_source":{"id":1,"active":true,"name":"test"}}
    ;

    var parsed = try deserialize.fromJson(GetDocResponse(TestDoc), std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", parsed.value._index.?);
    try std.testing.expectEqualStrings("1", parsed.value._id.?);
    try std.testing.expectEqual(@as(u64, 1), parsed.value._version.?);
    try std.testing.expect(parsed.value.found);
    try std.testing.expectEqual(@as(u64, 1), parsed.value._source.?.id);
    try std.testing.expect(parsed.value._source.?.active);
    try std.testing.expectEqualStrings("test", parsed.value._source.?.name);
}

test "GetDocResponse deserialization — not found" {
    const TestDoc = struct {
        id: u64,
    };

    const json =
        \\{"_index":"test","_id":"999","found":false}
    ;

    var parsed = try deserialize.fromJson(GetDocResponse(TestDoc), std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", parsed.value._index.?);
    try std.testing.expectEqualStrings("999", parsed.value._id.?);
    try std.testing.expect(!parsed.value.found);
    try std.testing.expect(parsed.value._source == null);
    try std.testing.expect(parsed.value._version == null);
}

test "GetDocResponse deserialization — u64 SNOMED concept IDs" {
    const Concept = struct {
        id: u64,
        module_id: u64,
        active: bool,
    };

    const json =
        \\{"_index":"snomedct","_id":"404684003","_version":2,"found":true,"_source":{"id":404684003,"module_id":900000000000207008,"active":true}}
    ;

    var parsed = try deserialize.fromJson(GetDocResponse(Concept), std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 404684003), parsed.value._source.?.id);
    try std.testing.expectEqual(@as(u64, 900000000000207008), parsed.value._source.?.module_id);
    try std.testing.expect(parsed.value._source.?.active);
}

test "IndexDocResponse deserialization — created" {
    const json =
        \\{"_index":"concepts","_id":"1","_version":1,"result":"created","_shards":{"total":2,"successful":1,"failed":0},"_seq_no":0,"_primary_term":1}
    ;

    var parsed = try deserialize.fromJson(IndexDocResponse, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("concepts", parsed.value._index.?);
    try std.testing.expectEqualStrings("1", parsed.value._id.?);
    try std.testing.expectEqual(@as(u64, 1), parsed.value._version.?);
    try std.testing.expectEqualStrings("created", parsed.value.result.?);
}

test "IndexDocResponse deserialization — updated" {
    const json =
        \\{"_index":"concepts","_id":"1","_version":2,"result":"updated"}
    ;

    var parsed = try deserialize.fromJson(IndexDocResponse, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("1", parsed.value._id.?);
    try std.testing.expectEqual(@as(u64, 2), parsed.value._version.?);
    try std.testing.expectEqualStrings("updated", parsed.value.result.?);
}

test "DeleteDocResponse deserialization — deleted" {
    const json =
        \\{"_index":"concepts","_id":"42","_version":3,"result":"deleted"}
    ;

    var parsed = try deserialize.fromJson(DeleteDocResponse, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("concepts", parsed.value._index.?);
    try std.testing.expectEqualStrings("42", parsed.value._id.?);
    try std.testing.expectEqual(@as(u64, 3), parsed.value._version.?);
    try std.testing.expectEqualStrings("deleted", parsed.value.result.?);
}

test "DeleteDocResponse deserialization — not_found" {
    const json =
        \\{"_index":"concepts","_id":"999","_version":1,"result":"not_found"}
    ;

    var parsed = try deserialize.fromJson(DeleteDocResponse, std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("999", parsed.value._id.?);
    try std.testing.expectEqualStrings("not_found", parsed.value.result.?);
}
