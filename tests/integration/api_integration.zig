//! Integration tests for the Elasticsearch API operations (M4).
//!
//! These tests run against a real Elasticsearch/OpenSearch instance.
//! They require the ES_URL environment variable to be set (e.g.
//! `ES_URL=http://localhost:9200`). Tests are skipped automatically
//! if ES_URL is not set.
//!
//! Each test creates a unique index, performs operations, asserts on
//! results, and deletes the index.
//!
//! Run with: zig build test-integration

const std = @import("std");
const elaztic = @import("elaztic");
const Query = elaztic.query.Query;

// ---------------------------------------------------------------------------
// Test document type
// ---------------------------------------------------------------------------

const Concept = struct {
    id: u64,
    active: bool,
    module_id: u64,
    term: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract host string from a parsed URI host component.
fn hostFromUri(uri: std.Uri) []const u8 {
    if (uri.host) |h| {
        return switch (h) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };
    }
    return "localhost";
}

/// Generate a unique index name using random hex characters.
fn generateIndexName(buf: []u8) []const u8 {
    const prefix = "test-elaztic-";
    @memcpy(buf[0..prefix.len], prefix);

    const hex_chars = "0123456789abcdef";
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var pos: usize = prefix.len;
    for (random_bytes) |b| {
        if (pos + 2 > buf.len) break;
        buf[pos] = hex_chars[b >> 4];
        buf[pos + 1] = hex_chars[b & 0x0f];
        pos += 2;
    }
    return buf[0..pos];
}

/// Parse ES_URL and return a base URL string, or null if not set.
fn getBaseUrl(allocator: std.mem.Allocator, out_buf: []u8) ?struct { base_url: []const u8, es_url_owned: []const u8 } {
    const es_url = std.process.getEnvVarOwned(allocator, "ES_URL") catch {
        std.debug.print("SKIP: ES_URL not set\n", .{});
        return null;
    };

    const uri = std.Uri.parse(es_url) catch {
        std.debug.print("SKIP: ES_URL is not a valid URI\n", .{});
        allocator.free(es_url);
        return null;
    };

    const host_str = hostFromUri(uri);
    const port: u16 = uri.port orelse 9200;

    var fbs = std.io.fixedBufferStream(out_buf);
    fbs.writer().print("http://{s}:{d}", .{ host_str, port }) catch {
        allocator.free(es_url);
        return null;
    };

    return .{
        .base_url = fbs.getWritten(),
        .es_url_owned = es_url,
    };
}

/// Perform a GET request. Returns status code and response body (caller owns body).
fn httpGet(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) !struct { status: u16, body: []const u8 } {
    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var hdr_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&hdr_buf);

    var xfer_buf: [16384]u8 = undefined;
    const resp_body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);

    return .{
        .status = @intFromEnum(response.head.status),
        .body = resp_body,
    };
}

/// Perform a PUT request with a JSON body. Returns the HTTP status code.
fn httpPut(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, body: []const u8) !u16 {
    const uri = try std.Uri.parse(url);

    var req = try client.request(.PUT, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    try req.sendBodyComplete(@constCast(body));

    var hdr_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&hdr_buf);

    var xfer_buf: [8192]u8 = undefined;
    const resp_body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);
    defer allocator.free(resp_body);

    return @intFromEnum(response.head.status);
}

/// Perform a PUT request with a JSON body. Returns status code and response body (caller owns body).
fn httpPutWithBody(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, body: []const u8) !struct { status: u16, body: []const u8 } {
    const uri = try std.Uri.parse(url);

    var req = try client.request(.PUT, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    try req.sendBodyComplete(@constCast(body));

    var hdr_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&hdr_buf);

    var xfer_buf: [16384]u8 = undefined;
    const resp_body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);

    return .{
        .status = @intFromEnum(response.head.status),
        .body = resp_body,
    };
}

