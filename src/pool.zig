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

    /// Format as "scheme://host:port".
    pub fn baseUrl(self: Node, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("{s}://{s}:{d}", .{ self.scheme, self.host, self.port });
        return fbs.getWritten();
    }
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

    const NodeList = std.ArrayListUnmanaged(Node);

    /// Initialise the pool with one or more nodes derived from `ClientConfig`.
    pub fn init(allocator: Allocator, config: anytype) !ConnectionPool {
        var nodes: NodeList = .empty;
        try nodes.append(allocator, .{
            .scheme = "http",
            .host = config.host,
            .port = config.port,
        });

        return .{
            .allocator = allocator,
            .http_client = .{ .allocator = allocator },
            .nodes = nodes,
            .current_node = 0,
            .mutex = .{},
            .retry_count = config.retry_on_failure,
            .retry_backoff_ms = config.retry_backoff_ms,
        };
    }

    /// Tear down all connections and free resources.
    pub fn deinit(self: *ConnectionPool) void {
        self.http_client.deinit();
        self.nodes.deinit(self.allocator);
    }

    /// Add an additional node to the pool.
    pub fn addNode(self: *ConnectionPool, scheme: []const u8, host: []const u8, port: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.nodes.append(self.allocator, .{ .scheme = scheme, .host = host, .port = port });
    }

    /// Pick the next healthy node (round-robin).
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

        // All nodes unhealthy — return the current one anyway and let the
        // caller deal with the connection error.
        const idx = self.current_node % n;
        self.current_node = (idx + 1) % n;
        return &self.nodes.items[idx];
    }

    /// Mark a node as unhealthy.
    pub fn markUnhealthy(self: *ConnectionPool, node: *Node) void {
        _ = self;
        node.healthy = false;
    }

    /// Mark a node as healthy.
    pub fn markHealthy(self: *ConnectionPool, node: *Node) void {
        _ = self;
        node.healthy = true;
        node.last_seen_alive = std.time.milliTimestamp();
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

    /// Send an HTTP request with retry logic and exponential backoff.
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

        var attempt: u32 = 0;
        while (attempt < self.retry_count) : (attempt += 1) {
            if (attempt > 0) {
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                backoff_ms *= 2;
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

            // Open request via std.http.Client (handles keep-alive, connection reuse).
            // When compression is disabled, override the Accept-Encoding header
            // to "identity" so the server sends uncompressed responses.
            // We cannot use the accept_encoding bool array for this because
            // std.http.Client skips "identity" when emitting the header,
            // producing a malformed header line when it's the only entry.
            const content_type_header: std.http.Header = .{ .name = "Content-Type", .value = "application/json" };
            const extra_hdrs: []const std.http.Header = if (body != null) &.{content_type_header} else &.{};
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
            // Note: std.http.Client asserts that sendBodiless() is only
            // called for methods that never carry a body (GET, HEAD, etc.).
            // For POST/PUT/DELETE without a body we send an empty payload.
            if (body) |payload| {
                req.sendBodyComplete(@constCast(payload)) catch |err| {
                    self.markNodeUnhealthyByHostPort(host, port);
                    last_err = err;
                    continue;
                };
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

            // Mark node healthy.
            self.mutex.lock();
            for (self.nodes.items) |*n| {
                if (std.mem.eql(u8, n.host, host) and n.port == port) {
                    n.healthy = true;
                    n.last_seen_alive = std.time.milliTimestamp();
                }
            }
            self.mutex.unlock();

            // Retry on 429 / 5xx.
            if (status_code == 429 or status_code >= 500) {
                allocator.free(owned_body);
                last_err = error.ServerError;
                continue;
            }

            return .{
                .status_code = status_code,
                .body = owned_body,
            };
        }

        return last_err;
    }

    /// Helper: mark a node unhealthy by host+port (thread-safe).
    fn markNodeUnhealthyByHostPort(self: *ConnectionPool, host: []const u8, port: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.host, host) and n.port == port) {
                n.healthy = false;
            }
        }
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
    };
    nodes = .empty;
    defer pool_inst.deinit();

    const n1 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node1", n1.host);

    // node2 is unhealthy — should skip to node3.
    const n2 = pool_inst.nextNode().?;
    try std.testing.expectEqualStrings("node3", n2.host);
}
