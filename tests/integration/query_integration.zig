//! Integration tests for the Elasticsearch query DSL.
//!
//! These tests run against a real Elasticsearch/OpenSearch instance.
//! They require the ES_URL environment variable to be set (e.g.
//! `ES_URL=http://localhost:9200`). Tests are skipped automatically
//! if ES_URL is not set.
//!
//! Each test creates a unique index, indexes documents, refreshes,
//! runs a query, asserts on results, and deletes the index.
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

/// Create an index via PUT /{index}.
fn createIndex(allocator: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, index_name: []const u8) !void {
    var url_buf: [512]u8 = undefined;
    var url_fbs = std.io.fixedBufferStream(&url_buf);
    try url_fbs.writer().print("{s}/{s}", .{ base_url, index_name });
    const url = url_fbs.getWritten();

    // Create with explicit mappings so that id and module_id are long (u64),
    // active is boolean, and term is keyword (for exact match / exists).
    const mapping_body =
        \\{
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

test "integration_term_query" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_term_query] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Create index
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

    // Refresh
    try refreshIndex(allocator, &client, base_url, index_name);

    // Build query: term(active, true)
    const q = Query.term("active", true);
    const query_json = try q.toJson(allocator);
    defer allocator.free(query_json);

    // Execute search
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

test "integration_terms_query" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_terms_query] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

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

    // Build query: terms("id", [doc1.id, doc3.id])
    const target_ids = [_]u64{ doc1.id, doc3.id };
    const q = Query.terms("id", @as([]const u64, &target_ids));
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

    // Assert: 2 docs matching the IDs
    std.debug.print("  hits: {d}\n", .{parsed.value.hits.hits.len});
    try std.testing.expectEqual(@as(usize, 2), parsed.value.hits.hits.len);
}

test "integration_bool_query" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_bool_query] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

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

    // Bool query: must=[term(active, true)], filter=[range(module_id).gte(900000000000207008)]
    // doc1: active=true, module_id=900000000000207008 → match (gte passes)
    // doc2: active=true, module_id=900000000000207008 → match
    // doc3: active=false → no match (must fails)
    const must_clauses = [_]Query{Query.term("active", true)};
    const filter_clauses = [_]Query{Query.range("module_id").gte(@as(u64, 900000000000207008)).build()};
    const q = Query.boolQuery(.{
        .must = &must_clauses,
        .filter = &filter_clauses,
    });
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

    // Assert: 2 docs (both active with module_id >= 900000000000207008)
    std.debug.print("  hits: {d}\n", .{parsed.value.hits.hits.len});
    try std.testing.expectEqual(@as(usize, 2), parsed.value.hits.hits.len);
}

test "integration_range_query" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_range_query] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

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

    // Range query: module_id >= 900000000000207008
    // doc1: module_id=900000000000207008 → match
    // doc2: module_id=900000000000207008 → match
    // doc3: module_id=900000000000012004 → no match
    const q = Query.range("module_id").gte(@as(u64, 900000000000207008)).build();
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

    // Assert: 2 docs with module_id >= 900000000000207008
    std.debug.print("  hits: {d}\n", .{parsed.value.hits.hits.len});
    try std.testing.expectEqual(@as(usize, 2), parsed.value.hits.hits.len);
}

test "integration_match_all" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_match_all] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

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

    // match_all query — should return all 3 docs
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

    // Assert: all 3 docs returned
    std.debug.print("  hits: {d}\n", .{parsed.value.hits.hits.len});
    try std.testing.expectEqual(@as(usize, 3), parsed.value.hits.hits.len);
}

test "integration_exists_query" {
    const allocator = std.testing.allocator;

    var base_buf: [256]u8 = undefined;
    const result = getBaseUrl(allocator, &base_buf) orelse return;
    defer allocator.free(result.es_url_owned);
    const base_url = result.base_url;

    var index_buf: [64]u8 = undefined;
    const index_name = generateIndexName(&index_buf);
    std.debug.print("\n  [integration_exists_query] index: {s}\n", .{index_name});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try createIndex(allocator, &client, base_url, index_name);
    defer deleteIndex(allocator, &client, base_url, index_name);

    // doc1: term = "Clinical finding" (present)
    // doc2: term = "SNOMED CT Concept" (present)
    // doc3: term = null (absent — elaztic omits null optionals)
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

    // Exists query on "term" — should match docs where the field is present
    const q = Query.exists("term");
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

    // Assert: 2 docs have the "term" field
    std.debug.print("  hits: {d}\n", .{parsed.value.hits.hits.len});
    try std.testing.expectEqual(@as(usize, 2), parsed.value.hits.hits.len);
}