/// Perform a POST request with a JSON body. Returns the response body (caller owns).
fn httpPost(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, body: []const u8) !struct { status: u16, body: []const u8 } {
    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    try req.sendBodyComplete(@constCast(body));

    var hdr_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&hdr_buf);

    var xfer_buf: [16384]u8 = undefined;
    const resp_body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);

    return .{
        .status = @intFromEnum(response.head.status),
        .body = resp_body,
    };
}

/// Perform a DELETE request. Returns the HTTP status code.
fn httpDelete(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) !u16 {
    const uri = try std.Uri.parse(url);

    var req = try client.request(.DELETE, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var hdr_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&hdr_buf);

    var xfer_buf: [8192]u8 = undefined;
    const resp_body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);
    defer allocator.free(resp_body);

    return @intFromEnum(response.head.status);
}

/// Index a single document via PUT /{index}/_doc/{id}.
fn indexDoc(allocator: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, index_name: []const u8, doc_id: []const u8, doc_json: []const u8) !void {
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}/_doc/{s}", .{ base_url, index_name, doc_id });
    const url = url_fbs.getWritten();

    const status = try httpPut(allocator, client, url, doc_json);
    if (status >= 300) {
        std.debug.print("  INDEX doc {s} failed with status {d}\n", .{ doc_id, status });
        return error.TestUnexpectedResult;
    }
}

/// Refresh an index so that indexed documents become searchable.
fn refreshIndex(allocator: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, index_name: []const u8) !void {
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}/_refresh", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    const result = try httpPost(allocator, client, url, "");
    defer allocator.free(result.body);

    if (result.status != 200) {
        std.debug.print("  REFRESH failed with status {d}\n", .{result.status});
        return error.TestUnexpectedResult;
    }
}

/// Create an index with explicit mappings for Concept fields.
fn createIndex(allocator: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, index_name: []const u8) !void {
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    // Create with explicit mappings so that id and module_id are long (u64),
    // active is boolean, and term is keyword (for exact match / exists).
    const mapping_body =
        \\{
        \\  "settings": {
        \\    "number_of_shards": 1,
        \\    "number_of_replicas": 0
        \\  },
        \\  "mappings": {
        \\    "properties": {
        \\      "id":        { "type": "long" },
        \\      "active":    { "type": "boolean" },
        \\      "module_id": { "type": "long" },
        \\      "term":      { "type": "keyword" }
        \\    }
        \\  }
        \\}
    ;

    const status = try httpPut(allocator, client, url, mapping_body);
    if (status >= 300) {
        std.debug.print("  CREATE INDEX failed with status {d}\n", .{status});
        return error.TestUnexpectedResult;
    }
}

/// Create an index with custom body (settings + mappings).
fn createIndexWithBody(allocator: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, index_name: []const u8, body: []const u8) !void {
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    const status = try httpPut(allocator, client, url, body);
    if (status >= 300) {
        std.debug.print("  CREATE INDEX failed with status {d}\n", .{status});
        return error.TestUnexpectedResult;
    }
}

/// Delete an index via DELETE /{index}.
fn deleteIndex(allocator: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, index_name: []const u8) void {
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    url_fbs.writer().print("{s}/{s}", .{ base_url, index_name }) catch return;
    const url = url_fbs.getWritten();

    const status = httpDelete(allocator, client, url) catch |err| {
        std.debug.print("  DELETE INDEX failed: {}\n", .{err});
        return;
    };
    std.debug.print("  DELETE INDEX status: {d}\n", .{status});
}

/// Execute a search query against an index and return the raw response body.
fn executeSearch(allocator: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, index_name: []const u8, query_json: []const u8) ![]const u8 {
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}/_search", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    // Wrap the query in a search body: {"query": ..., "size": 10}
    var search_body_buf: [4096]u8 = undefined;
    var search_fbs = std.io.fixedBufferStream(&search_body_buf);
    try search_fbs.writer().print("{{\"query\":{s},\"size\":10}}", .{query_json});
    const search_body_str = search_fbs.getWritten();

    const result = try httpPost(allocator, client, url, search_body_str);

    if (result.status != 200) {
        std.debug.print("  SEARCH failed with status {d}\n  body: {s}\n", .{ result.status, result.body });
        allocator.free(result.body);
        return error.TestUnexpectedResult;
    }

    return result.body;
}

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

