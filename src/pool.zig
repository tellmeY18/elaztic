//! HTTP connection pool and transport layer for Elasticsearch.
//!
//! Uses `std.http.Client` for proper HTTP/1.1 with keep-alive, gzip
//! decompression, and chunked transfer encoding handled automatically.
//! Implements round-robin node selection and retry logic with exponential backoff.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

/// A single Elasticsearch node endpoint.
pub const Node = struct {
    /// Scheme (e.g. "http" or "https").
    scheme: []const u8,
    /// Hostname or IP address.
    host: []const u8,
    /// Port number.
    port: u16,
    /// Whether this node is considered healthy.
    healthy: bool = true,
    /// Timestamp (ms) of last successful request.
    last_seen_alive: i64 = 0,
    /// Timestamp (ms) when this node was marked unhealthy, or null if healthy.
    dead_since: ?i64 = null,

    /// Format as "scheme://host:port".
    pub fn baseUrl(self: Node, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("{s}://{s}:{d}", .{ self.scheme, self.host, self.port });
        return fbs.getWritten();
    }
};

/// Log level for events emitted by the connection pool.
pub const LogLevel = enum { debug, info, warn, err };

/// Event emitted by the connection pool for observability.
/// Pass a callback via `ClientConfig.log_fn` to receive these events.
pub const LogEvent = union(enum) {
    /// Emitted before sending a request.
    request_start: struct {
        method: []const u8,
        path: []const u8,
    },
    /// Emitted on a successful (2xx) response.
    request_success: struct {
        method: []const u8,
        path: []const u8,
        status_code: u16,
        duration_ms: u64,
    },
    /// Emitted when a request is retried (429 or 5xx).
    request_retry: struct {
        method: []const u8,
        path: []const u8,
        attempt: u32,
        status_code: u16,
        backoff_ms: u64,
    },
    /// Emitted on a non-retryable error response.
    request_error: struct {
        method: []const u8,
        path: []const u8,
        status_code: u16,
    },
    /// Emitted when a node is marked unhealthy.
    node_unhealthy: struct {
        host: []const u8,
        port: u16,
    },
    /// Emitted when a previously-dead node recovers.
    node_recovered: struct {
        host: []const u8,
        port: u16,
    },
};

