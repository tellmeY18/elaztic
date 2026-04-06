//! Elasticsearch client implementation.
//!
//! Provides the main `ESClient` struct for interacting with Elasticsearch
//! clusters. This is the root of all state — no global state exists.

const std = @import("std");
const pool = @import("pool.zig");

/// Configuration for the Elasticsearch client.
pub const ClientConfig = struct {
    /// Elasticsearch host (default: localhost).
    host: []const u8 = "localhost",
    /// Elasticsearch port (default: 9200).
    port: u16 = 9200,
    /// Maximum connections per node.
    max_connections_per_node: u32 = 10,
    /// Request timeout in milliseconds.
    request_timeout_ms: u32 = 30_000,
    /// Number of retries on failure.
    retry_on_failure: u32 = 3,
    /// Initial backoff time between retries in milliseconds (doubles each retry).
    retry_backoff_ms: u32 = 100,
    /// Enable gzip compression for request/response bodies.
    compression: bool = true,
    /// Optional HTTP Basic auth credentials ("user:password").
    basic_auth: ?[]const u8 = null,
};

/// Cluster health response from Elasticsearch.
pub const ClusterHealth = struct {
    /// Name of the cluster.
    cluster_name: []const u8,
    /// Status of the cluster ("green", "yellow", or "red").
    status: []const u8,
    /// Number of nodes in the cluster.
    number_of_nodes: ?i64 = null,
    /// Whether the cluster has timed out.
    timed_out: ?bool = null,

    /// The body slice backing `cluster_name` and `status` — caller frees.
    _raw_body: []u8,

    /// Free resources.
    pub fn deinit(self: *ClusterHealth, allocator: std.mem.Allocator) void {
        allocator.free(self._raw_body);
    }
};

/// Elasticsearch client for managing connections and executing requests.
///
/// All allocations are explicit. Caller owns memory returned by the client
/// and must call the appropriate `deinit()`.
pub const ESClient = struct {
    /// Memory allocator.
    allocator: std.mem.Allocator,
    /// Client configuration.
    config: ClientConfig,
    /// Connection pool for HTTP connections.
    connection_pool: pool.ConnectionPool,

    /// Initialize a new Elasticsearch client.
    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) !ESClient {
        const p = try pool.ConnectionPool.init(allocator, config);
        return .{
            .allocator = allocator,
            .config = config,
            .connection_pool = p,
        };
    }

    /// Deinitialize the client and clean up all resources.
    pub fn deinit(self: *ESClient) void {
        self.connection_pool.deinit();
    }

    /// Add an additional Elasticsearch node to the connection pool.
    pub fn addNode(self: *ESClient, scheme: []const u8, host: []const u8, port: u16) !void {
        try self.connection_pool.addNode(scheme, host, port);
    }

    /// Ping the Elasticsearch cluster by requesting `/_cluster/health`.
    /// Returns the parsed cluster health. Caller must call `deinit()` on the result.
    pub fn ping(self: *ESClient) !ClusterHealth {
        var response = try self.connection_pool.sendRequest(
            self.allocator,
            "GET",
            "/_cluster/health",
            null,
            self.config.compression,
        );
        // response.body is owned by us; don't defer-free here — we'll hand
        // ownership to the ClusterHealth struct on success.

        if (response.status_code != 200) {
            response.deinit(self.allocator);
            return error.UnexpectedResponse;
        }

        // Parse JSON using std.json.
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response.body,
            .{},
        ) catch {
            response.deinit(self.allocator);
            return error.MalformedJson;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        const cluster_name = root.get("cluster_name") orelse {
            response.deinit(self.allocator);
            return error.MalformedJson;
        };
        const status = root.get("status") orelse {
            response.deinit(self.allocator);
            return error.MalformedJson;
        };

        var health = ClusterHealth{
            .cluster_name = switch (cluster_name) {
                .string => |s| s,
                else => {
                    response.deinit(self.allocator);
                    return error.MalformedJson;
                },
            },
            .status = switch (status) {
                .string => |s| s,
                else => {
                    response.deinit(self.allocator);
                    return error.MalformedJson;
                },
            },
            ._raw_body = response.body,
        };

        // Extract optional fields.
        if (root.get("number_of_nodes")) |v| {
            switch (v) {
                .integer => |i| health.number_of_nodes = i,
                else => {},
            }
        }
        if (root.get("timed_out")) |v| {
            switch (v) {
                .bool => |b| health.timed_out = b,
                else => {},
            }
        }

        // Transfer body ownership to ClusterHealth — do NOT free response.body.
        return health;
    }

    /// Send a raw HTTP request against the cluster. Low-level escape hatch.
    /// Caller owns the returned `HttpResponse` and must call `deinit()`.
    pub fn rawRequest(
        self: *ESClient,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
    ) !pool.HttpResponse {
        return self.connection_pool.sendRequest(
            self.allocator,
            method,
            path,
            body,
            self.config.compression,
        );
    }
};
