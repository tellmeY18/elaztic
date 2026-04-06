//! Smoke test: ping Elasticsearch/OpenSearch and verify we get a response.
//!
//! Requires the ES_URL environment variable (e.g. http://localhost:9200).
//! The target cluster should be running with security disabled.
//!
//! Run with: zig build test-smoke

const std = @import("std");
const elaztic = @import("elaztic");

fn hostFromUri(uri: std.Uri) []const u8 {
    if (uri.host) |h| {
        return switch (h) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };
    }
    return "localhost";
}

test "smoke_ping_cluster_health" {
    const allocator = std.testing.allocator;
    const es_url = std.process.getEnvVarOwned(allocator, "ES_URL") catch {
        std.debug.print("SKIP: ES_URL not set\n", .{});
        return;
    };
    defer allocator.free(es_url);
    const uri = std.Uri.parse(es_url) catch {
        std.debug.print("SKIP: ES_URL is not a valid URI\n", .{});
        return;
    };
    const host = hostFromUri(uri);
    const port = uri.port orelse 9200;
    var client = try elaztic.ESClient.init(allocator, .{
        .host = host,
        .port = port,
        .compression = false,
        .retry_on_failure = 2,
        .retry_backoff_ms = 200,
    });
    defer client.deinit();
    var response = try client.rawRequest("GET", "/_cluster/health", null);
    defer response.deinit(allocator);
    std.debug.print("\n  status: {d}\n  body: {s}\n", .{ response.status_code, response.body });
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(response.body.len > 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const status_val = parsed.value.object.get("status") orelse {
        return error.MissingStatusField;
    };
    const status_str = status_val.string;
    const valid = std.mem.eql(u8, status_str, "green") or
        std.mem.eql(u8, status_str, "yellow") or
        std.mem.eql(u8, status_str, "red");
    if (!valid) {
        std.debug.print("  unexpected cluster status: {s}\n", .{status_str});
        return error.UnexpectedClusterStatus;
    }
}

test "smoke_raw_request_root" {
    const allocator = std.testing.allocator;
    const es_url = std.process.getEnvVarOwned(allocator, "ES_URL") catch {
        std.debug.print("SKIP: ES_URL not set\n", .{});
        return;
    };
    defer allocator.free(es_url);
    const uri = std.Uri.parse(es_url) catch {
        std.debug.print("SKIP: ES_URL is not a valid URI\n", .{});
        return;
    };
    const host = hostFromUri(uri);
    const port = uri.port orelse 9200;
    var client = try elaztic.ESClient.init(allocator, .{
        .host = host,
        .port = port,
        .compression = false,
        .retry_on_failure = 2,
        .retry_backoff_ms = 200,
    });
    defer client.deinit();
    var response = try client.rawRequest("GET", "/_cluster/health", null);
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(response.body.len > 0);
}

test "smoke_connection_pool_reuse" {
    const allocator = std.testing.allocator;
    const es_url = std.process.getEnvVarOwned(allocator, "ES_URL") catch {
        std.debug.print("SKIP: ES_URL not set\n", .{});
        return;
    };
    defer allocator.free(es_url);
    const uri = std.Uri.parse(es_url) catch {
        std.debug.print("SKIP: ES_URL is not a valid URI\n", .{});
        return;
    };
    const host = hostFromUri(uri);
    const port = uri.port orelse 9200;
    var client = try elaztic.ESClient.init(allocator, .{
        .host = host,
        .port = port,
        .compression = false,
        .retry_on_failure = 2,
        .retry_backoff_ms = 200,
    });
    defer client.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var response = try client.rawRequest("GET", "/_cluster/health", null);
        defer response.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
    }
}
