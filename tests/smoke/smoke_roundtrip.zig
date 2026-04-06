//! Smoke test: round-trip a Zig struct through serialization/deserialization
//! and optionally through Elasticsearch/OpenSearch.
//!
//! Tests 1 & 2 run without any network — they validate the JSON
//! serialize → deserialize pipeline in isolation.
//!
//! Test 3 requires the ES_URL environment variable pointing at a running
//! Elasticsearch or OpenSearch instance (security disabled).
//! Start it with `just es-start` from the dev shell.
//!
//! Run with: zig build test-smoke

const std = @import("std");
const elaztic = @import("elaztic");

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

// ---------------------------------------------------------------------------
// Test 1 — serialize → deserialize round-trip (no network)
// ---------------------------------------------------------------------------

test "smoke_serialize_deserialize_roundtrip" {
    const allocator = std.testing.allocator;

    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
        term: []const u8,
        effective_time: ?[]const u8 = null,
    };

    const original = Concept{
        .id = 404684003,
        .active = true,
        .module_id = 900000000000207008,
        .term = "Clinical finding",
        .effective_time = "20020131",
    };

    // Serialize to JSON using elaztic's serializer.
    const json = try elaztic.serialize.toJson(allocator, original);
    defer allocator.free(json);

    // Deserialize back into the same struct type.
    var parsed = try elaztic.deserialize.fromJson(Concept, allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(original.id, parsed.value.id);
    try std.testing.expectEqual(original.active, parsed.value.active);
    try std.testing.expectEqual(original.module_id, parsed.value.module_id);
    try std.testing.expectEqualStrings(original.term, parsed.value.term);
    try std.testing.expectEqualStrings(original.effective_time.?, parsed.value.effective_time.?);
}

// ---------------------------------------------------------------------------
// Test 2 — parse a realistic ES search response (no network)
// ---------------------------------------------------------------------------

test "smoke_search_response_parse" {
    const allocator = std.testing.allocator;

    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
    };

    const json =
        \\{
        \\  "took": 12,
        \\  "timed_out": false,
        \\  "_shards": {"total": 5, "successful": 5, "skipped": 0, "failed": 0},
        \\  "hits": {
        \\    "total": {"value": 1, "relation": "eq"},
        \\    "max_score": 1.0,
        \\    "hits": [
        \\      {
        \\        "_index": "concepts",
        \\        "_id": "404684003",
        \\        "_score": 1.0,
        \\        "_source": {"id": 404684003, "active": true, "module_id": 900000000000207008}
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var parsed = try elaztic.deserialize.fromJson(
        elaztic.deserialize.SearchResponse(Concept),
        allocator,
        json,
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 12), parsed.value.took.?);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.hits.total.?.value);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.hits.hits.len);

    const hit = parsed.value.hits.hits[0];
    try std.testing.expectEqualStrings("concepts", hit._index.?);
    try std.testing.expectEqualStrings("404684003", hit._id.?);

    const src = hit._source.?;
    try std.testing.expectEqual(@as(u64, 404684003), src.id);
    try std.testing.expectEqual(true, src.active);
    try std.testing.expectEqual(@as(u64, 900000000000207008), src.module_id);
}

// ---------------------------------------------------------------------------
// Test 3 — full round-trip via Elasticsearch/OpenSearch (requires ES_URL)
// ---------------------------------------------------------------------------

