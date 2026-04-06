//! Elasticsearch client implementation.
//!
//! Provides the main `ESClient` struct for interacting with Elasticsearch
//! clusters. This is the root of all state — no global state exists.

const std = @import("std");
const pool = @import("pool.zig");
const index_mgmt = @import("api/index_mgmt.zig");
const doc_api = @import("api/document.zig");
const search_api = @import("api/search.zig");
const ser = @import("json/serialize.zig");
const deser = @import("json/deserialize.zig");
const err_mod = @import("error.zig");
const Query = @import("query/builder.zig").Query;
const bulk_indexer = @import("api/bulk_indexer.zig");

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

    // ===================================================================
    // Convenience methods
    // ===================================================================

    /// Create an Elasticsearch index.
    ///
    /// Optionally accepts index settings (shard/replica counts) and/or a raw
    /// JSON mappings body. When neither is provided, Elasticsearch applies its
    /// own defaults.
    pub fn createIndex(self: *ESClient, index: []const u8, opts: struct {
        settings: ?index_mgmt.IndexSettings = null,
        mappings: ?[]const u8 = null,
    }) !void {
        const req = index_mgmt.CreateIndexRequest{
            .index = index,
            .settings = opts.settings,
            .mappings = opts.mappings,
        };
        try self.executeSimple(req);
    }

    /// Delete an Elasticsearch index.
    pub fn deleteIndex(self: *ESClient, index: []const u8) !void {
        try self.executeSimple(index_mgmt.DeleteIndexRequest{ .index = index });
    }

    /// Refresh an Elasticsearch index, making recent changes searchable.
    pub fn refresh(self: *ESClient, index: []const u8) !void {
        try self.executeSimple(index_mgmt.RefreshRequest{ .index = index });
    }

    /// Update mappings on an existing index.
    pub fn putMapping(self: *ESClient, index: []const u8, mapping_body: []const u8) !void {
        try self.executeSimple(index_mgmt.PutMappingRequest{ .index = index, .body = mapping_body });
    }

    /// Add an alias for an index.
    pub fn putAlias(self: *ESClient, index: []const u8, alias: []const u8) !void {
        try self.executeSimple(index_mgmt.PutAliasRequest{ .index = index, .alias = alias });
    }

    /// Index (create/update) a document.
    ///
    /// Serializes `doc` to JSON, sends it to the `_doc` endpoint, and returns
    /// the index-document response with the assigned `_id` and `_version`.
    /// The caller does **not** need to free the returned `IndexDocResponse`
    /// — its string fields are copies owned by `self.allocator`.
    pub fn indexDoc(self: *ESClient, comptime T: type, index: []const u8, doc: T, opts: doc_api.IndexDocOptions) !doc_api.IndexDocResponse {
        const body = try ser.toJson(self.allocator, doc);
        defer self.allocator.free(body);

        const req = doc_api.IndexDocRequest{
            .index = index,
            .id = opts.id,
            .body = body,
        };

        return try self.executeTyped(doc_api.IndexDocResponse, req);
    }

    /// Get a document by ID.
    ///
    /// Returns a `Parsed(GetDocResponse(T))` whose arena owns all memory.
    /// The caller must call `.deinit()` when the result is no longer needed.
    pub fn getDoc(self: *ESClient, comptime T: type, index: []const u8, id: []const u8) !std.json.Parsed(doc_api.GetDocResponse(T)) {
        const req = doc_api.GetDocRequest{ .index = index, .id = id };
        return try self.executeTypedParsed(doc_api.GetDocResponse(T), req);
    }

    /// Delete a document by ID.
    pub fn deleteDoc(self: *ESClient, index: []const u8, id: []const u8) !doc_api.DeleteDocResponse {
        const req = doc_api.DeleteDocRequest{ .index = index, .id = id };
        return try self.executeTyped(doc_api.DeleteDocResponse, req);
    }

    /// Search an index with a query.
    ///
    /// Returns a `Parsed(SearchResponse(T))` whose arena owns all memory.
    /// The caller must call `.deinit()` when the result is no longer needed.
    pub fn searchDocs(self: *ESClient, comptime T: type, index: []const u8, q: ?Query, opts: search_api.SearchOptions) !std.json.Parsed(deser.SearchResponse(T)) {
        const req = search_api.SearchRequest{
            .index = index,
            .query = q,
            .options = opts,
        };
        return try self.executeTypedParsed(deser.SearchResponse(T), req);
    }

    /// Count documents in an index, optionally filtered by a query.
    pub fn count(self: *ESClient, index: []const u8, q: ?Query) !u64 {
        const req = search_api.CountRequest{ .index = index, .query = q };
        const resp = try self.executeTyped(search_api.CountResponse, req);
        return resp.count;
    }

    /// Create a `BulkIndexer` bound to this client's connection pool.
    ///
    /// The returned indexer batches documents and flushes them to the `_bulk`
    /// endpoint when thresholds are exceeded. Call `.deinit()` when done.
    /// The caller should call `.flush()` before `.deinit()` to send any
    /// remaining buffered documents.
    pub fn bulkIndexer(self: *ESClient, config: bulk_indexer.BulkConfig) bulk_indexer.BulkIndexer {
        return bulk_indexer.BulkIndexer.init(
            self.allocator,
            &self.connection_pool,
            self.config.compression,
            config,
        );
    }

    // ===================================================================
    // Internal helpers
    // ===================================================================

    /// Execute a request that expects no meaningful response body (just
    /// success/failure). On 2xx the body is discarded; on 4xx/5xx the
    /// error envelope is parsed and the corresponding `ESError` is returned.
    fn executeSimple(self: *ESClient, req: anytype) !void {
        const path = try req.httpPath(self.allocator);
        defer self.allocator.free(path);

        const body = try req.httpBody(self.allocator);
        defer if (body) |b| self.allocator.free(b);

        const response = try self.connection_pool.sendRequest(
            self.allocator,
            req.httpMethod(),
            path,
            body,
            self.config.compression,
        );

        if (response.status_code >= 200 and response.status_code < 300) {
            self.allocator.free(response.body);
            return;
        }

        return self.handleErrorResponse(response);
    }

    /// Execute a request and deserialize the response body into type `T`.
    ///
    /// Uses `fromJsonLeaky` — all string fields in `T` are copies owned by
    /// `self.allocator`. The caller is responsible for freeing any such
    /// fields if `T` requires it (simple response structs with `?[]const u8`
    /// fields are typically fine to let leak in request-scoped code).
    fn executeTyped(self: *ESClient, comptime T: type, req: anytype) !T {
        const path = try req.httpPath(self.allocator);
        defer self.allocator.free(path);

        const body = try req.httpBody(self.allocator);
        defer if (body) |b| self.allocator.free(b);

        const response = try self.connection_pool.sendRequest(
            self.allocator,
            req.httpMethod(),
            path,
            body,
            self.config.compression,
        );

        if (response.status_code >= 200 and response.status_code < 300) {
            defer self.allocator.free(response.body);
            return deser.fromJsonLeaky(T, self.allocator, response.body) catch {
                return error.MalformedJson;
            };
        }

        return self.handleErrorResponse(response);
    }

    /// Execute a request and return a `Parsed(T)` with arena ownership.
    ///
    /// The caller receives a `std.json.Parsed(T)` whose internal arena owns
    /// every allocation produced during deserialization. Call `.deinit()` to
    /// release all memory at once.
    fn executeTypedParsed(self: *ESClient, comptime T: type, req: anytype) !std.json.Parsed(T) {
        const path = try req.httpPath(self.allocator);
        defer self.allocator.free(path);

        const body = try req.httpBody(self.allocator);
        defer if (body) |b| self.allocator.free(b);

        const response = try self.connection_pool.sendRequest(
            self.allocator,
            req.httpMethod(),
            path,
            body,
            self.config.compression,
        );

        if (response.status_code >= 200 and response.status_code < 300) {
            defer self.allocator.free(response.body);
            return deser.fromJson(T, self.allocator, response.body) catch {
                return error.MalformedJson;
            };
        }

        return self.handleErrorResponse(response);
    }

    /// Handle an error response (4xx/5xx).
    ///
    /// Attempts to parse the response body as an Elasticsearch error envelope.
    /// On success, `parseErrorEnvelope` takes ownership of `response.body`
    /// (the arena frees it). We extract the typed `ESError`, deinit the
    /// envelope, and return the error.
    ///
    /// If parsing fails (malformed body), we free the body ourselves and
    /// return `UnexpectedResponse`.
    fn handleErrorResponse(self: *ESClient, response: pool.HttpResponse) err_mod.ESError {
        var envelope = err_mod.parseErrorEnvelope(self.allocator, response.body) catch {
            // parseErrorEnvelope did NOT consume the body on error — free it.
            self.allocator.free(response.body);
            return error.UnexpectedResponse;
        };
        // envelope's arena now owns the body memory.
        const es_err = envelope.toESError();
        envelope.deinit();
        return es_err;
    }
};