const doc1 = Concept{
    .id = 404684003,
    .active = true,
    .module_id = 900000000000207008,
    .term = "Clinical finding",
};

const doc2 = Concept{
    .id = 138875005,
    .active = true,
    .module_id = 900000000000207008,
    .term = "SNOMED CT Concept",
};

const doc3 = Concept{
    .id = 900000000000441003,
    .active = false,
    .module_id = 900000000000012004,
    .term = null,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "integration_create_delete_index" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_create_delete_index] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Create index with settings (1 shard, 0 replicas)
    const create_body =
        \\{
        \\  "settings": {
        \\    "number_of_shards": 1,
        \\    "number_of_replicas": 0
        \\  }
        \\}
    ;
    try createIndexWithBody(allocator, &client, base_url, index_name, create_body);

    // Verify index exists via GET /{index}
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const get_result = try httpGet(allocator, &client, url);
        defer allocator.free(get_result.body);

        std.debug.print("  GET index status: {d}\n", .{get_result.status});
        try std.testing.expectEqual(@as(u16, 200), get_result.status);
    }

    // Delete the index
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const del_status = try httpDelete(allocator, &client, url);
        std.debug.print("  DELETE index status: {d}\n", .{del_status});
        try std.testing.expectEqual(@as(u16, 200), del_status);
    }

    // Verify index is gone — GET should return 404
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const get_result = try httpGet(allocator, &client, url);
        defer allocator.free(get_result.body);

        std.debug.print("  GET deleted index status: {d}\n", .{get_result.status});
        try std.testing.expectEqual(@as(u16, 404), get_result.status);
    }
}

test "integration_index_get_doc" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_index_get_doc] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // Index doc1 with ID "1"
    const json1 = try elaztic.serialize.toJson(allocator, doc1);
    defer allocator.free(json1);
    try indexDoc(allocator, &client, base_url, index_name, "1", json1);

    // Refresh to make it retrievable
    try refreshIndex(allocator, &client, base_url, index_name);

    // GET /{index}/_doc/1
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}/_doc/1", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    const get_result = try httpGet(allocator, &client, url);
    defer allocator.free(get_result.body);

    std.debug.print("  GET doc status: {d}\n", .{get_result.status});
    try std.testing.expectEqual(@as(u16, 200), get_result.status);

    // Parse response as GetDocResponse(Concept)
    var parsed = try elaztic.deserialize.fromJson(
        elaztic.GetDocResponse(Concept),
        allocator,
        get_result.body,
    );
    defer parsed.deinit();

    // Verify fields
    try std.testing.expect(parsed.value.found);
    try std.testing.expectEqualStrings("1", parsed.value._id orelse return error.TestUnexpectedResult);

    const source = parsed.value._source orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(doc1.id, source.id);
    try std.testing.expectEqual(doc1.active, source.active);
    try std.testing.expectEqual(doc1.module_id, source.module_id);
    try std.testing.expectEqualStrings("Clinical finding", source.term orelse return error.TestUnexpectedResult);
}

test "integration_delete_doc" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_delete_doc] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // Index a document
    const json1 = try elaztic.serialize.toJson(allocator, doc1);
    defer allocator.free(json1);
    try indexDoc(allocator, &client, base_url, index_name, "1", json1);

    try refreshIndex(allocator, &client, base_url, index_name);

    // Verify document exists
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_doc/1", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const get_result = try httpGet(allocator, &client, url);
        defer allocator.free(get_result.body);

        try std.testing.expectEqual(@as(u16, 200), get_result.status);
    }

    // Delete the document via DELETE /{index}/_doc/1
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_doc/1", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const del_status = try httpDelete(allocator, &client, url);
        std.debug.print("  DELETE doc status: {d}\n", .{del_status});
        try std.testing.expectEqual(@as(u16, 200), del_status);
    }

    // Try to GET the deleted document — should return found: false or 404
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_doc/1", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const get_result = try httpGet(allocator, &client, url);
        defer allocator.free(get_result.body);

        std.debug.print("  GET deleted doc status: {d}\n", .{get_result.status});

        // ES returns 404 for deleted docs. Parse the body to confirm found: false.
        var parsed = try elaztic.deserialize.fromJson(
            elaztic.GetDocResponse(Concept),
            allocator,
            get_result.body,
        );
        defer parsed.deinit();

        try std.testing.expect(!parsed.value.found);
    }
}