/// HTTP response from Elasticsearch.
pub const HttpResponse = struct {
    /// HTTP status code.
    status_code: u16,
    /// Response body bytes. Owned by the caller — must be freed with `allocator`.
    body: []u8,

    /// Free owned memory.
    pub fn deinit(self: *HttpResponse, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

/// Connection pool managing round-robin node selection and an underlying
/// `std.http.Client` that handles keep-alive and gzip automatically.
pub const ConnectionPool = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    nodes: NodeList,
    current_node: usize,
    mutex: std.Thread.Mutex,

    // Retry configuration — set from ClientConfig at init time.
    retry_count: u32,
    retry_backoff_ms: u32,

    /// Minimum ms before retrying a dead node (node health recovery).
    resurrect_after_ms: u32,
    /// Cap on exponential backoff to prevent unbounded growth.
    max_retry_backoff_ms: u32,
    /// Pre-computed Authorization header value (owned), or null if no auth.
    auth_header: ?[]const u8,
    /// Optional logging callback for observability.
    log_fn: ?*const fn (LogEvent) void,

    const NodeList = std.ArrayListUnmanaged(Node);

    /// Initialise the pool with one or more nodes derived from `ClientConfig`.
    pub fn init(allocator: Allocator, config: anytype) !ConnectionPool {
        var nodes: NodeList = .empty;
        const scheme: []const u8 = if (@hasField(@TypeOf(config), "scheme")) config.scheme else "http";
        try nodes.append(allocator, .{
            .scheme = scheme,
            .host = config.host,
            .port = config.port,
        });

        // Pre-compute the Authorization header value if auth is configured.
        // basic_auth takes precedence over api_key when both are set.
        const auth_header: ?[]const u8 = blk: {
            if (@hasField(@TypeOf(config), "basic_auth")) {
                if (config.basic_auth) |creds| {
                    const encoded_len = std.base64.standard.Encoder.calcSize(creds.len);
                    const buf = try allocator.alloc(u8, "Basic ".len + encoded_len);
                    @memcpy(buf[0.."Basic ".len], "Basic ");
                    _ = std.base64.standard.Encoder.encode(buf["Basic ".len..], creds);
                    break :blk buf;
                }
            }
            if (@hasField(@TypeOf(config), "api_key")) {
                if (config.api_key) |key| {
                    const buf = try allocator.alloc(u8, "ApiKey ".len + key.len);
                    @memcpy(buf[0.."ApiKey ".len], "ApiKey ");
                    @memcpy(buf["ApiKey ".len..], key);
                    break :blk buf;
                }
            }
            break :blk null;
        };

        return .{
            .allocator = allocator,
            .http_client = .{ .allocator = allocator },
            .nodes = nodes,
            .current_node = 0,
            .mutex = .{},
            .retry_count = config.retry_on_failure,
            .retry_backoff_ms = config.retry_backoff_ms,
            .resurrect_after_ms = if (@hasField(@TypeOf(config), "resurrect_after_ms")) config.resurrect_after_ms else 60_000,
            .max_retry_backoff_ms = if (@hasField(@TypeOf(config), "max_retry_backoff_ms")) config.max_retry_backoff_ms else 30_000,
            .auth_header = auth_header,
            .log_fn = if (@hasField(@TypeOf(config), "log_fn")) config.log_fn else null,
        };
    }

    /// Tear down all connections and free resources.
    pub fn deinit(self: *ConnectionPool) void {
        if (self.auth_header) |hdr| self.allocator.free(hdr);
        self.http_client.deinit();
        self.nodes.deinit(self.allocator);
    }

    /// Add an additional node to the pool.
    pub fn addNode(self: *ConnectionPool, scheme: []const u8, host: []const u8, port: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.nodes.append(self.allocator, .{ .scheme = scheme, .host = host, .port = port });
    }

    /// Pick the next healthy node (round-robin). When all nodes are
    /// unhealthy, attempts to resurrect the node that has been dead
    /// the longest (provided it has exceeded `resurrect_after_ms`).
    fn nextNode(self: *ConnectionPool) ?*Node {
        const n = self.nodes.items.len;
        if (n == 0) return null;

        // Try each node once, starting from current_node.
        var tried: usize = 0;
        while (tried < n) : (tried += 1) {
            const idx = (self.current_node + tried) % n;
            if (self.nodes.items[idx].healthy) {
                self.current_node = (idx + 1) % n;
                return &self.nodes.items[idx];
            }
        }

        // All nodes unhealthy — try to resurrect the one that's been dead longest.
        const now = std.time.milliTimestamp();
        var best_candidate: ?usize = null;
        var oldest_dead: i64 = std.math.maxInt(i64);

        for (self.nodes.items, 0..) |node, i| {
            if (node.dead_since) |ds| {
                if (now - ds >= self.resurrect_after_ms and ds < oldest_dead) {
                    oldest_dead = ds;
                    best_candidate = i;
                }
            }
        }

        if (best_candidate) |idx| {
            self.current_node = (idx + 1) % n;
            return &self.nodes.items[idx];
        }

        // No node eligible for resurrection — return current anyway.
        const idx = self.current_node % n;
        self.current_node = (idx + 1) % n;
        return &self.nodes.items[idx];
    }

    /// Mark a node as unhealthy and record the time it died.
    pub fn markUnhealthy(self: *ConnectionPool, node: *Node) void {
        _ = self;
        node.healthy = false;
        node.dead_since = std.time.milliTimestamp();
    }

    /// Mark a node as healthy and clear its dead_since timestamp.
    pub fn markHealthy(self: *ConnectionPool, node: *Node) void {
        _ = self;
        node.healthy = true;
        node.last_seen_alive = std.time.milliTimestamp();
        node.dead_since = null;
    }

    /// Parse a method string into an `http.Method`.
    fn parseMethod(method_str: []const u8) http.Method {
        if (std.mem.eql(u8, method_str, "GET")) return .GET;
        if (std.mem.eql(u8, method_str, "POST")) return .POST;
        if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
        if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
        return .GET;
    }

    /// Emit a log event if a logging callback is configured.
    fn emitLog(self: *ConnectionPool, event: LogEvent) void {
        if (self.log_fn) |log| log(event);
    }

    /// Send an HTTP request with retry logic and jittered exponential backoff.
    ///
    /// Returns the response body and status code. The caller owns the
    /// returned `HttpResponse.body` slice.
    pub fn sendRequest(
        self: *ConnectionPool,
        allocator: Allocator,
        method_str: []const u8,
        path: []const u8,
        body: ?[]const u8,
        compression: bool,
    ) !HttpResponse {
        const http_method = parseMethod(method_str);

        var last_err: anyerror = error.MaxRetriesExceeded;
        var backoff_ms: u64 = self.retry_backoff_ms;

        self.emitLog(.{ .request_start = .{ .method = method_str, .path = path } });

        var attempt: u32 = 0;
        while (attempt < self.retry_count) : (attempt += 1) {
            if (attempt > 0) {
                // Full jitter: random(0, min(cap, base * 2^attempt))
                const max_backoff = @min(self.max_retry_backoff_ms, backoff_ms);
                const jittered: u64 = if (max_backoff > 0)
                    std.crypto.random.intRangeAtMost(u64, 0, max_backoff)
                else
                    0;
                std.Thread.sleep(jittered * std.time.ns_per_ms);
                backoff_ms = @min(self.max_retry_backoff_ms, backoff_ms * 2);
            }

            // Select a node (round-robin).
            self.mutex.lock();
            const node = self.nextNode() orelse {
                self.mutex.unlock();
                return error.ClusterUnavailable;
            };
            const scheme = node.scheme;
            const host = node.host;
            const port = node.port;
            self.mutex.unlock();

            // Build the full URL: scheme://host:port/path
            var url_buf: [2048]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&url_buf);
            fbs.writer().print("{s}://{s}:{d}{s}", .{ scheme, host, port, path }) catch {
                return error.InvalidUri;
            };
            const url = fbs.getWritten();

            const uri = Uri.parse(url) catch {
                return error.InvalidUri;
            };

            // Build extra headers: Content-Type (if body) + Authorization (if auth).
            var hdrs_buf: [2]std.http.Header = undefined;
            var hdr_count: usize = 0;
            if (body != null) {
                hdrs_buf[hdr_count] = .{ .name = "Content-Type", .value = "application/json" };
                hdr_count += 1;
            }
            if (self.auth_header) |auth| {
                hdrs_buf[hdr_count] = .{ .name = "Authorization", .value = auth };
                hdr_count += 1;
            }
            const extra_hdrs: []const std.http.Header = hdrs_buf[0..hdr_count];

            // Open request via std.http.Client (handles keep-alive, connection reuse).
            // When compression is disabled, override the Accept-Encoding header
            // to "identity" so the server sends uncompressed responses.
            // We cannot use the accept_encoding bool array for this because
            // std.http.Client skips "identity" when emitting the header,
            // producing a malformed header line when it's the only entry.
            const start_time = std.time.milliTimestamp();
            var req = self.http_client.request(http_method, uri, .{
                .extra_headers = extra_hdrs,
                .headers = if (!compression) .{
                    .accept_encoding = .{ .override = "identity" },
                } else .{},
            }) catch |err| {
                self.markNodeUnhealthyByHostPort(host, port);
                last_err = err;
                continue;
            };
            defer req.deinit();

            // Send headers + body.
            //
            // std.http.Client has hard asserts:
            //   - sendBodyComplete asserts requestHasBody() (true for POST/PUT/PATCH)
            //   - sendBodiless asserts !requestHasBody()
            //
            // Elasticsearch uses DELETE with a JSON body for several endpoints
            // (clear scroll, close PIT, delete by query). Since DELETE's
            // requestHasBody() returns false, we cannot use sendBodyComplete.
            // Instead we write the HTTP request manually to the connection's
            // buffered writer, replicating what the private sendHead() does.
            // See CLAUDE.md §3a for the full rationale.
            if (body) |payload| {
                if (http_method.requestHasBody()) {
                    // Normal path: POST, PUT, PATCH with body.
                    req.sendBodyComplete(@constCast(payload)) catch |err| {
                        self.markNodeUnhealthyByHostPort(host, port);
                        last_err = err;
                        continue;
                    };
                } else {
                    // DELETE (or GET) with body — bypass the assert by writing
                    // the raw HTTP request to the connection writer.
                    sendBodyForMethodWithoutBody(&req, payload) catch |err| {
                        self.markNodeUnhealthyByHostPort(host, port);
                        last_err = err;
                        continue;
                    };
                }
            } else if (http_method.requestHasBody()) {
                req.sendBodyComplete(@constCast(@as([]const u8, ""))) catch |err| {
                    self.markNodeUnhealthyByHostPort(host, port);
                    last_err = err;
                    continue;
                };
            } else {
                req.sendBodiless() catch |err| {
                    self.markNodeUnhealthyByHostPort(host, port);
                    last_err = err;
                    continue;
                };
            }

            // Receive the response head.
            var redirect_buf: [2048]u8 = undefined;
            var response = req.receiveHead(&redirect_buf) catch |err| {
                self.markNodeUnhealthyByHostPort(host, port);
                last_err = err;
                continue;
            };

            const status_code: u16 = @intFromEnum(response.head.status);

            // Read the full response body.
            var transfer_buf: [8192]u8 = undefined;
            const reader = response.reader(&transfer_buf);
            const owned_body = reader.allocRemaining(allocator, .unlimited) catch |err| {
                last_err = err;
                continue;
            };

            const end_time = std.time.milliTimestamp();
            const duration_ms: u64 = @intCast(@max(0, end_time - start_time));

            // Mark node healthy (and emit recovery event if it was previously dead).
            self.mutex.lock();
            for (self.nodes.items) |*n| {
                if (std.mem.eql(u8, n.host, host) and n.port == port) {
                    const was_dead = !n.healthy;
                    n.healthy = true;
                    n.last_seen_alive = std.time.milliTimestamp();
                    n.dead_since = null;
                    if (was_dead) {
                        self.emitLog(.{ .node_recovered = .{ .host = host, .port = port } });
                    }
                }
            }
            self.mutex.unlock();

            // Retry on 429 / 5xx.
            if (status_code == 429 or status_code >= 500) {
                self.emitLog(.{ .request_retry = .{
                    .method = method_str,
                    .path = path,
                    .attempt = attempt,
                    .status_code = status_code,
                    .backoff_ms = backoff_ms,
                } });
                allocator.free(owned_body);
                last_err = if (status_code == 429) error.TooManyRequests else error.ServerError;
                continue;
            }

            // Non-retryable error (4xx other than 429).
            if (status_code >= 400) {
                self.emitLog(.{ .request_error = .{
                    .method = method_str,
                    .path = path,
                    .status_code = status_code,
                } });
            } else {
                self.emitLog(.{ .request_success = .{
                    .method = method_str,
                    .path = path,
                    .status_code = status_code,
                    .duration_ms = duration_ms,
                } });
            }

            return .{
                .status_code = status_code,
                .body = owned_body,
            };
        }

        return last_err;
    }

    /// Write a full HTTP request (head + body) to the connection writer for
    /// methods where `requestHasBody()` returns `false` (e.g. DELETE).
    ///
    /// Zig 0.15's `std.http.Client` hard-asserts in `sendBodyUnflushed` that
    /// the method supports a body. Elasticsearch legitimately requires DELETE
    /// with a JSON body for clear-scroll, close-PIT, and delete-by-query.
    ///
    /// This function replicates the essential parts of the private `sendHead`
    /// function, sets `Content-Length`, writes the body, and flushes. After
    /// this call the connection is in the correct state for `receiveHead`.
    fn sendBodyForMethodWithoutBody(req: *http.Client.Request, payload: []const u8) !void {
        const connection = req.connection orelse return error.ConnectionRefused;
        const w = connection.writer();

        // ── Request line ──────────────────────────────────────────────
        try w.writeAll(@tagName(req.method));
        try w.writeByte(' ');
        try req.uri.writeToStream(w, .{
            .scheme = connection.proxied,
            .authentication = connection.proxied,
            .authority = connection.proxied,
            .path = true,
            .query = true,
        });
        try w.writeByte(' ');
        try w.writeAll(@tagName(req.version));
        try w.writeAll("\r\n");

        // ── Host ──────────────────────────────────────────────────────
        try w.writeAll("host: ");
        try req.uri.writeToStream(w, .{ .authority = true });
        try w.writeAll("\r\n");

        // ── Connection ────────────────────────────────────────────────
        if (req.keep_alive) {
            try w.writeAll("connection: keep-alive\r\n");
        } else {
            try w.writeAll("connection: close\r\n");
        }

        // ── Accept-Encoding ───────────────────────────────────────────
        // Emit the same accept-encoding the normal path would produce so
        // that the response can be decoded correctly by receiveHead.
        {
            var has_any = false;
            for (req.accept_encoding, 0..) |enabled, i| {
                if (!enabled) continue;
                const tag: http.ContentEncoding = @enumFromInt(i);
                if (tag == .identity) continue;
                if (has_any) try w.writeAll(", ");
                if (!has_any) try w.writeAll("accept-encoding: ");
                try w.writeAll(@tagName(tag));
                has_any = true;
            }
            if (has_any) try w.writeAll("\r\n");
        }

        // ── Content-Length ────────────────────────────────────────────
        try w.print("content-length: {d}\r\n", .{payload.len});

        // ── Extra headers (includes Content-Type when set) ───────────
        for (req.extra_headers) |header| {
            try w.writeAll(header.name);
            try w.writeAll(": ");
            try w.writeAll(header.value);
            try w.writeAll("\r\n");
        }

        // ── End of headers ────────────────────────────────────────────
        try w.writeAll("\r\n");

        // ── Body ──────────────────────────────────────────────────────
        try w.writeAll(payload);
        try connection.flush();
    }

    /// Helper: mark a node unhealthy by host+port (thread-safe).
    fn markNodeUnhealthyByHostPort(self: *ConnectionPool, host: []const u8, port: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.host, host) and n.port == port) {
                n.healthy = false;
                n.dead_since = now;
            }
        }
        self.emitLog(.{ .node_unhealthy = .{ .host = host, .port = port } });
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "round_robin_node_selection" {
    const allocator = std.testing.allocator;
    var nodes: ConnectionPool.NodeList = .empty;
    defer nodes.deinit(allocator);

    try nodes.append(allocator, .{ .scheme = "http", .host = "node1", .port = 9200 });
    try nodes.append(allocator, .{ .scheme = "http", .host = "node2", .port = 9200 });
    try nodes.append(allocator, .{ .scheme = "http", .host = "node3", .port = 9200 });

    var pool_inst: ConnectionPool = .{
        .allocator = allocator,
        .http_client = .{ .allocator = allocator },
        .nodes = nodes,
        .current_node = 0,
        .mutex = .{},
        .retry_count = 3,
        .retry_backoff_ms = 100,
        .resurrect_after_ms = 60_000,
        .max_retry_backoff_ms = 30_000,
        .auth_header = null,
        .log_fn = null,
    };
    // Transfer ownership so deinit doesn't double-free.
    nodes = .empty;
    defer pool_inst.deinit();

    const n1 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node1", n1.host);

    const n2 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node2", n2.host);

    const n3 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node3", n3.host);

    // Wraps around.
    const n4 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node1", n4.host);
}

