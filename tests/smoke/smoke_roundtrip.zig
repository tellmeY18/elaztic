//! Smoke test: round-trip a Zig struct through serialization/deserialization
//! and optionally through ZincSearch.
//!
//! Tests 1 & 2 run without any network — they validate the JSON
//! serialize → deserialize pipeline in isolation.
//!
//! Test 3 requires ZINC_URL and ZINC_AUTH environment variables pointing at a
//! running ZincSearch instance.  Start it with `zinc-start` from the dev shell.
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
// Test 3 — full round-trip via ZincSearch (requires ZINC_URL + ZINC_AUTH)
// ---------------------------------------------------------------------------

test "smoke_zinc_index_roundtrip" {
    const allocator = std.testing.allocator;

    // -- gate on environment variables --
    const zinc_url = std.process.getEnvVarOwned(allocator, "ZINC_URL") catch {
        std.debug.print("SKIP: ZINC_URL not set\n", .{});
        return;
    };
    defer allocator.free(zinc_url);

    const zinc_auth = std.process.getEnvVarOwned(allocator, "ZINC_AUTH") catch {
        std.debug.print("SKIP: ZINC_AUTH not set\n", .{});
        return;
    };
    defer allocator.free(zinc_auth);

    // Parse host + port from the URL.
    const uri = std.Uri.parse(zinc_url) catch {
        std.debug.print("SKIP: ZINC_URL is not a valid URI\n", .{});
        return;
    };
    const host_str = hostFromUri(uri);
    const port: u16 = uri.port orelse 4080;

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
    // Note: ZincSearch stores numbers as float64 internally, which can only
    // represent integers exactly up to 2^53 (9007199254740992).  Full SNOMED
    // concept IDs like 900000000000207008 exceed this and lose precision.
    // For the smoke test we use IDs that round-trip safely through float64.
    // Real Elasticsearch (M3+) handles u64 via string mapping and has no
    // such limitation.
    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
        term: []const u8,
    };

    const doc = Concept{
        .id = 404684003,
        .active = true,
        .module_id = 900000000000012,
        .term = "Clinical finding",
    };

    // Serialize with elaztic.
    const doc_json = try elaztic.serialize.toJson(allocator, doc);
    defer allocator.free(doc_json);

    // -- build Basic auth header --
    const b64 = std.base64.standard.Encoder;
    var auth_buf: [512]u8 = undefined;
    const prefix = "Basic ";
    @memcpy(auth_buf[0..prefix.len], prefix);
    const encoded = b64.encode(auth_buf[prefix.len..], zinc_auth);
    const auth_header = auth_buf[0 .. prefix.len + encoded.len];

    // -- HTTP client (std.http.Client directly; ESClient doesn't wire auth yet) --
    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    // ---------------------------------------------------------------
    // PUT /es/<index>/_doc/1  — index the document
    // ---------------------------------------------------------------
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/es/{s}/_doc/1", .{ base_url, index_name });
        const url = url_fbs.getWritten();
        const put_uri = try std.Uri.parse(url);

        var req = try http_client.request(.PUT, put_uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        // doc_json is already []u8 — no @constCast needed.
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

    // Small delay — ZincSearch is eventually consistent.
    std.Thread.sleep(1000 * std.time.ns_per_ms);

    // ---------------------------------------------------------------
    // POST /es/<index>/_search  — search for the document and verify
    // (ZincSearch does not implement GET _doc/<id>, so we use _search)
    // ---------------------------------------------------------------
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/es/{s}/_search", .{ base_url, index_name });
        const url = url_fbs.getWritten();
        const search_uri = try std.Uri.parse(url);

        const search_body =
            \\{"query":{"match_all":{}},"size":10}
        ;

        var req = try http_client.request(.POST, search_uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
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
    // DELETE /es/<index>  — cleanup
    // ---------------------------------------------------------------
    {
        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("{s}/es/{s}", .{ base_url, index_name });
        const url = url_fbs.getWritten();
        const del_uri = try std.Uri.parse(url);

        var req = try http_client.request(.DELETE, del_uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
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