test "integration_search_with_query" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_search_with_query] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // Index 3 docs: 2 active, 1 inactive
    const json1 = try elaztic.serialize.toJson(allocator, doc1);
    defer allocator.free(json1);
    try indexDoc(allocator, &client, base_url, index_name, "1", json1);

    const json2 = try elaztic.serialize.toJson(allocator, doc2);
    defer allocator.free(json2);
    try indexDoc(allocator, &client, base_url, index_name, "2", json2);

    const json3 = try elaztic.serialize.toJson(allocator, doc3);
    defer allocator.free(json3);
    try indexDoc(allocator, &client, base_url, index_name, "3", json3);

    try refreshIndex(allocator, &client, base_url, index_name);

    // Build query: term(active, true) — should match doc1 and doc2
    const q = Query.term("active", true);
    const query_json = try q.toJson(allocator);
    defer allocator.free(query_json);

    const search_body = try executeSearch(allocator, &client, base_url, index_name, query_json);
    defer allocator.free(search_body);

    // Parse response
    var parsed = try elaztic.deserialize.fromJson(
        elaztic.deserialize.SearchResponse(Concept),
        allocator,
        search_body,
    );
    defer parsed.deinit();

    // Assert: 2 active docs
    std.debug.print("  hits: {d}\n", .{parsed.value.hits.hits.len});
    try std.testing.expectEqual(@as(usize, 2), parsed.value.hits.hits.len);
}

test "integration_count" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_count] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // Index 3 docs
    const json1 = try elaztic.serialize.toJson(allocator, doc1);
    defer allocator.free(json1);
    try indexDoc(allocator, &client, base_url, index_name, "1", json1);

    const json2 = try elaztic.serialize.toJson(allocator, doc2);
    defer allocator.free(json2);
    try indexDoc(allocator, &client, base_url, index_name, "2", json2);

    const json3 = try elaztic.serialize.toJson(allocator, doc3);
    defer allocator.free(json3);
    try indexDoc(allocator, &client, base_url, index_name, "3", json3);

    try refreshIndex(allocator, &client, base_url, index_name);

    // Count all documents (no query body)
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_count", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const count_result = try httpPost(allocator, &client, url, "");
        defer allocator.free(count_result.body);

        std.debug.print("  count all status: {d}\n", .{count_result.status});
        try std.testing.expectEqual(@as(u16, 200), count_result.status);

        // Parse response — expect {"count": 3, ...}
        const CountResponse = struct { count: u64 };
        var parsed = try elaztic.deserialize.fromJson(CountResponse, allocator, count_result.body);
        defer parsed.deinit();

        std.debug.print("  count all: {d}\n", .{parsed.value.count});
        try std.testing.expectEqual(@as(u64, 3), parsed.value.count);
    }

    // Count with a term query filter — only active docs
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_count", .{ base_url, index_name });
        const url = url_fbs.getWritten();

        const q = Query.term("active", true);
        const query_json = try q.toJson(allocator);
        defer allocator.free(query_json);

        var body_buf: [4096]u8 = undefined;
        var body_fbs = std.io.fixedBufferStream(&body_buf);
        try body_fbs.writer().print("{{\"query\":{s}}}", .{query_json});
        const body_str = body_fbs.getWritten();

        const count_result = try httpPost(allocator, &client, url, body_str);
        defer allocator.free(count_result.body);

        std.debug.print("  count filtered status: {d}\n", .{count_result.status});
        try std.testing.expectEqual(@as(u16, 200), count_result.status);

        const CountResponse = struct { count: u64 };
        var parsed = try elaztic.deserialize.fromJson(CountResponse, allocator, count_result.body);
        defer parsed.deinit();

        std.debug.print("  count filtered: {d}\n", .{parsed.value.count});
        try std.testing.expectEqual(@as(u64, 2), parsed.value.count);
    }
}