test "skip_unhealthy_node" {
    const allocator = std.testing.allocator;
    var nodes: ConnectionPool.NodeList = .empty;
    defer nodes.deinit(allocator);

    try nodes.append(allocator, .{ .scheme = "http", .host = "node1", .port = 9200 });
    try nodes.append(allocator, .{ .scheme = "http", .host = "node2", .port = 9200, .healthy = false });
    try nodes.append(allocator, .{ .scheme = "http", .host = "node3", .port = 9200 });

    var pool_inst: ConnectionPool = .{
        .allocator = allocator,
        .http_client = .{ .allocator = allocator },
        .nodes = nodes,
        .current_node = 0,
        .mutex = .{},
        .retry_count = 3,
        .retry_backoff_ms = 100,
        .resurrect_after_ms = 60_000,
        .max_retry_backoff_ms = 30_000,
        .auth_header = null,
        .log_fn = null,
    };
    nodes = .empty;
    defer pool_inst.deinit();

    const n1 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node1", n1.host);

    // node2 is unhealthy — should skip to node3.
    const n2 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node3", n2.host);
}

test "node_resurrection_after_timeout" {
    const allocator = std.testing.allocator;
    var nodes: ConnectionPool.NodeList = .empty;
    defer nodes.deinit(allocator);

    // All nodes unhealthy, with node2 dead the longest.
    const now = std.time.milliTimestamp();
    try nodes.append(allocator, .{
        .scheme = "http",
        .host = "node1",
        .port = 9200,
        .healthy = false,
        .dead_since = now - 30_000, // 30s ago — below threshold
    });
    try nodes.append(allocator, .{
        .scheme = "http",
        .host = "node2",
        .port = 9200,
        .healthy = false,
        .dead_since = now - 120_000, // 120s ago — oldest, above threshold
    });
    try nodes.append(allocator, .{
        .scheme = "http",
        .host = "node3",
        .port = 9200,
        .healthy = false,
        .dead_since = now - 90_000, // 90s ago — above threshold, but not oldest
    });

    var pool_inst: ConnectionPool = .{
        .allocator = allocator,
        .http_client = .{ .allocator = allocator },
        .nodes = nodes,
        .current_node = 0,
        .mutex = .{},
        .retry_count = 3,
        .retry_backoff_ms = 100,
        .resurrect_after_ms = 60_000,
        .max_retry_backoff_ms = 30_000,
        .auth_header = null,
        .log_fn = null,
    };
    nodes = .empty;
    defer pool_inst.deinit();

    // Should resurrect node2 (dead longest and past threshold).
    const resurrected = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node2", resurrected.host);
}

