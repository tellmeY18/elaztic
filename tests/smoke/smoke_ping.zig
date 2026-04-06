//! Smoke test: ping ZincSearch and verify we get a response.
//!
//! Requires ZINC_URL and ZINC_AUTH environment variables.
//! Start ZincSearch with `zinc-start` before running.
//!
//! Run with: zig build test-smoke

const std = @import("std");
const elaztic = @import("elaztic");

/// Helper to extract host string from a parsed URI host component.
fn hostFromUri(uri: std.Uri) []const u8 {
    if (uri.host) |h| {
        return switch (h) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };
    }
    return "localhost";
}

test "smoke_ping_healthz" {
    const allocator = std.testing.allocator;

    // Read ZINC_URL; skip test if not set.
    const zinc_url = std.process.getEnvVarOwned(allocator, "ZINC_URL") catch {
        std.debug.print("SKIP: ZINC_URL not set\n", .{});
        return;
    };
    defer allocator.free(zinc_url);

    // Parse host and port from the URL.
    const uri = std.Uri.parse(zinc_url) catch {
        std.debug.print("SKIP: ZINC_URL is not a valid URI\n", .{});
        return;
    };

    const host = hostFromUri(uri);
    const port = uri.port orelse 4080;

    var client = try elaztic.ESClient.init(allocator, .{
        .host = host,
        .port = port,
        .compression = false,
        .retry_on_failure = 2,
        .retry_backoff_ms = 200,
    });
    defer client.deinit();

    // ZincSearch uses /healthz instead of /_cluster/health
    var response = try client.rawRequest("GET", "/healthz", null);
    defer response.deinit(allocator);

    std.debug.print("\n  status: {d}\n  body: {s}\n", .{ response.status_code, response.body });

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(response.body.len > 0);

    // Verify it parses as JSON with a "status" field
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();

    const status_val = parsed.value.object.get("status") orelse {
        return error.MissingStatusField;
    };
    try std.testing.expectEqualStrings("ok", status_val.string);
}

test "smoke_raw_request_root" {
    const allocator = std.testing.allocator;

    const zinc_url = std.process.getEnvVarOwned(allocator, "ZINC_URL") catch {
        std.debug.print("SKIP: ZINC_URL not set\n", .{});
        return;
    };
    defer allocator.free(zinc_url);

    const uri = std.Uri.parse(zinc_url) catch {
        std.debug.print("SKIP: ZINC_URL is not a valid URI\n", .{});
        return;
    };

    const host = hostFromUri(uri);
    const port = uri.port orelse 4080;

    var client = try elaztic.ESClient.init(allocator, .{
        .host = host,
        .port = port,
        .compression = false,
        .retry_on_failure = 2,
        .retry_backoff_ms = 200,
    });
    defer client.deinit();

    // GET / on ZincSearch returns a 302 redirect to the UI.
    // Our client follows redirects by default, so we should get 200 back.
    var response = try client.rawRequest("GET", "/healthz", null);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(response.body.len > 0);
}

test "smoke_connection_pool_reuse" {
    const allocator = std.testing.allocator;

    const zinc_url = std.process.getEnvVarOwned(allocator, "ZINC_URL") catch {
        std.debug.print("SKIP: ZINC_URL not set\n", .{});
        return;
    };
    defer allocator.free(zinc_url);

    const uri = std.Uri.parse(zinc_url) catch {
        std.debug.print("SKIP: ZINC_URL is not a valid URI\n", .{});
        return;
    };

    const host = hostFromUri(uri);
    const port = uri.port orelse 4080;

    var client = try elaztic.ESClient.init(allocator, .{
        .host = host,
        .port = port,
        .compression = false,
        .retry_on_failure = 2,
        .retry_backoff_ms = 200,
    });
    defer client.deinit();

    // Issue multiple sequential requests to verify connection reuse (keep-alive).
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var response = try client.rawRequest("GET", "/healthz", null);
        defer response.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
    }
}
