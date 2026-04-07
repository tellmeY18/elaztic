# elaztic

A production-grade Elasticsearch client library for Zig.

**Comptime-validated query DSL** — field names are checked at compile time against your document structs. Typos become compile errors, not runtime surprises.

- **Target:** Elasticsearch 7.x / 8.x, OpenSearch 1.x / 2.x
- **Transport:** HTTP/1.1 with persistent keep-alive connections
- **Zig:** 0.15.2+ required

## Install

**Step 1:** Add the dependency:

```sh
zig fetch --save git+https://github.com/tellmeY18/elaztic
```

**Step 2:** Wire it into your `build.zig`:

```zig
const elaztic_dep = b.dependency("elaztic", .{});
const elaztic_mod = elaztic_dep.module("elaztic");
exe.root_module.addImport("elaztic", elaztic_mod);
```

## Quick Start

### Connect and ping

```zig
const elaztic = @import("elaztic");

var client = try elaztic.ESClient.init(allocator, .{});
defer client.deinit();

var health = try client.ping();
defer health.deinit(allocator);
// health.status is "green", "yellow", or "red"
```

### Index a document

```zig
const Concept = struct {
    id: u64,
    active: bool,
    module_id: u64,
    term: []const u8,
};

const doc = Concept{
    .id = 404684003,
    .active = true,
    .module_id = 900000000000207008,
    .term = "Clinical finding",
};

const resp = try client.indexDoc(Concept, "concepts", doc, .{ .id = "404684003" });
// resp._id.? == "404684003", resp.result.? == "created"
```

### Search with comptime-validated queries

```zig
const f = elaztic.query.field;
const Q = elaztic.query.Query;

const q = Q.boolQuery(.{
    .must = &.{
        Q.term(f(Concept, "active").name, true),
    },
    .filter = &.{
        Q.range(f(Concept, "module_id").name).gte(900000000000207008).build(),
    },
});

var result = try client.searchDocs(Concept, "concepts", q, .{ .size = 10 });
defer result.deinit();

for (result.value.hits.hits) |hit| {
    const concept = hit._source.?;
    // concept.id, concept.term, etc.
}
```

> **The key innovation:** `f(Concept, "active")` validates at compile time that the
> `active` field exists on `Concept`. Write `f(Concept, "actve")` and get a compile
> error — not a runtime 400 from Elasticsearch.

## Query DSL

All query types serialize to Elasticsearch-compatible JSON:

| Constructor | ES Query |
|---|---|
| `Query.term(field, value)` | `{"term": {"field": value}}` |
| `Query.terms(field, values)` | `{"terms": {"field": [...]}}` |
| `Query.match(field, text)` | `{"match": {"field": text}}` |
| `Query.matchAll()` | `{"match_all": {}}` |
| `Query.boolQuery(opts)` | `{"bool": {"must": [...], ...}}` |
| `Query.range(field).gte(v).build()` | `{"range": {"field": {"gte": v}}}` |
| `Query.exists(field)` | `{"exists": {"field": "..."}}` |
| `Query.prefix(field, value)` | `{"prefix": {"field": value}}` |
| `Query.ids(values)` | `{"ids": {"values": [...]}}` |
| `Query.nested(path, query)` | `{"nested": {"path": "...", "query": {...}}}` |
| `Query.wildcard(field, pattern)` | `{"wildcard": {"field": pattern}}` |

### Nested bool queries

```zig
const q = Q.boolQuery(.{
    .must = &.{
        Q.term(f(Concept, "active").name, true),
    },
    .should = &.{
        Q.match(f(Concept, "term").name, "finding"),
        Q.prefix(f(Concept, "term").name, "clin"),
    },
    .must_not = &.{
        Q.range(f(Concept, "module_id").name).lt(100000000).build(),
    },
});
```

### Aggregations

```zig
const Aggregation = elaztic.query.Aggregation;

const aggs = &[_]Aggregation{
    Aggregation.termsAgg("by_module", "module_id", 10),
    Aggregation.valueCount("total_active", "id"),
};

var result = try client.searchDocs(Concept, "concepts", null, .{
    .size = 0,
    .aggs = aggs,
});
defer result.deinit();
```

