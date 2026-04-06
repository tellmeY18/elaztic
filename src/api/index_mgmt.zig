//! Index management request and response types for Elasticsearch.
//!
//! Provides request structs for creating, deleting, refreshing indices,
//! updating mappings, and managing aliases. Each request type exposes a
//! uniform interface via `httpMethod()`, `httpPath()`, and `httpBody()`
//! so that the client can dispatch them generically.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Settings for index creation.
///
/// Controls the number of primary and replica shards. When a field is `null`,
/// Elasticsearch uses its own defaults.
pub const IndexSettings = struct {
    /// Number of primary shards (default: ES decides).
    number_of_shards: ?u32 = null,
    /// Number of replica shards (default: ES decides).
    number_of_replicas: ?u32 = null,
};

/// Request to create an Elasticsearch index.
///
/// Supports optional index settings (shard counts) and optional mappings
/// provided as raw JSON bytes. When neither is set, the request body is
/// omitted entirely and Elasticsearch applies its defaults.
pub const CreateIndexRequest = struct {
    /// Index name.
    index: []const u8,
    /// Optional index settings.
    settings: ?IndexSettings = null,
    /// Optional mappings JSON body (raw JSON bytes, must be a valid JSON object).
    mappings: ?[]const u8 = null,

    /// Returns the HTTP method for this request.
    pub fn httpMethod(_: CreateIndexRequest) []const u8 {
        return "PUT";
    }

    /// Returns the HTTP path (e.g. `"/my-index"`).
    ///
    /// The returned slice is owned by the caller and must be freed with `allocator`.
    pub fn httpPath(self: CreateIndexRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}", .{self.index});
    }

    /// Returns the request body JSON, or `null` if no settings or mappings are set.
    ///
    /// When non-null, the returned slice is owned by the caller and must be freed
    /// with `allocator`.
    pub fn httpBody(self: CreateIndexRequest, allocator: Allocator) !?[]u8 {
        if (self.settings == null and self.mappings == null) return null;

        var list: std.ArrayListUnmanaged(u8) = .{};
        errdefer list.deinit(allocator);
        const writer = list.writer(allocator);

        try writer.writeByte('{');
        var needs_comma = false;

        if (self.settings) |s| {
            try writer.writeAll("\"settings\":{");
            var inner_needs_comma = false;

            if (s.number_of_shards) |v| {
                try std.fmt.format(writer, "\"number_of_shards\":{d}", .{v});
                inner_needs_comma = true;
            }

            if (s.number_of_replicas) |v| {
                if (inner_needs_comma) try writer.writeByte(',');
                try std.fmt.format(writer, "\"number_of_replicas\":{d}", .{v});
            }

            try writer.writeByte('}');
            needs_comma = true;
        }

        if (self.mappings) |m| {
            if (needs_comma) try writer.writeByte(',');
            try writer.writeAll("\"mappings\":");
            try writer.writeAll(m);
        }

        try writer.writeByte('}');
        return try list.toOwnedSlice(allocator);
    }
};

/// Request to delete an Elasticsearch index.
pub const DeleteIndexRequest = struct {
    /// Index name.
    index: []const u8,

    /// Returns the HTTP method for this request.
    pub fn httpMethod(_: DeleteIndexRequest) []const u8 {
        return "DELETE";
    }

    /// Returns the HTTP path (e.g. `"/my-index"`).
    ///
    /// The returned slice is owned by the caller and must be freed with `allocator`.
    pub fn httpPath(self: DeleteIndexRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}", .{self.index});
    }

    /// Returns the request body. Always `null` for delete requests.
    pub fn httpBody(_: DeleteIndexRequest, _: Allocator) !?[]u8 {
        return null;
    }
};

/// Request to refresh an Elasticsearch index, making recent changes searchable.
///
/// After indexing documents, they are not immediately searchable. A refresh
/// makes all operations performed since the last refresh available for search.
pub const RefreshRequest = struct {
    /// Index name, or `"_all"` to refresh all indices.
    index: []const u8,

    /// Returns the HTTP method for this request.
    pub fn httpMethod(_: RefreshRequest) []const u8 {
        return "POST";
    }

    /// Returns the HTTP path (e.g. `"/my-index/_refresh"`).
    ///
    /// The returned slice is owned by the caller and must be freed with `allocator`.
    pub fn httpPath(self: RefreshRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_refresh", .{self.index});
    }

    /// Returns the request body. Always `null` for refresh requests.
    pub fn httpBody(_: RefreshRequest, _: Allocator) !?[]u8 {
        return null;
    }
};