test "integration_refresh" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_refresh] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Create index with refresh_interval disabled so docs aren't auto-visible
    const create_body =
        \\{
        \\  "settings": {
        \\    "number_of_shards": 1,
        \\    "number_of_replicas": 0,
        \\    "refresh_interval": "-1"
        \\  },
        \\  "mappings": {
        \\    "properties": {
        \\      "id":        { "type": "long" },
        \\      "active":    { "type": "boolean" },
        \\      "module_id": { "type": "long" },
        \\      "term":      { "type": "keyword" }
        \\    }
        \\  }
        \\}
    ;
    try createIndexWithBody(allocator, &client, base_url, index_name, create_body);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // Index a document (no refresh)
    const json1 = try elaztic.serialize.toJson(allocator, doc1);
    defer allocator.free(json1);
    try indexDoc(allocator, &client, base_url, index_name, "1", json1);

    // Search immediately — should get 0 hits (not refreshed)
    {
        const q = Query.matchAll();
        const query_json = try q.toJson(allocator);
        defer allocator.free(query_json);

        const search_body = try executeSearch(allocator, &client, base_url, index_name, query_json);
        defer allocator.free(search_body);

        var parsed = try elaztic.deserialize.fromJson(
            elaztic.deserialize.SearchResponse(Concept),
            allocator,
            search_body,
        );
        defer parsed.deinit();

        std.debug.print("  hits before refresh: {d}\n", .{parsed.value.hits.hits.len});
        try std.testing.expectEqual(@as(usize, 0), parsed.value.hits.hits.len);
    }

    // Now refresh
    try refreshIndex(allocator, &client, base_url, index_name);

    // Search again — should now get 1 hit
    {
        const q = Query.matchAll();
        const query_json = try q.toJson(allocator);
        defer allocator.free(query_json);

        const search_body = try executeSearch(allocator, &client, base_url, index_name, query_json);
        defer allocator.free(search_body);

        var parsed = try elaztic.deserialize.fromJson(
            elaztic.deserialize.SearchResponse(Concept),
            allocator,
            search_body,
        );
        defer parsed.deinit();

        std.debug.print("  hits after refresh: {d}\n", .{parsed.value.hits.hits.len});
        try std.testing.expectEqual(@as(usize, 1), parsed.value.hits.hits.len);
    }
}

test "integration_put_mapping" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_put_mapping] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // PUT /{index}/_mapping with a new field
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}/_mapping", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    const mapping_body =
        \\{"properties":{"new_field":{"type":"keyword"}}}
    ;

    const status = try httpPut(allocator, &client, url, mapping_body);
    std.debug.print("  PUT mapping status: {d}\n", .{status});
    try std.testing.expectEqual(@as(u16, 200), status);

    // Verify mapping was applied by GET /{index}/_mapping
    {
        var get_url_buf: [512]u8 = undefined;
        var get_url_fbs = std.io.fixedBufferStream(&get_url_buf);
        try get_url_fbs.writer().print("{s}/{s}/_mapping", .{ base_url, index_name });
        const get_url = get_url_fbs.getWritten();

        const get_result = try httpGet(allocator, &client, get_url);
        defer allocator.free(get_result.body);

        std.debug.print("  GET mapping status: {d}\n", .{get_result.status});
        try std.testing.expectEqual(@as(u16, 200), get_result.status);

        // The response should contain "new_field" somewhere in the mapping
        try std.testing.expect(std.mem.indexOf(u8, get_result.body, "new_field") != null);
    }
}