test "no_resurrection_before_timeout" {
    const allocator = std.testing.allocator;
    var nodes: ConnectionPool.NodeList = .empty;
    defer nodes.deinit(allocator);

    // All nodes unhealthy but died recently (below resurrect_after_ms).
    const now = std.time.milliTimestamp();
    try nodes.append(allocator, .{
        .scheme = "http",
        .host = "node1",
        .port = 9200,
        .healthy = false,
        .dead_since = now - 10_000, // 10s ago
    });
    try nodes.append(allocator, .{
        .scheme = "http",
        .host = "node2",
        .port = 9200,
        .healthy = false,
        .dead_since = now - 20_000, // 20s ago
    });

    var pool_inst: ConnectionPool = .{
        .allocator = allocator,
        .http_client = .{ .allocator = allocator },
        .nodes = nodes,
        .current_node = 0,
        .mutex = .{},
        .retry_count = 3,
        .retry_backoff_ms = 100,
        .resurrect_after_ms = 60_000,
        .max_retry_backoff_ms = 30_000,
        .auth_header = null,
        .log_fn = null,
    };
    nodes = .empty;
    defer pool_inst.deinit();

    // No node is past the 60s threshold — falls through to the current node.
    const fallback = pool_inst.nextNode().?;
    // Should return node at current_node (0) = node1, since no resurrection candidate.
    try std.testing.expectEqualStrings("node1", fallback.host);
}