test "smoke_es_index_roundtrip" {
    const allocator = std.testing.allocator;

    // -- gate on environment variable --
    const es_url = std.process.getEnvVarOwned(allocator, "ES_URL") catch {
        std.debug.print("SKIP: ES_URL not set\n", .{});
        return;
    };
    defer allocator.free(es_url);

    // Parse host + port from the URL.
    const uri = std.Uri.parse(es_url) catch {
        std.debug.print("SKIP: ES_URL is not a valid URI\n", .{});
        return;
    };
    const host_str = hostFromUri(uri);
    const port: u16 = uri.port orelse 9200;

    // -- base URL for constructing request paths --
    var base_buf: [256]u8 = undefined;
    var base_fbs = std.io.fixedBufferStream(&base_buf);
    base_fbs.writer().print("http://{s}:{d}", .{ host_str, port }) catch return;
    const base_url = base_fbs.getWritten();

    // -- unique index name (timestamp-based) --
    const ts = std.time.milliTimestamp();
    var index_buf: [64]u8 = undefined;
    var index_fbs = std.io.fixedBufferStream(&index_buf);
    index_fbs.writer().print("smoke-rt-{d}", .{ts}) catch return;
    const index_name = index_fbs.getWritten();

    // -- document type --
    // Elasticsearch / OpenSearch handle u64 natively.  We use full SNOMED
    // concept IDs here.
    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
        term: []const u8,
    };

    const doc = Concept{
        .id = 404684003,
        .active = true,
        .module_id = 900000000000207008,
        .term = "Clinical finding",
    };

    // Serialize with elaztic.
    const doc_json = try elaztic.serialize.toJson(allocator, doc);
    defer allocator.free(doc_json);

    // -- HTTP client (std.http.Client directly; ESClient doesn't wire all verbs yet) --
    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    // ---------------------------------------------------------------
    // PUT /<index>/_doc/1  — index the document
    // ---------------------------------------------------------------
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_doc/1", .{ base_url, index_name });
        const url = url_fbs.getWritten();
        const put_uri = try std.Uri.parse(url);

        var req = try http_client.request(.PUT, put_uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer req.deinit();

        try req.sendBodyComplete(doc_json);

        var hdr_buf: [2048]u8 = undefined;
        var response = try req.receiveHead(&hdr_buf);

        var xfer_buf: [8192]u8 = undefined;
        const body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);
        defer allocator.free(body);

        std.debug.print("\n  PUT status: {d}\n  PUT body: {s}\n", .{
            @intFromEnum(response.head.status),
            body,
        });
        try std.testing.expect(@intFromEnum(response.head.status) < 300);
    }

    // ---------------------------------------------------------------
    // POST /<index>/_refresh  — make the indexed document searchable
    // ---------------------------------------------------------------
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_refresh", .{ base_url, index_name });
        const url = url_fbs.getWritten();
        const refresh_uri = try std.Uri.parse(url);

        var req = try http_client.request(.POST, refresh_uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(@as([]const u8, "")));

        var hdr_buf: [2048]u8 = undefined;
        var response = try req.receiveHead(&hdr_buf);

        var xfer_buf: [8192]u8 = undefined;
        const refresh_body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);
        defer allocator.free(refresh_body);

        std.debug.print("  REFRESH status: {d}\n", .{@intFromEnum(response.head.status)});
        try std.testing.expect(@intFromEnum(response.head.status) == 200);
    }

    // ---------------------------------------------------------------
    // POST /<index>/_search  — search for the document and verify
    // ---------------------------------------------------------------
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}/_search", .{ base_url, index_name });
        const url = url_fbs.getWritten();
        const search_uri = try std.Uri.parse(url);

        const search_body =
            \\{"query":{"match_all":{}},"size":10}
        ;

        var req = try http_client.request(.POST, search_uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(@as([]const u8, search_body)));

        var hdr_buf: [2048]u8 = undefined;
        var response = try req.receiveHead(&hdr_buf);

        var xfer_buf: [8192]u8 = undefined;
        const body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);
        defer allocator.free(body);

        std.debug.print("  SEARCH status: {d}\n  SEARCH body: {s}\n", .{
            @intFromEnum(response.head.status),
            body,
        });
        try std.testing.expect(@intFromEnum(response.head.status) == 200);

        // Deserialize as a SearchResponse using elaztic's typed deserializer.
        var parsed = try elaztic.deserialize.fromJson(
            elaztic.deserialize.SearchResponse(Concept),
            allocator,
            body,
        );
        defer parsed.deinit();

        const resp = parsed.value;

        // We should have at least one hit.
        try std.testing.expect(resp.hits.hits.len >= 1);

        const source = resp.hits.hits[0]._source orelse {
            std.debug.print("  FAIL: _source is null in search hit\n", .{});
            return error.TestUnexpectedResult;
        };

        try std.testing.expectEqual(doc.id, source.id);
        try std.testing.expectEqual(doc.active, source.active);
        try std.testing.expectEqual(doc.module_id, source.module_id);
        try std.testing.expectEqualStrings(doc.term, source.term);
    }

    // ---------------------------------------------------------------
    // DELETE /<index>  — cleanup
    // ---------------------------------------------------------------
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/{s}", .{ base_url, index_name });
        const url = url_fbs.getWritten();
        const del_uri = try std.Uri.parse(url);

        var req = try http_client.request(.DELETE, del_uri, .{
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer req.deinit();

        try req.sendBodiless();

        var hdr_buf: [2048]u8 = undefined;
        var response = try req.receiveHead(&hdr_buf);

        var xfer_buf: [8192]u8 = undefined;
        const del_body = try response.reader(&xfer_buf).allocRemaining(allocator, .unlimited);
        defer allocator.free(del_body);

        std.debug.print("  DELETE status: {d}\n", .{@intFromEnum(response.head.status)});
    }
}
