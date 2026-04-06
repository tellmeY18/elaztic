//! ElasticRequest tagged union for all Elasticsearch operations.
//!
//! This union represents all possible operations that can be executed against
//! an Elasticsearch cluster. Each variant contains the specific request data
//! for that operation type.

/// Placeholder for search request (to be implemented in M3).
pub const SearchRequest = struct {};

/// Placeholder for bulk request (to be implemented in M5).
pub const BulkRequest = struct {};

/// Placeholder for create index request (to be implemented in M4).
pub const CreateIndexRequest = struct {};

/// Placeholder for delete index request (to be implemented in M4).
pub const DeleteIndexRequest = struct {};

/// Placeholder for get document request (to be implemented in M4).
pub const GetRequest = struct {};

/// Placeholder for delete document request (to be implemented in M4).
pub const DeleteRequest = struct {};

/// Placeholder for scroll request (to be implemented in M6).
pub const ScrollRequest = struct {};

/// Placeholder for clear scroll request (to be implemented in M6).
pub const ClearScrollRequest = struct {};

/// Placeholder for point-in-time open request (to be implemented in M6).
pub const PitOpenRequest = struct {};

/// Placeholder for point-in-time close request (to be implemented in M6).
pub const PitCloseRequest = struct {};

/// Placeholder for put mapping request (to be implemented in M4).
pub const PutMappingRequest = struct {};

/// Placeholder for refresh request (to be implemented in M4).
pub const RefreshRequest = struct {};

/// Placeholder for count request (to be implemented in M4).
pub const CountRequest = struct {};

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
    /// Refresh index operation.
    refresh: RefreshRequest,
    /// Count operation.
    count: CountRequest,
};
