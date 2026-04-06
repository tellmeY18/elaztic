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

/// Index management request/response types (create, delete, refresh, mapping, alias).
pub const index_mgmt = @import("api/index_mgmt.zig");

/// Request to create an Elasticsearch index.
pub const CreateIndexRequest = index_mgmt.CreateIndexRequest;

/// Request to delete an Elasticsearch index.
pub const DeleteIndexRequest = index_mgmt.DeleteIndexRequest;

/// Request to refresh an Elasticsearch index.
pub const RefreshRequest = index_mgmt.RefreshRequest;

/// Request to update mappings on an existing index.
pub const PutMappingRequest = index_mgmt.PutMappingRequest;

/// Request to add an alias for an index.
pub const PutAliasRequest = index_mgmt.PutAliasRequest;

/// Settings for index creation (shard and replica counts).
pub const IndexSettings = index_mgmt.IndexSettings;

/// Document CRUD request/response types (index, get, delete).
pub const document = @import("api/document.zig");

/// Request to index (create/update) a document.
pub const IndexDocRequest = document.IndexDocRequest;

/// Request to get a document by ID.
pub const GetDocRequest = document.GetDocRequest;

/// Request to delete a document by ID.
pub const DeleteDocRequest = document.DeleteDocRequest;

/// Response from an index document request.
pub const IndexDocResponse = document.IndexDocResponse;

/// Response from a delete document request.
pub const DeleteDocResponse = document.DeleteDocResponse;

/// Response from a get document request, generic over the `_source` document type.
pub const GetDocResponse = document.GetDocResponse;

/// Options for indexing a document.
pub const IndexDocOptions = document.IndexDocOptions;

/// Search and count request/response types.
pub const search = @import("api/search.zig");

/// Request to search an Elasticsearch index.
pub const SearchRequest = search.SearchRequest;

/// Options for building a search request.
pub const SearchOptions = search.SearchOptions;

/// Request to count documents in an Elasticsearch index.
pub const CountRequest = search.CountRequest;

/// Response from a count request.
pub const CountResponse = search.CountResponse;

/// Bulk API response types and parsing.
pub const bulk = @import("api/bulk.zig");

/// Parsed response from the Elasticsearch bulk API.
pub const BulkResponse = bulk.BulkResponse;

/// Result of a single action in a bulk response.
pub const BulkItemResult = bulk.BulkItemResult;

/// Parse a raw JSON bulk response body into a `BulkResponse`.
pub const parseBulkResponse = bulk.parseBulkResponse;

/// Bulk indexer for batching documents and flushing to the _bulk endpoint.
pub const bulk_indexer = @import("api/bulk_indexer.zig");

/// Bulk indexer that batches documents and auto-flushes on thresholds.
pub const BulkIndexer = bulk_indexer.BulkIndexer;

/// Configuration for the bulk indexer (max_docs, max_bytes thresholds).
pub const BulkConfig = bulk_indexer.BulkConfig;

/// Result of a bulk flush operation.
pub const BulkResult = bulk_indexer.BulkResult;

/// Scroll API types and iterator.
pub const scroll = @import("api/scroll.zig");

/// Initial scroll search request type.
pub const ScrollSearchRequest = scroll.ScrollSearchRequest;

/// Request to fetch the next page of scroll results.
pub const ScrollNextRequest = scroll.ScrollNextRequest;

/// Request to clear a scroll context.
pub const ClearScrollRequest = scroll.ClearScrollRequest;

/// Scroll search response, generic over the document type.
pub const ScrollSearchResponse = scroll.ScrollSearchResponse;

/// Iterator that pages through scroll results one page at a time.
pub const ScrollIterator = scroll.ScrollIterator;

/// PIT (Point-in-Time) API types and iterator.
pub const pit = @import("api/pit.zig");

/// Request to open a point-in-time.
pub const PitOpenRequest = pit.PitOpenRequest;

/// Response from opening a point-in-time.
pub const PitOpenResponse = pit.PitOpenResponse;

/// Request to close a point-in-time.
pub const PitCloseRequest = pit.PitCloseRequest;

/// Request to search with a PIT context.
pub const PitSearchRequest = pit.PitSearchRequest;

/// Sort field specification for PIT searches.
pub const SortField = pit.SortField;

/// PIT search response, generic over the document type.
pub const PitSearchResponse = pit.PitSearchResponse;

/// A single hit in a PIT search response (includes sort values).
pub const PitHit = pit.PitHit;

/// Iterator that pages through PIT results using search_after.
pub const PitIterator = pit.PitIterator;

/// Query DSL builder — comptime-validated, composable query construction.
pub const query = struct {
    pub const Query = @import("query/builder.zig").Query;
    pub const BoolOpts = @import("query/builder.zig").BoolOpts;
    pub const RangeBuilder = @import("query/builder.zig").RangeBuilder;
    pub const TermValue = @import("query/builder.zig").TermValue;
    pub const TermsValues = @import("query/builder.zig").TermsValues;
    pub const RangeValue = @import("query/builder.zig").RangeValue;

    /// Comptime-validated field path accessor.
    pub const FieldPath = @import("query/field.zig").FieldPath;
    /// Validates at compile time that `name` exists on struct type `T`.
    pub const field = @import("query/field.zig").field;

    /// Aggregation DSL for terms, value_count, top_hits, and nested sub-aggregations.
    pub const Aggregation = @import("query/aggregation.zig").Aggregation;

    /// Source filtering for controlling `_source` field in search results.
    pub const SourceFilter = @import("query/source_filter.zig").SourceFilter;
};

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