### Source filtering

```zig
const SourceFilter = elaztic.query.SourceFilter;

// Include only specific fields
var result = try client.searchDocs(Concept, "concepts", query, .{
    .source = .{ .includes = &.{ "id", "active" } },
});
defer result.deinit();

// Exclude source entirely
var result2 = try client.searchDocs(Concept, "concepts", query, .{
    .source = .disabled,
});
defer result2.deinit();
```

## Document CRUD

```zig
// Index with explicit ID
const resp = try client.indexDoc(Concept, "concepts", doc, .{ .id = "123" });

// Index with auto-generated ID
const resp2 = try client.indexDoc(Concept, "concepts", doc, .{});
// resp2._id.? contains the auto-generated ID

// Get by ID
var got = try client.getDoc(Concept, "concepts", "123");
defer got.deinit();
if (got.value.found) {
    const concept = got.value._source.?;
}

// Delete by ID
const del = try client.deleteDoc("concepts", "123");
// del.result.? == "deleted" or "not_found"
```

## Index Management

```zig
// Create index with settings
try client.createIndex("my-index", .{
    .settings = .{ .number_of_shards = 1, .number_of_replicas = 0 },
});

// Create index with mappings
try client.createIndex("my-index", .{
    .mappings =
        \\{"properties":{"id":{"type":"long"},"term":{"type":"text"}}}
    ,
});

// Refresh (make recent writes searchable)
try client.refresh("my-index");

// Update mappings (add new fields only)
try client.putMapping("my-index",
    \\{"properties":{"new_field":{"type":"keyword"}}}
);

// Add an alias
try client.putAlias("my-index-v2", "my-index");

// Delete index
try client.deleteIndex("my-index");
```

## Bulk Indexing

The `BulkIndexer` batches documents into NDJSON and flushes to the `_bulk` endpoint. Auto-flushes when `max_docs` or `max_bytes` thresholds are exceeded.

```zig
var indexer = client.bulkIndexer(.{
    .max_docs = 1000,
    .max_bytes = 5 * 1024 * 1024, // 5 MB
});
defer indexer.deinit();

// Add documents — auto-flushes at threshold
for (0..5000) |i| {
    const doc = Concept{ .id = i, .active = true, .module_id = 900000000000207008, .term = "concept" };
    const json = try elaztic.serialize.toJson(allocator, doc);
    defer allocator.free(json);
    try indexer.add("concepts", null, json);
}

// Flush remaining
var result = try indexer.flush();
defer result.deinit();

if (result.hasFailures()) {
    // Inspect result.items for per-action details
}
```

## Scrolling & Point-in-Time

For result sets that don't fit in memory, use iterators that yield one page at a time.

### ScrollIterator

```zig
var iter = try client.scrollSearch(Concept, "concepts", query, .{ .size = 100 }, "1m");
defer iter.deinit(); // auto-clears server-side scroll context

while (try iter.next()) |hits| {
    for (hits) |hit| {
        const concept = hit._source.?;
        // process concept
    }
}
```

### PitIterator (preferred for read-heavy queries)

```zig
var iter = try client.pitSearch(Concept, "concepts", query, 100, "5m");
defer iter.deinit(); // auto-closes PIT

while (try iter.next()) |hits| {
    for (hits) |hit| {
        // process hit
    }
}
```

**When to use which:**
- **Scroll:** Legacy API, holds resources on the server between pages. Good for one-time exports.
- **PIT + search_after:** Preferred. Stateless between pages, better for concurrent readers.

Both iterators guarantee only one page of hits is in memory at a time.

## Configuration

```zig
const config = elaztic.ClientConfig{
    // Connection
    .host = "localhost",       // ES host
    .port = 9200,              // ES port
    .scheme = "http",          // "http" or "https" (TLS handled natively)

    // Authentication (mutually exclusive; basic_auth takes precedence)
    .basic_auth = null,        // "user:password" for HTTP Basic
    .api_key = null,           // API key for Authorization: ApiKey header

    // Connection pool
    .max_connections_per_node = 10,

    // Timeouts and retries
    .request_timeout_ms = 30_000,
    .retry_on_failure = 3,
    .retry_backoff_ms = 100,      // initial backoff (jittered exponential)
    .max_retry_backoff_ms = 30_000, // backoff cap

    // Node health
    .resurrect_after_ms = 60_000,  // retry dead nodes after this interval

    // Compression
    .compression = true,           // gzip request/response bodies

    // Observability
    .log_fn = null,                // optional fn(LogEvent) void callback
};
```

