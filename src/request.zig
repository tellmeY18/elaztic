//! ElasticRequest tagged union for all Elasticsearch operations.
//!
//! This union represents all possible operations that can be executed against
//! an Elasticsearch cluster. Each variant contains the specific request data
//! for that operation type.

const index_mgmt = @import("api/index_mgmt.zig");
const doc_api = @import("api/document.zig");
const search_api = @import("api/search.zig");
const scroll_api = @import("api/scroll.zig");
const pit_api = @import("api/pit.zig");

/// Request to search an Elasticsearch index.
pub const SearchRequest = search_api.SearchRequest;

/// Request to create an Elasticsearch index.
pub const CreateIndexRequest = index_mgmt.CreateIndexRequest;

/// Request to delete an Elasticsearch index.
pub const DeleteIndexRequest = index_mgmt.DeleteIndexRequest;

/// Request to get a document by ID.
pub const GetRequest = doc_api.GetDocRequest;

/// Request to delete a document by ID.
pub const DeleteRequest = doc_api.DeleteDocRequest;

/// Request to index (create/update) a document.
pub const IndexRequest = doc_api.IndexDocRequest;

/// Request to update mappings on an existing index.
pub const PutMappingRequest = index_mgmt.PutMappingRequest;

/// Request to add an alias for an index.
pub const PutAliasRequest = index_mgmt.PutAliasRequest;

/// Request to refresh an index.
pub const RefreshRequest = index_mgmt.RefreshRequest;

/// Request to count documents.
pub const CountRequest = search_api.CountRequest;

/// Placeholder for bulk request (to be implemented in M5).
pub const BulkRequest = struct {};

/// Request for the initial scroll search.
pub const ScrollRequest = scroll_api.ScrollSearchRequest;

/// Request to clear a scroll context.
pub const ClearScrollRequest = scroll_api.ClearScrollRequest;

/// Request to open a point-in-time.
pub const PitOpenRequest = pit_api.PitOpenRequest;

/// Request to close a point-in-time.
pub const PitCloseRequest = pit_api.PitCloseRequest;

/// Tagged union representing all possible Elasticsearch operations.
/// All operations are dispatched through a single `execute` function on ESClient.
pub const ElasticRequest = union(enum) {
    /// Search operation.
    search: SearchRequest,
    /// Bulk indexing operation.
    bulk: BulkRequest,
    /// Create index operation.
    create_index: CreateIndexRequest,
    /// Delete index operation.
    delete_index: DeleteIndexRequest,
    /// Get document operation.
    get: GetRequest,
    /// Delete document operation.
    delete: DeleteRequest,
    /// Index (create/update) document operation.
    index_doc: IndexRequest,
    /// Scroll operation.
    scroll: ScrollRequest,
    /// Clear scroll operation.
    clear_scroll: ClearScrollRequest,
    /// Open point-in-time operation.
    pit_open: PitOpenRequest,
    /// Close point-in-time operation.
    pit_close: PitCloseRequest,
    /// Put mapping operation.
    put_mapping: PutMappingRequest,
    /// Put alias operation.
    put_alias: PutAliasRequest,
    /// Refresh index operation.
    refresh: RefreshRequest,
    /// Count operation.
    count: CountRequest,
};