test "mark_unhealthy_sets_dead_since" {
    const allocator = std.testing.allocator;
    var nodes: ConnectionPool.NodeList = .empty;
    defer nodes.deinit(allocator);

    try nodes.append(allocator, .{ .scheme = "http", .host = "node1", .port = 9200 });

    var pool_inst: ConnectionPool = .{
        .allocator = allocator,
        .http_client = .{ .allocator = allocator },
        .nodes = nodes,
        .current_node = 0,
        .mutex = .{},
        .retry_count = 3,
        .retry_backoff_ms = 100,
        .resurrect_after_ms = 60_000,
        .max_retry_backoff_ms = 30_000,
        .auth_header = null,
        .log_fn = null,
    };
    nodes = .empty;
    defer pool_inst.deinit();

    const node = &pool_inst.nodes.items[0];
    try std.testing.expect(node.dead_since == null);
    try std.testing.expect(node.healthy);

    pool_inst.markUnhealthy(node);
    try std.testing.expect(!node.healthy);
    try std.testing.expect(node.dead_since != null);

    pool_inst.markHealthy(node);
    try std.testing.expect(node.healthy);
    try std.testing.expect(node.dead_since == null);
}

test "jittered_backoff_is_bounded" {
    // Verify that the jitter formula produces values within [0, cap].
    const cap: u64 = 5_000;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const jittered = std.crypto.random.intRangeAtMost(u64, 0, cap);
        try std.testing.expect(jittered <= cap);
    }
}