test "integration_put_alias" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_put_alias] index: {s}\n", .{index_name});

    // Generate a unique alias name to avoid conflicts with other tests
    var alias_buf: [64]u8 = undefined;
    const alias_prefix = "alias-";
    @memcpy(alias_buf[0..alias_prefix.len], alias_prefix);

    const hex_chars = "0123456789abcdef";
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var alias_pos: usize = alias_prefix.len;
    for (random_bytes) |b| {
        if (alias_pos + 2 > alias_buf.len) break;
        alias_buf[alias_pos] = hex_chars[b >> 4];
        alias_buf[alias_pos + 1] = hex_chars[b & 0x0f];
        alias_pos += 2;
    }
    const alias_name = alias_buf[0..alias_pos];
    std.debug.print("  alias: {s}\n", .{alias_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // Index a document so we can search for it via alias
    const json1 = try elaztic.serialize.toJson(allocator, doc1);
    defer allocator.free(json1);
    try indexDoc(allocator, &client, base_url, index_name, "1", json1);
    try refreshIndex(allocator, &client, base_url, index_name);

    // PUT /{index}/_alias/{alias_name}
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_alias/{s}", .{ base_url, index_name, alias_name });
        const url = url_fbs.getWritten();

        const status = try httpPut(allocator, &client, url, "{}");
        std.debug.print("  PUT alias status: {d}\n", .{status});
        try std.testing.expectEqual(@as(u16, 200), status);
    }

    // Search via alias — POST /{alias}/_search
    {
        const q = Query.matchAll();
        const query_json = try q.toJson(allocator);
        defer allocator.free(query_json);

        const search_body = try executeSearch(allocator, &client, base_url, alias_name, query_json);
        defer allocator.free(search_body);

        var parsed = try elaztic.deserialize.fromJson(
            elaztic.deserialize.SearchResponse(Concept),
            allocator,
            search_body,
        );
        defer parsed.deinit();

        std.debug.print("  hits via alias: {d}\n", .{parsed.value.hits.hits.len});
        try std.testing.expectEqual(@as(usize, 1), parsed.value.hits.hits.len);
    }
}

test "integration_index_without_id" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_index_without_id] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // POST /{index}/_doc (no ID in path) — ES should auto-generate an ID
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}/_doc", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    const json1 = try elaztic.serialize.toJson(allocator, doc1);
    defer allocator.free(json1);

    const post_result = try httpPost(allocator, &client, url, json1);
    defer allocator.free(post_result.body);

    std.debug.print("  POST doc status: {d}\n", .{post_result.status});
    try std.testing.expectEqual(@as(u16, 201), post_result.status);

    // Parse the response to verify auto-generated _id
    const IndexResponse = struct {
        _index: ?[]const u8 = null,
        _id: ?[]const u8 = null,
        result: ?[]const u8 = null,
    };

    var parsed = try elaztic.deserialize.fromJson(IndexResponse, allocator, post_result.body);
    defer parsed.deinit();

    // _id should be non-null and non-empty (auto-generated)
    const auto_id = parsed.value._id orelse {
        std.debug.print("  ERROR: _id is null in response\n", .{});
        return error.TestUnexpectedResult;
    };
    std.debug.print("  auto-generated _id: {s}\n", .{auto_id});
    try std.testing.expect(auto_id.len > 0);

    // result should be "created"
    const res_str = parsed.value.result orelse {
        std.debug.print("  ERROR: result is null in response\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings("created", res_str);
}

test "integration_error_index_not_found" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    std.debug.print("\n  [integration_error_index_not_found]\n", .{});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // POST /nonexistent-index-xyz/_search — should get 404
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/nonexistent-index-xyz/_search", .{base_url});
    const url = url_fbs.getWritten();

    const search_body =
        \\{"query":{"match_all":{}}}
    ;

    const post_result = try httpPost(allocator, &client, url, search_body);
    defer allocator.free(post_result.body);

    std.debug.print("  search nonexistent index status: {d}\n", .{post_result.status});
    try std.testing.expectEqual(@as(u16, 404), post_result.status);
}
