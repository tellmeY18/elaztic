//! elaztic — Zig Elasticsearch Client Library
//!
//! A production-grade Elasticsearch client for Zig, targeting ES 7.x and 8.x
//! over HTTP/1.1. Designed for the Snowstorm SNOMED CT terminology server.

const std = @import("std");

/// Elasticsearch client for managing connections and executing requests.
pub const ESClient = @import("client.zig").ESClient;

/// Configuration for the Elasticsearch client.
pub const ClientConfig = @import("client.zig").ClientConfig;

/// Cluster health response from a ping.
pub const ClusterHealth = @import("client.zig").ClusterHealth;

/// Tagged union representing all possible Elasticsearch operations.
pub const ElasticRequest = @import("request.zig").ElasticRequest;

/// Error types specific to Elasticsearch operations.
pub const ESError = @import("error.zig").ESError;

/// Connection pool for managing HTTP connections with round-robin node selection.
pub const ConnectionPool = @import("pool.zig").ConnectionPool;

/// HTTP response returned by the transport layer.
pub const HttpResponse = @import("pool.zig").HttpResponse;

/// Bulk API response types and parsing.
pub const bulk = @import("api/bulk.zig");

/// Parsed response from the Elasticsearch bulk API.
pub const BulkResponse = bulk.BulkResponse;

/// Result of a single action in a bulk response.
pub const BulkItemResult = bulk.BulkItemResult;

/// Parse a raw JSON bulk response body into a `BulkResponse`.
pub const parseBulkResponse = bulk.parseBulkResponse;

/// Comptime JSON serializer pre-configured for Elasticsearch conventions.
pub const serialize = @import("json/serialize.zig");

/// Comptime JSON deserializer pre-configured for Elasticsearch response conventions.
pub const deserialize = @import("json/deserialize.zig");

/// A single Elasticsearch node endpoint.
pub const Node = @import("pool.zig").Node;

test {
    // Ensure all public modules compile.
    std.testing.refAllDecls(@This());
}
