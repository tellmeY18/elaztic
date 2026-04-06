//! Error types and handling for Elasticsearch operations.
//!
//! Defines the comprehensive error set for ES operations, with retry logic
//! for transient errors (429, 503) and no retries for client errors (4xx except 429).

/// Elasticsearch-specific errors.
/// These map to common ES error conditions and HTTP status codes.
pub const ESError = error{
    /// Connection could not be established (e.g., network unreachable).
    ConnectionRefused,
    /// Connection timed out.
    ConnectionTimeout,
    /// Request timed out on the server side.
    RequestTimeout,
    /// Rate limited (HTTP 429).
    TooManyRequests,
    /// Index does not exist (HTTP 404).
    IndexNotFound,
    /// Document does not exist (HTTP 404).
    DocumentNotFound,
    /// Version conflict in update operations (HTTP 409).
    VersionConflict,
    /// Mapping conflict (HTTP 400).
    MappingConflict,
    /// Shard failure (HTTP 500+).
    ShardFailure,
    /// Cluster is unavailable (HTTP 503).
    ClusterUnavailable,
    /// Unexpected HTTP response status.
    UnexpectedResponse,
    /// Malformed JSON in response.
    MalformedJson,
};

/// Check if an error should trigger a retry.
/// Retries on 429 (TooManyRequests) and 503 (ClusterUnavailable).
/// Never retries on 4xx errors except 429.
pub fn shouldRetry(err: ESError) bool {
    return switch (err) {
        .TooManyRequests, .ClusterUnavailable => true,
        else => false,
    };
}