test "scheme_from_config" {
    const allocator = std.testing.allocator;
    const config = .{
        .host = "secure.example.com",
        .port = @as(u16, 9243),
        .retry_on_failure = @as(u32, 3),
        .retry_backoff_ms = @as(u32, 100),
        .scheme = "https",
    };

    var pool = try ConnectionPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expectEqualStrings("https", pool.nodes.items[0].scheme);
}

test "auth_header_basic" {
    const allocator = std.testing.allocator;
    const config = .{
        .host = "localhost",
        .port = @as(u16, 9200),
        .retry_on_failure = @as(u32, 3),
        .retry_backoff_ms = @as(u32, 100),
        .basic_auth = @as(?[]const u8, "elastic:changeme"),
    };

    var pool = try ConnectionPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expect(pool.auth_header != null);
    try std.testing.expectEqualStrings("Basic ZWxhc3RpYzpjaGFuZ2VtZQ==", pool.auth_header.?);
}

test "auth_header_api_key" {
    const allocator = std.testing.allocator;
    const config = .{
        .host = "localhost",
        .port = @as(u16, 9200),
        .retry_on_failure = @as(u32, 3),
        .retry_backoff_ms = @as(u32, 100),
        .api_key = @as(?[]const u8, "my-api-key-value"),
    };

    var pool = try ConnectionPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expect(pool.auth_header != null);
    try std.testing.expectEqualStrings("ApiKey my-api-key-value", pool.auth_header.?);
}