### URL-based initialization

```zig
var client = try elaztic.ESClient.initFromUrl(allocator, "https://es.example.com:9243");
defer client.deinit();
```

### Multi-node cluster

```zig
var client = try elaztic.ESClient.init(allocator, .{});
defer client.deinit();

try client.addNode("http", "es-node-2", 9200);
try client.addNode("http", "es-node-3", 9200);
// Requests are round-robin'd across healthy nodes
```

### Logging

```zig
fn myLogger(event: elaztic.LogEvent) void {
    switch (event) {
        .request_success => |info| {
            std.log.info("{s} {s} → {d} ({d}ms)", .{
                info.method, info.path, info.status_code, info.duration_ms,
            });
        },
        .request_retry => |info| {
            std.log.warn("retry #{d}: {s} {s} → {d}", .{
                info.attempt, info.method, info.path, info.status_code,
            });
        },
        .node_unhealthy => |info| {
            std.log.err("node down: {s}:{d}", .{ info.host, info.port });
        },
        else => {},
    }
}

var client = try elaztic.ESClient.init(allocator, .{ .log_fn = &myLogger });
```

## Error Handling

All operations return errors from the `ESError` set:

| Error | When |
|---|---|
| `ConnectionRefused` | Network unreachable |
| `ConnectionTimeout` | Connection timed out |
| `RequestTimeout` | Server-side timeout |
| `TooManyRequests` | Rate limited (429) — retried automatically |
| `IndexNotFound` | Index does not exist (404) |
| `DocumentNotFound` | Document does not exist (404) |
| `VersionConflict` | Optimistic concurrency conflict (409) |
| `MappingConflict` | Invalid mapping (400) |
| `ShardFailure` | Shard-level failure (500+) |
| `ClusterUnavailable` | Cluster down (503) — retried automatically |
| `UnexpectedResponse` | Unknown error status |
| `MalformedJson` | Unparseable response body |

**Retry semantics:** 429 and 503 are retried with jittered exponential backoff. All other 4xx errors are never retried.

## Memory Ownership

- **Caller owns** all memory returned by the library
- Every type that allocates provides a `deinit()` method
- All tests run under `std.testing.allocator` (GPA in debug) to catch leaks
- **Zero memory leaks** across 211+ tests

Key `deinit()` patterns:
```zig
var client = try ESClient.init(allocator, .{});
defer client.deinit();

var health = try client.ping();
defer health.deinit(allocator);

var search_result = try client.searchDocs(T, index, query, opts);
defer search_result.deinit();

var scroll_iter = try client.scrollSearch(T, index, query, opts, "1m");
defer scroll_iter.deinit();

var bulk_result = try indexer.flush();
defer bulk_result.deinit();
```

## Building & Testing

This project uses **Nix flakes** for a reproducible dev environment. Never install Zig globally.

```sh
nix develop              # enter dev shell with Zig, ZLS, just, OpenSearch

zig build                # build
zig build test --summary all          # unit tests (no network)
zig build test-smoke --summary all    # smoke tests (requires ES)
zig build test-integration --summary all  # integration tests (requires ES)
zig build test-all --summary all      # everything

zig build bench          # throughput benchmarks
```

### OpenSearch (test backend)

```sh
es-start    # start OpenSearch on port 9200
es-stop     # stop OpenSearch
es-status   # check if running
```

Set `ES_URL=http://localhost:9200` when running smoke/integration tests. Tests are skipped automatically if `ES_URL` is not set.

## Compatibility

| elaztic | Elasticsearch | OpenSearch | Zig |
|---|---|---|---|
| 0.1.x | 7.x, 8.x | 1.x, 2.x | 0.15.2+ |

Tested against OpenSearch (Apache 2.0 fork, wire-compatible with the ES 7.x REST API). HTTP/1.1 only.

## License

[AGPL-3.0](LICENSE)