/// Request to update mappings on an existing index.
///
/// The body must be a valid JSON object describing the mapping properties
/// to add. Elasticsearch does not allow removing or changing the type of
/// existing mapped fields — only new fields can be added.
pub const PutMappingRequest = struct {
    /// Index name.
    index: []const u8,
    /// Mapping body as raw JSON bytes.
    body: []const u8,

    /// Returns the HTTP method for this request.
    pub fn httpMethod(_: PutMappingRequest) []const u8 {
        return "PUT";
    }

    /// Returns the HTTP path (e.g. `"/my-index/_mapping"`).
    ///
    /// The returned slice is owned by the caller and must be freed with `allocator`.
    pub fn httpPath(self: PutMappingRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_mapping", .{self.index});
    }

    /// Returns a caller-owned copy of the mapping body.
    ///
    /// The returned slice must be freed with `allocator`.
    pub fn httpBody(self: PutMappingRequest, allocator: Allocator) Allocator.Error!?[]u8 {
        return try allocator.dupe(u8, self.body);
    }
};

/// Request to add an alias for an index.
///
/// Aliases allow referencing one or more indices by an alternative name,
/// which is useful for zero-downtime reindexing and multi-index queries.
pub const PutAliasRequest = struct {
    /// Index name.
    index: []const u8,
    /// Alias name.
    alias: []const u8,

    /// Returns the HTTP method for this request.
    pub fn httpMethod(_: PutAliasRequest) []const u8 {
        return "PUT";
    }

    /// Returns the HTTP path (e.g. `"/my-index/_alias/my-alias"`).
    ///
    /// The returned slice is owned by the caller and must be freed with `allocator`.
    pub fn httpPath(self: PutAliasRequest, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "/{s}/_alias/{s}", .{ self.index, self.alias });
    }

    /// Returns the request body. Always `null` for alias requests.
    pub fn httpBody(_: PutAliasRequest, _: Allocator) !?[]u8 {
        return null;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "CreateIndexRequest — httpMethod returns PUT" {
    const req = CreateIndexRequest{ .index = "test-index" };
    try std.testing.expectEqualStrings("PUT", req.httpMethod());
}

test "CreateIndexRequest — httpPath" {
    const req = CreateIndexRequest{ .index = "my-index" };
    const path = try req.httpPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/my-index", path);
}

test "CreateIndexRequest — httpBody returns null when no settings or mappings" {
    const req = CreateIndexRequest{ .index = "test-index" };
    const body = try req.httpBody(std.testing.allocator);
    try std.testing.expect(body == null);
}

test "CreateIndexRequest — httpBody with settings only (shards)" {
    const req = CreateIndexRequest{
        .index = "test-index",
        .settings = .{ .number_of_shards = 3 },
    };
    const body = (try req.httpBody(std.testing.allocator)).?;
    defer std.testing.allocator.free(body);

    // Parse back to verify structure.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const settings = obj.get("settings").?.object;
    try std.testing.expectEqual(@as(i64, 3), settings.get("number_of_shards").?.integer);
    try std.testing.expect(settings.get("number_of_replicas") == null);
    try std.testing.expect(obj.get("mappings") == null);
}

test "CreateIndexRequest — httpBody with settings only (replicas)" {
    const req = CreateIndexRequest{
        .index = "test-index",
        .settings = .{ .number_of_replicas = 0 },
    };
    const body = (try req.httpBody(std.testing.allocator)).?;
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const settings = parsed.value.object.get("settings").?.object;

    try std.testing.expectEqual(@as(i64, 0), settings.get("number_of_replicas").?.integer);
    try std.testing.expect(settings.get("number_of_shards") == null);
}

test "CreateIndexRequest — httpBody with settings (both shards and replicas)" {
    const req = CreateIndexRequest{
        .index = "test-index",
        .settings = .{ .number_of_shards = 1, .number_of_replicas = 2 },
    };
    const body = (try req.httpBody(std.testing.allocator)).?;
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const settings = parsed.value.object.get("settings").?.object;

    try std.testing.expectEqual(@as(i64, 1), settings.get("number_of_shards").?.integer);
    try std.testing.expectEqual(@as(i64, 2), settings.get("number_of_replicas").?.integer);
}

test "CreateIndexRequest — httpBody with mappings only" {
    const mappings_json =
        \\{"properties":{"title":{"type":"text"},"id":{"type":"long"}}}
    ;
    const req = CreateIndexRequest{
        .index = "test-index",
        .mappings = mappings_json,
    };
    const body = (try req.httpBody(std.testing.allocator)).?;
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expect(obj.get("settings") == null);

    const mappings = obj.get("mappings").?.object;
    const props = mappings.get("properties").?.object;
    try std.testing.expectEqualStrings("text", props.get("title").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("long", props.get("id").?.object.get("type").?.string);
}

test "CreateIndexRequest — httpBody with both settings and mappings" {
    const mappings_json =
        \\{"properties":{"name":{"type":"keyword"}}}
    ;
    const req = CreateIndexRequest{
        .index = "test-index",
        .settings = .{ .number_of_shards = 1, .number_of_replicas = 0 },
        .mappings = mappings_json,
    };
    const body = (try req.httpBody(std.testing.allocator)).?;
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // Settings present.
    const settings = obj.get("settings").?.object;
    try std.testing.expectEqual(@as(i64, 1), settings.get("number_of_shards").?.integer);
    try std.testing.expectEqual(@as(i64, 0), settings.get("number_of_replicas").?.integer);

    // Mappings present.
    const mappings = obj.get("mappings").?.object;
    const props = mappings.get("properties").?.object;
    try std.testing.expectEqualStrings("keyword", props.get("name").?.object.get("type").?.string);
}

test "DeleteIndexRequest — httpMethod returns DELETE" {
    const req = DeleteIndexRequest{ .index = "doomed-index" };
    try std.testing.expectEqualStrings("DELETE", req.httpMethod());
}

test "DeleteIndexRequest — httpPath" {
    const req = DeleteIndexRequest{ .index = "doomed-index" };
    const path = try req.httpPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/doomed-index", path);
}

test "DeleteIndexRequest — httpBody returns null" {
    const req = DeleteIndexRequest{ .index = "doomed-index" };
    const body = try req.httpBody(std.testing.allocator);
    try std.testing.expect(body == null);
}

test "RefreshRequest — httpMethod returns POST" {
    const req = RefreshRequest{ .index = "my-index" };
    try std.testing.expectEqualStrings("POST", req.httpMethod());
}

test "RefreshRequest — httpPath with named index" {
    const req = RefreshRequest{ .index = "my-index" };
    const path = try req.httpPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/my-index/_refresh", path);
}

test "RefreshRequest — httpPath with _all" {
    const req = RefreshRequest{ .index = "_all" };
    const path = try req.httpPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/_all/_refresh", path);
}

test "RefreshRequest — httpBody returns null" {
    const req = RefreshRequest{ .index = "my-index" };
    const body = try req.httpBody(std.testing.allocator);
    try std.testing.expect(body == null);
}

test "PutMappingRequest — httpMethod returns PUT" {
    const req = PutMappingRequest{
        .index = "my-index",
        .body = "{}",
    };
    try std.testing.expectEqualStrings("PUT", req.httpMethod());
}

test "PutMappingRequest — httpPath" {
    const req = PutMappingRequest{
        .index = "concepts",
        .body = "{}",
    };
    const path = try req.httpPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/concepts/_mapping", path);
}

test "PutMappingRequest — httpBody returns duped body" {
    const mapping_json =
        \\{"properties":{"active":{"type":"boolean"}}}
    ;
    const req = PutMappingRequest{
        .index = "concepts",
        .body = mapping_json,
    };
    const body = (try req.httpBody(std.testing.allocator)).?;
    defer std.testing.allocator.free(body);

    // Body must be a copy, not the same pointer.
    try std.testing.expectEqualStrings(mapping_json, body);
    try std.testing.expect(body.ptr != mapping_json.ptr);
}

test "PutAliasRequest — httpMethod returns PUT" {
    const req = PutAliasRequest{
        .index = "concepts-v2",
        .alias = "concepts",
    };
    try std.testing.expectEqualStrings("PUT", req.httpMethod());
}

test "PutAliasRequest — httpPath" {
    const req = PutAliasRequest{
        .index = "concepts-v2",
        .alias = "concepts",
    };
    const path = try req.httpPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/concepts-v2/_alias/concepts", path);
}

test "PutAliasRequest — httpBody returns null" {
    const req = PutAliasRequest{
        .index = "concepts-v2",
        .alias = "concepts",
    };
    const body = try req.httpBody(std.testing.allocator);
    try std.testing.expect(body == null);
}