test "auth_header_none" {
    const allocator = std.testing.allocator;
    const config = .{
        .host = "localhost",
        .port = @as(u16, 9200),
        .retry_on_failure = @as(u32, 3),
        .retry_backoff_ms = @as(u32, 100),
    };

    var pool = try ConnectionPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expect(pool.auth_header == null);
}

test "auth_header_basic_takes_precedence_over_api_key" {
    const allocator = std.testing.allocator;
    const config = .{
        .host = "localhost",
        .port = @as(u16, 9200),
        .retry_on_failure = @as(u32, 3),
        .retry_backoff_ms = @as(u32, 100),
        .basic_auth = @as(?[]const u8, "user:pass"),
        .api_key = @as(?[]const u8, "my-key"),
    };

    var pool = try ConnectionPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expect(pool.auth_header != null);
    // Should use basic auth, not api_key.
    try std.testing.expect(std.mem.startsWith(u8, pool.auth_header.?, "Basic "));
}

test "log_event_emission" {
    const allocator = std.testing.allocator;
    var nodes: ConnectionPool.NodeList = .empty;
    defer nodes.deinit(allocator);

    try nodes.append(allocator, .{ .scheme = "http", .host = "node1", .port = 9200 });

    const S = struct {
        var events_received: usize = 0;
        var last_event_tag: ?std.meta.Tag(LogEvent) = null;

        fn logCallback(event: LogEvent) void {
            events_received += 1;
            last_event_tag = std.meta.activeTag(event);
        }
    };
    S.events_received = 0;
    S.last_event_tag = null;

    var pool_inst: ConnectionPool = .{
        .allocator = allocator,
        .http_client = .{ .allocator = allocator },
        .nodes = nodes,
        .current_node = 0,
        .mutex = .{},
        .retry_count = 3,
        .retry_backoff_ms = 100,
        .resurrect_after_ms = 60_000,
        .max_retry_backoff_ms = 30_000,
        .auth_header = null,
        .log_fn = &S.logCallback,
    };
    nodes = .empty;
    defer pool_inst.deinit();

    // Emit node_unhealthy event via the helper.
    pool_inst.markNodeUnhealthyByHostPort("node1", 9200);

    try std.testing.expectEqual(@as(usize, 1), S.events_received);
    try std.testing.expectEqual(LogEvent.node_unhealthy, S.last_event_tag.?);
}
