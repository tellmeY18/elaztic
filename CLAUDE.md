# CLAUDE.md — Zig Elasticsearch Client (`elaztic`)

## Project Overview

This project builds a production-grade Elasticsearch client library in Zig,
designed as a prerequisite for a larger Snowstorm SNOMED CT terminology server
rewrite. The client should be a first-class standalone open-source library —
not a throwaway internal tool.

**Design north star:** Take architectural inspiration from
`lambdaworks/zio-elasticsearch` (typed field accessors, ADT request model,
streaming separation) but implemented idiomatically in Zig using `comptime`
instead of runtime reflection.

**Target:** Elasticsearch 7.x and 8.x. HTTP/1.1 only (no HTTP/2 needed).
**Zig version:** Track latest stable release (pinned via `zig-overlay` in flake).

---

## Dev Environment

This project uses **Nix flakes** for a fully reproducible dev environment.
The flake is at the root of the repo (`flake.nix`).

**Entering the dev shell:**
```
nix develop          # stable Zig (default)
nix develop .#nightly  # Zig nightly/master
nix develop .#ci       # minimal, for automation
```

**What the dev shell provides:**
- Zig (stable or nightly depending on shell)
- ZLS (Zig Language Server)
- `just` task runner
- `opensearch` (from nixpkgs, Apache 2.0 licensed)
- `es-start` / `es-stop` / `es-status` helper scripts
- `git`, `pkg-config`
- Platform debugger: `gdb` + `valgrind` on Linux, `lldb` on macOS

**Never install Zig or ZLS globally** — always use `nix develop`. This ensures
every contributor is on the exact same toolchain version.

**Building:**
```
zig build                    # debug build
zig build -Doptimize=ReleaseSafe   # release build
nix build                    # build via Nix (reproducible)
```

---

## Test Backend — Elasticsearch (OpenSearch)

All tests (smoke and integration) run against OpenSearch, which is available
as `pkgs.opensearch` from nixpkgs. OpenSearch is the Apache 2.0 licensed fork
of Elasticsearch, wire-compatible with the ES 7.x REST API. It is fully
managed by Nix — no Docker required.

**Starting OpenSearch:**
```
es-start       # starts OpenSearch on port 9200, data in .opensearch-data/
es-stop        # stops it
es-status      # check if running
```

Set `ES_URL=http://localhost:9200` when running tests.
Tests are skipped automatically if `ES_URL` is not set.

**Per-test index isolation:** Every test creates a fresh index
with a UUID-based name and tears it down in `defer`. Tests never share indices.

---

## Architecture

```
elaztic/
├── src/
│   ├── root.zig              # Public API surface, re-exports
│   ├── client.zig            # ESClient, connection pool, config
│   ├── pool.zig              # HTTP connection pool (keep-alive)
│   ├── request.zig           # ElasticRequest tagged union
│   ├── query/
│   │   ├── builder.zig       # Comptime query DSL (BoolQuery, TermQuery, etc.)
│   │   ├── field.zig         # Comptime field path accessor (FieldPath(T))
│   │   └── aggregation.zig   # Aggregation DSL
│   ├── api/
│   │   ├── search.zig        # Search request/response types
│   │   ├── bulk.zig          # Bulk indexer
│   │   ├── index.zig         # Index management (create, delete, alias)
│   │   ├── scroll.zig        # Scroll API
│   │   └── pit.zig           # Point-in-time API
│   ├── json/
│   │   ├── serialize.zig     # Comptime JSON serializer (structs → ES JSON)
│   │   └── deserialize.zig   # Comptime JSON deserializer (ES responses → structs)
│   └── error.zig             # Error types and ES error envelope parsing
├── tests/
│   ├── smoke/                # Against Elasticsearch (OpenSearch)
│   └── integration/          # Against Elasticsearch (OpenSearch)
├── examples/
│   ├── basic_search.zig
│   ├── bulk_index.zig
│   └── scroll_large.zig
├── bench/                    # Throughput benchmarks (separate from tests)
├── flake.nix                 # Dev environment — always use this
├── flake.lock
├── justfile                  # Task runner commands
└── build.zig
```

---

## Core Design Decisions

### 1. Comptime Field Paths (the key innovation)

Do NOT use string literals for field names in queries. Use comptime-validated
field paths that fail at compile time if the field doesn't exist.

```zig
pub fn field(comptime T: type, comptime name: []const u8) FieldPath(T) {
    if (!@hasField(T, name)) {
        @compileError("Field '" ++ name ++ "' does not exist on " ++ @typeName(T));
    }
    return .{ .name = name };
}
```

Usage:
```zig
const Concept = struct { id: u64, active: bool, module_id: u64 };

const q = Query.bool(.{
    .must = &.{
        Query.term(field(Concept, "active"), true),
        Query.range(field(Concept, "module_id")).gte(900000000000207008),
    }
});
// field(Concept, "typo") → compile error: Field 'typo' does not exist on Concept
```

### 2. ElasticRequest Tagged Union

All operations are values of a single tagged union, dispatched by a single
`execute` function. This makes the API surface minimal and composable.

```zig
pub const ElasticRequest = union(enum) {
    search: SearchRequest,
    bulk: BulkRequest,
    create_index: CreateIndexRequest,
    delete_index: DeleteIndexRequest,
    get: GetRequest,
    delete: DeleteRequest,
    scroll: ScrollRequest,
    clear_scroll: ClearScrollRequest,
    pit_open: PitOpenRequest,
    pit_close: PitCloseRequest,
    put_mapping: PutMappingRequest,
    refresh: RefreshRequest,
    count: CountRequest,
};
```

### 3. Concurrency Model: Thread Pool + Blocking I/O

No async/await (not stable in Zig). Fixed thread pool with persistent
HTTP/1.1 keep-alive connections per ES node. This is correct for an ES
client — outbound to a small cluster, not inbound fan-out.

```zig
pub const ClientConfig = struct {
    max_connections_per_node: u32 = 10,
    request_timeout_ms: u32 = 30_000,
    retry_on_failure: u32 = 3,
    retry_backoff_ms: u32 = 100,
    compression: bool = true,
};
```

### 3a. HTTP Transport

Use `std.net.TcpStream` directly for the connection pool transport. Do not use `std.http.Client` (no external connection lifecycle control, API instability) or `http.zig` (server-only library, no outbound client API). ES's REST API is pure request/response HTTP/1.1 — framing it by hand in `pool.zig` is ~200 lines and gives the `ConnectionPool` full control over socket acquire/release/reuse.

> **Known issue — `std.http.Client` vs DELETE-with-body (Zig 0.15):**
>
> Elasticsearch uses `DELETE` with a JSON body for several endpoints (clear
> scroll, close PIT, delete by query). Zig's `std.http.Client` has a hard
> `assert(r.method.requestHasBody())` inside `sendBodyUnflushed` (Client.zig
> L924), and `requestHasBody()` returns `false` for `DELETE` (http.zig L38).
> This means calling `req.sendBodyComplete(body)` on a DELETE request panics.
>
> **Workaround in `pool.zig`:** When `sendRequest` detects a body on a method
> where `requestHasBody()` is `false`, it bypasses `sendBodyComplete` and
> instead writes the HTTP request directly to the connection's writer:
>
> 1. Set `req.transfer_encoding = .{ .content_length = payload.len }` so
>    the `content-length` header is emitted by `sendHead`.
> 2. Call the private `sendHead` indirectly — not possible; instead
>    replicate the header-writing logic using `req.connection.?.writer()`.
> 3. Write the body bytes and flush.
> 4. `receiveHead` works normally afterwards because it just reads from
>    the same connection.
>
> This affects: `ClearScrollRequest` (`DELETE /_search/scroll`),
> `PitCloseRequest` (`DELETE /_search/point_in_time`), and any future
> DELETE-with-body endpoint.
>
> Other ES clients (elasticsearch-py, go-elasticsearch, elasticsearch-java)
> use HTTP libraries that allow DELETE with body per RFC 9110 §9.3.5.

### 4. Bulk Indexer

Critical for Snowstorm's RF2 import pipeline. A dedicated `BulkIndexer`
handles batching and flushing — not a thin wrapper over the bulk endpoint.

```zig
pub const BulkConfig = struct {
    max_docs: usize = 1000,
    max_bytes: usize = 5 * 1024 * 1024,  // 5MB
    flush_interval_ms: ?u64 = null,        // null = manual flush only
};
```

### 5. Streaming / Scroll / PIT

The streaming API must yield pages — never buffer a full result set in memory.
Snowstorm ECL queries can return millions of concept IDs.

---

## JSON Strategy

Zig's `std.json` parses to a dynamic `Value` tree — insufficient for typed ES
responses. Build a comptime deserializer layer on top.

Rules:
- Omit null optional fields (ES treats missing and null differently)
- Snake_case field names map 1:1 to ES field names
- SNOMED concept IDs are `u64` — never `i32` or `u32`

---

## Error Handling

Never panic. Return errors up the stack. ES errors have a well-defined JSON
envelope — parse them into typed errors, not raw strings.

```zig
pub const ESError = error{
    ConnectionRefused,
    ConnectionTimeout,
    RequestTimeout,
    TooManyRequests,
    IndexNotFound,
    DocumentNotFound,
    VersionConflict,
    MappingConflict,
    ShardFailure,
    ClusterUnavailable,
    UnexpectedResponse,
    MalformedJson,
};
```

Retry on 429 and 503 with backoff. Never retry 4xx (except 429).

---

## Milestone Plan

### M1 — Transport Layer (weeks 1–3)
**Test backend: Elasticsearch (OpenSearch)**

- [ ] `ConnectionPool` — persistent TCP connections, keep-alive, round-robin
- [ ] HTTP/1.1 request serializer and response parser
- [ ] gzip body compression (`std.compress.zlib`)
- [ ] Retry logic with exponential backoff
- [ ] Smoke test: `client.ping()` against Elasticsearch on port 9200

Deliverable: `client.ping()` returns a cluster health response.

---

### M2 — JSON Infrastructure (weeks 4–5)
**Test backend: Elasticsearch (OpenSearch)**

- [ ] Comptime struct serializer → ES JSON
- [ ] Comptime JSON deserializer → typed structs
- [ ] `SearchResponse(T)` — generic over `_source` document type
- [ ] `BulkResponse` — parse per-action results
- [ ] `ErrorEnvelope` — parse ES error JSON
- [ ] Unit tests with captured response fixtures (no network)
- [ ] Smoke test: round-trip a struct through Elasticsearch index → get

Deliverable: Typed round-trip works against Elasticsearch.

---

### M3 — Query DSL (weeks 6–8)
**Test backend: Elasticsearch (OpenSearch)**

#### Phase 1 — Field Paths (`src/query/field.zig`)
- [ ] `FieldPath` struct holding comptime field name string
- [ ] `field(comptime T, comptime name)` — validates field exists via `@hasField`, returns `FieldPath`
- [ ] Nested path support: `field(Outer, "inner.value")` splits on `.` and walks struct types
- [ ] `@compileError` with human-readable message on invalid field names
- [ ] Unit tests: valid field, invalid field (compile error), nested paths, `u64` fields

#### Phase 2 — Core Query Builders (`src/query/builder.zig`)
- [ ] `Query` namespace with `toJson(allocator)` → `[]u8` on every query type
- [ ] `Query.term(field_name, value)` → `{"term": {"field": value}}`
- [ ] `Query.terms(field_name, values_slice)` → `{"terms": {"field": [...]}}` (large `[]u64` support)
- [ ] `Query.match(field_name, text)` → `{"match": {"field": text}}`
- [ ] `Query.matchAll()` → `{"match_all": {}}`
- [ ] `Query.bool(opts)` with `.must`, `.filter`, `.should`, `.must_not` (each `[]const Query`)
- [ ] `Query.range(field_name)` with `.gt()`, `.gte()`, `.lt()`, `.lte()` chainable builder
- [ ] `Query.exists(field_name)` → `{"exists": {"field": "name"}}`
- [ ] `Query.prefix(field_name, value)` → `{"prefix": {"field": value}}`
- [ ] `Query.ids(id_slice)` → `{"ids": {"values": [...]}}`
- [ ] `Query.nested(path, query)` → `{"nested": {"path": "...", "query": {...}}}`
- [ ] `Query.wildcard(field_name, pattern)` → `{"wildcard": {"field": pattern}}`
- [ ] All queries serialize to `std.json.Value` (object tree) for composability
- [ ] Unit tests per query type: construct → serialize → diff against expected JSON string

#### Phase 3 — Aggregations (`src/query/aggregation.zig`)
- [ ] `Aggregation` namespace with `toJson(allocator)` → `[]u8`
- [ ] `Aggregation.terms(name, field_name, size)` → `{"name": {"terms": {"field": "...", "size": N}}}`
- [ ] `Aggregation.valueCount(name, field_name)` → `{"name": {"value_count": {"field": "..."}}}`
- [ ] `Aggregation.topHits(name, size)` → `{"name": {"top_hits": {"size": N}}}`
- [ ] Sub-aggregation nesting: `.subAggs(child_agg)` for terms → top_hits patterns
- [ ] Unit tests per aggregation type

#### Phase 4 — Source Filtering
- [ ] `_source: false` to exclude source entirely
- [ ] `_source: ["field1", "field2"]` include list
- [ ] `_source: {"includes": [...], "excludes": [...]}` full form
- [ ] Integrated into search request body builder
- [ ] Unit tests for each source filtering mode

#### Phase 5 — Integration Tests (`tests/integration/`)
- [ ] `integration_term_query` — index 3 docs, term query on `active=true`, assert hit count
- [ ] `integration_terms_query` — terms query with `[]u64` concept IDs, assert correct docs returned
- [ ] `integration_bool_query` — must + filter combination, verify results
- [ ] `integration_range_query` — range on `module_id` with `.gte()`, verify boundaries
- [ ] `integration_match_query` — full-text match on a `term` field
- [ ] `integration_exists_query` — filter docs with/without optional field
- [ ] `integration_nested_bool` — deeply nested bool with should + must_not
- [ ] `integration_aggregation_terms` — terms agg on `module_id`, verify bucket counts
- [ ] `integration_source_filtering` — search with `_source: ["id"]`, verify only `id` returned
- [ ] Each test creates UUID-named index, indexes docs, refreshes, queries, asserts, deletes index
- [ ] `build.zig` — add `test-integration` step wiring up integration test files

Deliverable: Full query DSL. Compile-time field validation works. All query
types serialize to correct ES JSON. Integration tests pass against OpenSearch.

---

### M4 — Core API Operations (weeks 9–11)
**Test backend: Elasticsearch (OpenSearch)**

#### Phase 1 — Index Management (`src/api/index_mgmt.zig`)
- [ ] `CreateIndexRequest` — index name, optional settings (shards, replicas), optional mappings JSON
- [ ] `DeleteIndexRequest` — index name
- [ ] `RefreshRequest` — index name (or `_all`)
- [ ] `PutMappingRequest` — index name + mapping body (JSON `[]u8`)
- [ ] `PutAliasRequest` — index name + alias name
- [ ] `GetAliasRequest` — alias name, returns list of indices
- [ ] Each request type has a `toHttpRequest()` → method, path, body
- [ ] Unit tests: verify correct HTTP method, path, and body for each

#### Phase 2 — Document CRUD (`src/api/document.zig`)
- [ ] `IndexDocRequest` — index name, optional doc ID, document body (serialized via `serialize.toJson`)
- [ ] `GetDocRequest` — index name + doc ID, returns typed `T` document
- [ ] `DeleteDocRequest` — index name + doc ID
- [ ] `GetDocResponse(T)` — wraps `_index`, `_id`, `_version`, `found`, `_source: T`
- [ ] `IndexDocResponse` — wraps `_index`, `_id`, `_version`, `result` ("created"/"updated")
- [ ] `DeleteDocResponse` — wraps `_index`, `_id`, `_version`, `result` ("deleted"/"not_found")
- [ ] Unit tests: serialize/deserialize round-trips for request/response types

#### Phase 3 — Search & Count (`src/api/search.zig`)
- [ ] `SearchRequest` — index name/pattern, query (`Query`), optional size/from, optional source filter, optional aggs
- [ ] `SearchRequest.toJsonBody(allocator)` → full `{"query": {...}, "size": N, ...}` body
- [ ] `CountRequest` — index name/pattern, optional query
- [ ] `CountResponse` — `count: u64`, `_shards` info
- [ ] Reuse `SearchResponse(T)` from `deserialize.zig` for search results
- [ ] Unit tests: search body serialization with all optional fields

#### Phase 4 — ESClient Execute (`src/client.zig`)
- [ ] `ESClient.execute(request: ElasticRequest)` — dispatch tagged union to HTTP
- [ ] For each variant: compute HTTP method, path, body → call `connection_pool.sendRequest`
- [ ] Parse response: on 2xx → deserialize typed response; on 4xx/5xx → parse `ErrorEnvelope` → return `ESError`
- [ ] Typed return: `search` → `SearchResponse(T)`, `get` → `GetDocResponse(T)`, etc.
- [ ] Convenience methods on `ESClient`:
  - [ ] `search(comptime T, index, query, opts)` → `SearchResponse(T)`
  - [ ] `getDoc(comptime T, index, id)` → `GetDocResponse(T)`
  - [ ] `indexDoc(comptime T, index, doc, opts)` → `IndexDocResponse`
  - [ ] `deleteDoc(index, id)` → `DeleteDocResponse`
  - [ ] `count(index, query)` → `u64`
  - [ ] `createIndex(index, opts)` → `void` (or error)
  - [ ] `deleteIndex(index)` → `void` (or error)
  - [ ] `refresh(index)` → `void`
  - [ ] `putMapping(index, mapping_body)` → `void`
  - [ ] `putAlias(index, alias)` → `void`

#### Phase 5 — Update `request.zig` Tagged Union
- [ ] Replace placeholder structs with real request types from `api/` modules
- [ ] `ElasticRequest` variants carry actual data, not empty structs
- [ ] `ElasticRequest.toHttpMethod()` → `[]const u8`
- [ ] `ElasticRequest.toPath(allocator)` → `[]u8`
- [ ] `ElasticRequest.toBody(allocator)` → `?[]u8`

#### Phase 6 — Integration Tests (`tests/integration/api_integration.zig`)
- [ ] `integration_create_delete_index` — create index with settings, verify exists, delete, verify gone
- [ ] `integration_index_get_doc` — index a Concept doc, get by ID, verify all fields
- [ ] `integration_delete_doc` — index a doc, delete it, verify 404 on get
- [ ] `integration_search_with_query` — index docs, search with term query via client, verify hits
- [ ] `integration_count` — index docs, count with/without query filter
- [ ] `integration_refresh` — index doc, refresh, verify searchable
- [ ] `integration_put_mapping` — create index, add mapping field, verify accepted
- [ ] `integration_put_alias` — create index, add alias, search via alias
- [ ] `integration_index_without_id` — index doc without explicit ID, verify auto-generated ID returned
- [ ] `integration_error_index_not_found` — search on non-existent index, verify `IndexNotFound` error
- [ ] Each test creates UUID-named index, performs operation, asserts, cleans up
- [ ] `build.zig` — add `api_integration.zig` to `test-integration` step

Deliverable: Complete CRUD surface. All operations go through `ESClient.execute` or
typed convenience methods. Error responses parsed into `ESError`. Integration tests
verify every operation against OpenSearch.

---

### M5 — Bulk Indexer (weeks 12–13)
**Test backend: Elasticsearch (OpenSearch)**

#### Phase 1 — BulkIndexer Core (`src/api/bulk_indexer.zig`)
- [ ] `BulkConfig` struct — `max_docs`, `max_bytes`, `flush_interval_ms` thresholds
- [ ] `BulkIndexer` struct — batches documents and flushes to the `_bulk` endpoint
- [ ] `BulkIndexer.init(allocator, client, config)` — creates indexer tied to an `ESClient`
- [ ] `BulkIndexer.deinit()` — frees internal buffer, does NOT auto-flush (caller must flush first)
- [ ] `BulkIndexer.add(index, id, doc)` — serialize doc to JSON, append NDJSON action+source lines
- [ ] `BulkIndexer.addRaw(index, id, json_bytes)` — append pre-serialized JSON (no double-serialize)
- [ ] `BulkIndexer.addDelete(index, id)` — append delete action (no source line)
- [ ] Auto-flush: `add` triggers flush when `max_docs` or `max_bytes` threshold is exceeded
- [ ] `BulkIndexer.flush()` — send buffered NDJSON to `POST /_bulk`, parse `BulkResponse`, reset buffer
- [ ] `BulkIndexer.pendingCount()` — number of buffered actions not yet flushed
- [ ] `BulkIndexer.pendingBytes()` — byte size of the buffered NDJSON payload
- [ ] Flush returns `BulkResult` with `total`, `succeeded`, `failed`, `items` (per-action results)
- [ ] Buffer is a single `ArrayList(u8)` — NDJSON lines appended contiguously, no per-doc allocation
- [ ] Action line format: `{"index":{"_index":"<idx>","_id":"<id>"}}\n` (or `{"delete":...}`)
- [ ] Unit tests: add docs, verify pending counts, verify NDJSON format, verify auto-flush threshold

#### Phase 2 — NDJSON Builder Internals
- [ ] `appendActionLine(writer, action, index, id)` — write the action metadata JSON line
- [ ] `appendSourceLine(writer, json_bytes)` — write the source document JSON line + newline
- [ ] Action types: `index`, `create`, `delete` (update deferred to M7+)
- [ ] NDJSON must end with a trailing newline (ES requirement)
- [ ] No heap allocation per document — all writes go into the shared `ArrayList(u8)` buffer
- [ ] Unit tests: verify NDJSON output matches ES spec for various action types

#### Phase 3 — ESClient Integration
- [ ] `ESClient.bulkIndexer(config)` — convenience to create a `BulkIndexer` bound to this client
- [ ] `BulkIndexer.flush()` uses `ESClient.rawRequest("POST", "/_bulk", ndjson_body)` internally
- [ ] Response body parsed via existing `parseBulkResponse` from `src/api/bulk.zig`
- [ ] On partial failure: `BulkResult.failed > 0` but no error returned (caller inspects items)
- [ ] On transport error: propagate the error from `rawRequest`

#### Phase 4 — BulkResult and Error Reporting
- [ ] `BulkResult` struct — `total: usize`, `succeeded: usize`, `failed: usize`, `took_ms: u64`
- [ ] `BulkResult.items` — optional `[]BulkItemResult` for per-action inspection
- [ ] `BulkResult.hasFailures()` → `bool`
- [ ] `BulkResult.failedItems()` — iterator/slice over only failed items
- [ ] `BulkResult.deinit()` — frees the underlying `BulkResponse` arena
- [ ] Unit tests: verify result counts, hasFailures, failedItems filtering

#### Phase 5 — Integration Tests (`tests/integration/bulk_integration.zig`)
- [ ] `integration_bulk_index_basic` — bulk index 10 docs, flush, verify all created, search to confirm
- [ ] `integration_bulk_auto_flush` — set max_docs=5, add 7 docs, verify auto-flush at 5, manual flush for remaining 2
- [ ] `integration_bulk_mixed_actions` — mix index + delete actions in one bulk, verify results
- [ ] `integration_bulk_large_batch` — index 1000 docs in one flush, verify count matches
- [ ] `integration_bulk_byte_threshold` — set max_bytes low, verify auto-flush triggers on size
- [ ] `integration_bulk_empty_flush` — flush with no pending docs, verify no error and 0 results
- [ ] `integration_bulk_partial_failure` — index to a read-only index or with bad mapping, verify partial failures reported
- [ ] Each test creates UUID-named index, performs operations, asserts, cleans up
- [ ] `build.zig` — add `bulk_integration.zig` to `test-integration` step

#### Phase 6 — Benchmarks (`bench/bulk_bench.zig`)
- [ ] Benchmark harness: index N docs via `BulkIndexer`, measure wall-clock time
- [ ] Target: >50K docs/sec on localhost against OpenSearch
- [ ] Configurable: doc count, batch size, doc size
- [ ] Print throughput (docs/sec) and latency (ms per flush)
- [ ] `build.zig` — add `bench` build step

Deliverable: `BulkIndexer` handles batching, NDJSON serialization, auto-flush on
thresholds, and per-action failure reporting. Can drive RF2 import workloads at
>50K docs/sec. Integration tests verify all flush modes against OpenSearch.

---

### M6 — Scroll + PIT (weeks 14–15)
**Test backend: Elasticsearch (OpenSearch)**

#### Phase 1 — Scroll API Types (`src/api/scroll.zig`)
- [x] `ScrollSearchRequest` struct — wraps a `SearchRequest` with `scroll` keep-alive duration (e.g. `"1m"`)
- [x] `ScrollSearchRequest.httpMethod()` → `"POST"`
- [x] `ScrollSearchRequest.httpPath(allocator)` → `"/<index>/_search?scroll=<duration>"`
- [x] `ScrollSearchRequest.httpBody(allocator)` → delegates to inner `SearchRequest.httpBody()`
- [x] `ScrollNextRequest` struct — holds `scroll_id: []const u8` and `scroll: []const u8` (keep-alive)
- [x] `ScrollNextRequest.httpMethod()` → `"POST"`
- [x] `ScrollNextRequest.httpPath(allocator)` → `"/_search/scroll"`
- [x] `ScrollNextRequest.httpBody(allocator)` → `{"scroll": "<duration>", "scroll_id": "<id>"}`
- [x] `ClearScrollRequest` struct — holds `scroll_id: []const u8`
- [x] `ClearScrollRequest.httpMethod()` → `"DELETE"`
- [x] `ClearScrollRequest.httpPath(allocator)` → `"/_search/scroll"`
- [x] `ClearScrollRequest.httpBody(allocator)` → `{"scroll_id": "<id>"}`
- [x] `ScrollSearchResponse(T)` — extends `SearchResponse(T)` with `_scroll_id: ?[]const u8`
- [x] Unit tests: verify HTTP method, path (with scroll param), body for each request type

#### Phase 2 — ScrollIterator (`src/api/scroll.zig`)
- [x] `ScrollIterator(T)` struct — generic over document type `T`
- [x] Fields: `allocator`, `pool: *ConnectionPool`, `compression: bool`, `scroll_duration`, `scroll_id`, `current_page`, `done: bool`
- [x] `ScrollIterator.init(allocator, pool, compression, index, query, opts, scroll_duration)` — sends initial `_search?scroll=` request, parses first page
- [x] `ScrollIterator.next()` → `?[]const Hit(T)` — returns next page of hits, or `null` when exhausted
- [x] On each `next()`: sends `POST /_search/scroll` with current `scroll_id`, parses response, updates `scroll_id`
- [x] Returns `null` when `hits.hits` is empty (no more results)
- [x] `ScrollIterator.deinit()` — sends `DELETE /_search/scroll` to clear server-side scroll context, frees memory
- [x] Memory cap: only one page of hits is live at a time; previous page is freed on `next()`
- [x] Error handling: transport errors propagate; on `deinit` clear-scroll errors are silently ignored
- [x] Unit tests: mock-free design tests for request construction

#### Phase 3 — PIT API Types (`src/api/pit.zig`)
- [x] `PitOpenRequest` struct — holds `index: []const u8` and `keep_alive: []const u8` (e.g. `"5m"`)
- [x] `PitOpenRequest.httpMethod()` → `"POST"`
- [x] `PitOpenRequest.httpPath(allocator)` → `"/<index>/_search/point_in_time?keep_alive=<duration>"` (OpenSearch-compatible)
- [x] `PitOpenRequest.httpBody(allocator)` → `null` (no body needed)
- [x] `PitOpenResponse` struct — `pit_id: []const u8`
- [x] `PitCloseRequest` struct — holds `pit_id: []const u8`
- [x] `PitCloseRequest.httpMethod()` → `"DELETE"`
- [x] `PitCloseRequest.httpPath(allocator)` → `"/_search/point_in_time"` (OpenSearch-compatible)
- [x] `PitCloseRequest.httpBody(allocator)` → `{"pit_id": "<id>"}`
- [x] `PitSearchRequest` struct — search with PIT context: `pit_id`, `keep_alive`, `query`, `size`, `search_after`, `sort`
- [x] `PitSearchRequest.httpMethod()` → `"POST"`
- [x] `PitSearchRequest.httpPath(allocator)` → `"/_search"` (no index in path when using PIT)
- [x] `PitSearchRequest.httpBody(allocator)` → `{"pit": {"id": "...", "keep_alive": "..."}, "query": {...}, "size": N, "sort": [...], "search_after": [...]}`
- [x] `PitSearchResponse(T)` — extends `SearchResponse(T)` with `pit_id: ?[]const u8` (refreshed PIT ID)
- [x] Unit tests: verify HTTP method, path, body for each request type; verify `search_after` + `sort` serialization

#### Phase 4 — PitIterator (`src/api/pit.zig`)
- [x] `PitIterator(T)` struct — generic over document type `T`, preferred over scroll for read-heavy queries
- [x] Fields: `allocator`, `pool: *ConnectionPool`, `compression: bool`, `pit_id`, `keep_alive`, `sort_fields`, `last_sort_values`, `current_page`, `done: bool`, `page_size: u32`
- [x] `PitIterator.init(allocator, pool, compression, index, query, opts)` — opens PIT via `POST /<index>/_search/point_in_time`, sends initial search, parses first page
- [x] `PitIterator.next()` → `?[]const Hit(T)` — returns next page of hits, or `null` when exhausted
- [x] On each `next()`: extracts `sort` values from last hit of previous page, sends `search_after` search, updates `pit_id` (may be refreshed by ES)
- [x] Returns `null` when `hits.hits` is empty
- [x] `PitIterator.deinit()` — sends `DELETE /_search/point_in_time` to close PIT, frees memory
- [x] Memory cap: only one page of hits is live at a time; previous page is freed on `next()`
- [x] Default sort: `[{"_doc": "asc"}]` (most efficient for full-index scans)
- [x] Error handling: transport errors propagate; on `deinit` close-PIT errors are silently ignored

#### Phase 5 — ESClient Convenience Methods (`src/client.zig`)
- [x] `ESClient.scrollSearch(comptime T, index, query, opts, scroll_duration)` → `ScrollIterator(T)` — convenience to create and initialize a scroll iterator
- [x] `ESClient.openPit(index, keep_alive)` → `[]u8` — open a point-in-time, returns owned pit_id
- [x] `ESClient.closePit(pit_id)` → `void` — close a point-in-time
- [x] `ESClient.pitSearch(comptime T, index, query, page_size, keep_alive)` → `PitIterator(T)` — convenience to create and initialize a PIT iterator
- [x] Update `src/request.zig` — replaced placeholder `ScrollRequest`, `ClearScrollRequest`, `PitOpenRequest`, `PitCloseRequest` with real types from `api/scroll.zig` and `api/pit.zig`
- [x] Update `src/root.zig` — re-exported `ScrollIterator`, `PitIterator`, `ScrollSearchRequest`, `PitOpenRequest`, `PitCloseRequest`, `PitSearchRequest`, and all related types

#### Phase 6 — Integration Tests (`tests/integration/scroll_pit_integration.zig`)
- [x] `integration_scroll_basic` — index 25 docs, scroll with `size=10`, collect all pages, verify 25 total hits across 3 pages
- [x] `integration_scroll_with_query` — index 20 docs (10 active, 10 inactive), scroll with `term(active, true)`, verify only 10 hits
- [x] `integration_scroll_empty_result` — scroll on empty index, verify immediate `null` from `next()`
- [x] `integration_scroll_auto_clear` — scroll through partial results, call `deinit()`, verify scroll context is cleared (no leaked server resources)
- [x] `integration_scroll_single_page` — index 5 docs, scroll with `size=10`, verify all returned in first page, `next()` returns `null`
- [x] `integration_pit_basic` — index 25 docs, PIT iterate with `size=10`, collect all pages, verify 25 total hits
- [x] `integration_pit_with_query` — index 20 docs, PIT iterate with query filter, verify correct subset
- [x] `integration_pit_empty_result` — PIT iterate on empty index, verify immediate `null`
- [x] `integration_pit_auto_close` — iterate partially, call `deinit()`, verify PIT is closed
- [x] `integration_pit_open_close` — open PIT explicitly, verify `pit_id` returned, close PIT, verify no error
- [x] `integration_scroll_large_dataset` — index 500 docs, scroll with `size=50`, verify all 500 retrieved across 10 pages
- [x] Each test creates UUID-named index, indexes docs via `BulkIndexer`, refreshes, iterates, asserts, deletes index
- [x] `build.zig` — added `scroll_pit_integration.zig` to `test-integration` step

Deliverable: `ScrollIterator` and `PitIterator` page through arbitrarily large result
sets without buffering more than one page in memory. Auto-clear/close on `deinit()`
prevents leaked server-side resources. Both iterators use the same `Hit(T)` type from
`SearchResponse`. Integration tests verify pagination, query filtering, empty results,
and resource cleanup against OpenSearch. Can page through 500K+ concept documents.

---

### M7 — Hardening (weeks 16–17)
**Test backend: Elasticsearch (OpenSearch)**

#### Phase 1 — Jittered Exponential Backoff (`src/pool.zig`)
- [x] Replace deterministic `backoff *= 2` with full-jitter: `random(0, min(cap, base * 2^attempt))`
- [x] Add `max_retry_backoff_ms: u32 = 30_000` cap to `ClientConfig` to prevent unbounded growth
- [x] Use `std.crypto.random` for jitter (cryptographically secure, no seed needed)
- [x] Differentiate 429 vs 5xx in retry loop: 429 → `TooManyRequests`, 503 → `ClusterUnavailable`
- [x] On 429, use `Retry-After` header from response if present (seconds), fall back to jittered backoff
- [x] Unit tests: verify backoff values are within expected range, verify cap is respected

#### Phase 2 — Node Health Recovery (`src/pool.zig`)
- [x] Add `dead_since: ?i64 = null` field to `Node` — timestamp (ms) when marked unhealthy
- [x] Add `resurrect_after_ms: u32 = 60_000` to `ClientConfig` — minimum time before retrying a dead node
- [x] In `markUnhealthy`: set `dead_since = std.time.milliTimestamp()`
- [x] In `nextNode`: if all nodes are unhealthy, check if any node's `dead_since + resurrect_after_ms < now`; if so, try that node (give it a chance to recover)
- [x] On successful request to a resurrected node, clear `dead_since` and mark healthy
- [x] Unit tests: verify dead nodes are skipped, verify resurrection after timeout, verify healthy-on-success

#### Phase 3 — Auth Support (`src/pool.zig`, `src/client.zig`)
- [x] Wire existing `ClientConfig.basic_auth` (`"user:password"`) into pool as `Authorization: Basic <base64>` header
- [x] Add `api_key: ?[]const u8 = null` to `ClientConfig` — API key auth (`Authorization: ApiKey <key>`)
- [x] `basic_auth` and `api_key` are mutually exclusive — if both set, `basic_auth` takes precedence
- [x] Auth header is added via `extra_headers` on every request in `sendRequest`
- [x] Base64 encoding uses `std.base64.standard.Encoder`
- [x] Unit tests: verify correct `Authorization` header for basic auth, API key, and no-auth cases

#### Phase 4 — HTTPS / TLS Support (`src/pool.zig`, `src/client.zig`)
- [x] Add `scheme: []const u8 = "http"` to `ClientConfig` (values: `"http"` or `"https"`)
- [x] Use `config.scheme` instead of hardcoded `"http"` in `ConnectionPool.init`
- [x] `std.http.Client` handles TLS natively for `https://` URIs — no extra code needed
- [x] Add `ESClient.initFromUrl(allocator, url_string)` convenience — parses `http://host:port` or `https://host:port` into ClientConfig
- [x] Unit tests: verify URL parsing for http and https schemes

#### Phase 5 — Structured Logging Hooks (`src/pool.zig`, `src/client.zig`)
- [x] Define `LogLevel` enum: `debug`, `info`, `warn`, `err`
- [x] Define `LogEvent` tagged union with variants:
  - `request_start: { method, path }` — before sending
  - `request_success: { method, path, status_code, duration_ms }` — on 2xx
  - `request_retry: { method, path, attempt, status_code, backoff_ms }` — on retryable error
  - `request_error: { method, path, status_code, error_type }` — on non-retryable error
  - `node_unhealthy: { host, port }` — when a node is marked dead
  - `node_recovered: { host, port }` — when a dead node comes back
- [x] Add `log_fn: ?*const fn (LogEvent) void = null` to `ClientConfig`
- [x] Call `log_fn` at appropriate points in `sendRequest` (before request, on success, on retry, on error, on node state change)
- [x] No-op when `log_fn` is `null` — zero overhead in the default case
- [x] Unit tests: verify log events are emitted in correct order for success/retry/error scenarios

#### Phase 6 — Memory Safety Audit
- [x] Verify all integration tests run under `std.testing.allocator` (GPA in debug) — already the case
- [x] Add explicit `std.heap.GeneralPurposeAllocator` usage to the benchmark harness (`bench/bulk_bench.zig`) to catch leaks in hot paths
- [x] Audit `ScrollIterator.deinit()` and `PitIterator.deinit()` for leaks when partially consumed
- [x] Audit `BulkIndexer` for leaks on error paths (flush failure mid-batch)
- [x] Audit `ESClient` convenience methods for leaks when `handleErrorResponse` is called
- [x] Document any known leak-safe patterns in CLAUDE.md conventions section

#### Phase 7 — Integration Tests (`tests/integration/hardening_integration.zig`)
- [x] `integration_basic_auth` — configure client with `basic_auth`, ping cluster, verify success (OpenSearch accepts any auth on unauthenticated clusters)
- [x] `integration_retry_success` — verify client retries and succeeds (index doc, search immediately — tests the retry path naturally)
- [x] `integration_node_failover` — add a fake dead node + real node, verify requests still succeed via the healthy node
- [x] `integration_node_recovery` — mark a node unhealthy, verify it's skipped, wait for resurrect timeout, verify it's retried
- [x] `integration_logging_events` — configure log_fn, perform operations, verify events are emitted
- [x] Each test uses UUID-named index, cleans up after itself
- [x] `build.zig` — add `hardening_integration.zig` to `test-integration` step

Deliverable: Production-ready transport layer with jittered backoff preventing thundering
herd on 429/503, automatic node health recovery, HTTP Basic and API key authentication,
HTTPS support via std.http.Client's native TLS, and structured logging hooks for
observability. All existing tests continue to pass. Memory safety verified under GPA.

---

### M8 — Polish + Publishing (weeks 18–20)

**Goal:** Make `elaztic` a first-class, discoverable, well-documented open-source
Zig package that users can install with a single `zig fetch` command.

**Reference libraries studied:**
- `karlseguin/pg.zig` — README-as-docs pattern, standalone example project,
  `build.zig.zon` structure, API reference inline in README
- `elastic/elasticsearch-rs` — progressive disclosure (zero-config → URL → auth),
  compatibility matrix, module-level doc tutorial, escape-hatch pattern
- zigistry.dev — auto-indexed via GitHub `zig-package` topic

**Current state entering M8:**
- 167 unit tests + 44 integration/smoke tests = 211 total, all passing, zero leaks
- CI already exists (`.github/workflows/ci.yml` + `release.yml`)
- `build.zig.zon` exists but needs version + paths update
- No `README.md`, no `examples/` directory, no `justfile`
- Doc comments already present on most public symbols
- License: AGPL-3.0

---

#### Phase 1 — Doc Comment Audit (`src/**/*.zig`)
- [ ] Audit every `pub` symbol in `src/root.zig` — ensure `///` doc comment present
- [ ] Audit `src/client.zig` — every public method on `ESClient` has `///` with:
  - One-line summary
  - Parameter descriptions (what each arg does, default behaviour)
  - Return value description (what the caller receives, who owns the memory)
  - Error conditions (which errors from `ESError` can be returned and when)
  - Example usage snippet where non-obvious
- [ ] Audit `src/pool.zig` — `ConnectionPool`, `Node`, `HttpResponse`, `LogEvent`, `LogLevel`
- [ ] Audit `src/error.zig` — `ESError` variants, `ErrorEnvelope`, `parseErrorEnvelope`
- [ ] Audit `src/request.zig` — `ElasticRequest` union and all variants
- [ ] Audit `src/api/document.zig` — all request/response types and their methods
- [ ] Audit `src/api/index_mgmt.zig` — all request types and their methods
- [ ] Audit `src/api/search.zig` — `SearchRequest`, `CountRequest`, `SearchOptions`, responses
- [ ] Audit `src/api/bulk.zig` — `BulkResponse`, `BulkItemResult`, `parseBulkResponse`
- [ ] Audit `src/api/bulk_indexer.zig` — `BulkIndexer`, `BulkConfig`, `BulkResult`, all methods
- [ ] Audit `src/api/scroll.zig` — all request/response types, `ScrollIterator` and its methods
- [ ] Audit `src/api/pit.zig` — all request/response types, `PitIterator` and its methods
- [ ] Audit `src/query/builder.zig` — `Query` namespace, every query constructor
- [ ] Audit `src/query/field.zig` — `FieldPath`, `field()` function
- [ ] Audit `src/query/aggregation.zig` — `Aggregation` namespace, all aggregation constructors
- [ ] Audit `src/query/source_filter.zig` — `SourceFilter` and its variants
- [ ] Audit `src/json/serialize.zig` — all public serialization functions
- [ ] Audit `src/json/deserialize.zig` — all public deserialization functions, `TotalHits`, `Hit`, `HitsEnvelope`, `SearchResponse`
- [ ] Add module-level `//!` doc comments to every file that lacks them (one-line summary of what the module provides)
- [ ] Verify: every `deinit()` method documents what memory it frees
- [ ] Verify: every function returning allocated memory documents caller-owns semantics

#### Phase 2 — `root.zig` Module Tutorial
- [ ] Expand the top-level `//!` doc comment in `src/root.zig` into a full tutorial (following the Rust ES client's `lib.rs` pattern):
  - `//! # elaztic` — title
  - `//! ## Overview` — one paragraph: what this library is, what ES versions it targets
  - `//! ## Compatibility` — ES 7.x / 8.x, tested against OpenSearch
  - `//! ## Quick Start` — progressive examples:
    1. Zero-config: `ESClient.init(allocator, .{})` → `ping()`
    2. Custom URL: `ESClient.initFromUrl(allocator, "http://es:9200")`
    3. With auth: `ESClient.init(allocator, .{ .basic_auth = "user:pass" })`
  - `//! ## Query DSL` — comptime field validation example (the key differentiator)
  - `//! ## Bulk Indexing` — `BulkIndexer` example
  - `//! ## Scrolling Large Result Sets` — `ScrollIterator` / `PitIterator`
  - `//! ## Error Handling` — `ESError` switch example, retry semantics
  - `//! ## Memory Ownership` — who owns what, `deinit()` patterns
- [ ] Keep existing re-exports unchanged — only expand the `//!` header

#### Phase 3 — README.md (`README.md`)

The README is the primary documentation surface (Zig ecosystem convention: README = docs).
Follows the `pg.zig` pattern of exhaustive inline API docs.

- [ ] **Header section:**
  - Title: `# elaztic`
  - One-liner: `A production-grade Elasticsearch client library for Zig.`
  - Badges: Zig version, license (AGPL-3.0), CI status, GitHub stars
  - One paragraph: what it is, ES 7.x/8.x target, comptime field validation as key feature
- [ ] **Compatibility section:**
  - Table: elaztic version × ES version × OpenSearch version
  - Note: tested against OpenSearch (Apache 2.0 fork, wire-compatible with ES 7.x REST API)
  - Note: HTTP/1.1 only (no HTTP/2)
  - Note: Zig 0.15.2+ required (tracked via `minimum_zig_version` in `build.zig.zon`)
- [ ] **Install section** (two steps, following pg.zig pattern):
  - Step 1: `zig fetch --save git+https://github.com/<owner>/elaztic`
  - Step 2: `build.zig` snippet showing `b.dependency("elaztic", ...).module("elaztic")`
  - Note about Nix: `nix develop` for reproducible toolchain
- [ ] **Quick Start section** (progressive disclosure, following Rust ES client pattern):
  - Example 1: Connect + ping (zero config, localhost:9200)
  - Example 2: Index a document + get it back
  - Example 3: Search with comptime-validated query DSL
  - Each example is self-contained with imports, `main()`, error handling
- [ ] **Query DSL section** (the key selling point — lead with it prominently):
  - Comptime field path example: `field(Concept, "active")` vs compile error on typo
  - `Query.term`, `Query.bool`, `Query.range`, `Query.match` examples
  - Nested bool query example
  - Aggregation example
  - Source filtering example
- [ ] **Document CRUD section:**
  - `indexDoc` — with and without explicit ID
  - `getDoc` — typed response
  - `deleteDoc`
  - `createIndex` / `deleteIndex` / `refresh` / `putMapping` / `putAlias`
- [ ] **Bulk Indexing section:**
  - `BulkIndexer` lifecycle: init → add → flush → deinit
  - Auto-flush on `max_docs` / `max_bytes` thresholds
  - `BulkResult` inspection: `hasFailures()`, `failedItems()`
  - Performance note: >50K docs/sec target
- [ ] **Scrolling & Point-in-Time section:**
  - `ScrollIterator` example: init → `while (iter.next())` loop → auto-clear on `deinit()`
  - `PitIterator` example: same pattern, preferred for read-heavy queries
  - When to use scroll vs PIT
  - Memory guarantee: one page in memory at a time
- [ ] **Configuration section:**
  - Full `ClientConfig` field reference with defaults
  - `initFromUrl` for URL-based config
  - Auth: `basic_auth` vs `api_key` (mutually exclusive, basic takes precedence)
  - TLS: `scheme = "https"` (std.http.Client handles TLS natively)
  - Retry: `retry_on_failure`, `retry_backoff_ms`, `max_retry_backoff_ms`
  - Node recovery: `resurrect_after_ms`
  - Logging: `log_fn` callback with `LogEvent` variants
  - Compression: `compression = true` (gzip)
- [ ] **Error Handling section:**
  - `ESError` enum — every variant documented with when it occurs
  - Retry semantics: 429 + 503 retried, other 4xx never retried
  - `ErrorEnvelope` — parsed from ES JSON error responses
  - Example: catching `IndexNotFound` vs `VersionConflict`
- [ ] **Memory Ownership section:**
  - Rule: caller owns memory returned by the library
  - `deinit()` patterns: `ESClient`, `ClusterHealth`, `BulkResult`, `ErrorEnvelope`,
    `ScrollIterator`, `PitIterator`
  - Arena allocators: `BulkResponse._arena`, `ErrorEnvelope._arena`
  - All tests run under `std.testing.allocator` (GPA) to catch leaks
- [ ] **Building & Testing section:**
  - `nix develop` — required, never install Zig globally
  - `zig build` / `zig build test` / `zig build test-smoke` / `zig build test-integration`
  - `es-start` / `es-stop` for OpenSearch
  - `ES_URL=http://localhost:9200` environment variable
  - `zig build bench` for throughput benchmarks
- [ ] **License section:**
  - AGPL-3.0 — link to LICENSE file

#### Phase 4 — Examples (`examples/`)

Standalone example project with its own `build.zig` + `build.zig.zon` (following
the pg.zig pattern — proves the library is consumable as a dependency).

- [ ] Create `examples/` directory
- [ ] `examples/build.zig.zon` — standalone manifest declaring `elaztic` as a path dependency:
  ```
  .dependencies = .{ .elaztic = .{ .path = ".." } }
  ```
- [ ] `examples/build.zig` — builds each example as a separate executable, each importing `elaztic`
- [ ] `examples/basic_search.zig` — Complete, runnable example:
  - Connect to localhost:9200
  - Create a UUID-named index
  - Define a `Concept` struct with `id: u64`, `active: bool`, `module_id: u64`, `term: []const u8`
  - Index 5 sample SNOMED-like concepts
  - Refresh the index
  - Search with `Query.bool` + `Query.term(field(Concept, "active"), true)` + `Query.range(field(Concept, "module_id")).gte(900000000000207008)`
  - Print results
  - Delete the index
  - Proper error handling and `defer` cleanup throughout
- [ ] `examples/bulk_index.zig` — Bulk indexing example:
  - Connect to localhost:9200
  - Create index
  - Create `BulkIndexer` with `max_docs = 500`
  - Index 1000 documents in a loop
  - Show auto-flush behaviour
  - Final manual `flush()`
  - Print `BulkResult` stats (total, succeeded, failed, took_ms)
  - Delete index
- [ ] `examples/scroll_large.zig` — Scroll through large result set:
  - Connect to localhost:9200
  - Create index, bulk-index 200 documents
  - Refresh
  - Create `ScrollIterator` with `size = 50`
  - Page through all results, print page count and hit count per page
  - Auto-clear on `deinit()`
  - Also demonstrate `PitIterator` as alternative
  - Delete index
- [ ] Each example has a comment header explaining what it demonstrates
- [ ] Each example compiles and runs standalone: `cd examples && zig build run-basic-search`
- [ ] Verify all examples run against OpenSearch (test manually with `es-start`)

#### Phase 5 — `build.zig.zon` Finalization

- [ ] Update `.version` from `"0.0.0"` to `"0.1.0"` (first public release)
- [ ] Add `"LICENSE"` to `.paths` array (required for package distribution)
- [ ] Add `"README.md"` to `.paths` array (displayed by registries and zig tools)
- [ ] Verify `.minimum_zig_version = "0.15.2"` is correct
- [ ] Verify `.name = .elaztic` matches the module name in `build.zig`
- [ ] Keep `.fingerprint` unchanged (security/trust implications)
- [ ] Remove boilerplate comments from the template (clean up for publishing)
- [ ] Verify `zig fetch --save` works with a local path dependency

#### Phase 6 — `build.zig` Cleanup

- [ ] Remove excessive template comments (keep only comments that add value)
- [ ] Verify module exposure: `b.addModule("elaztic", .{ .root_source_file = b.path("src/root.zig") })`
- [ ] Verify all test steps are wired up: `test`, `test-smoke`, `test-integration`, `bench`
- [ ] Add `test-all` step that depends on `test` + `test-smoke` + `test-integration`
- [ ] Verify examples can be built from the examples directory
- [ ] Ensure `zig build --help` output is clean and descriptive (step names + descriptions)
- [ ] Remove the `exe` (CLI executable) build target — this is a library, not a CLI tool
  - Remove `src/main.zig` executable build
  - Remove `run` step
  - Keep the `exe_tests` if they test anything useful, otherwise remove
  - The `elaztic` module is the only thing consumers import

#### Phase 7 — Justfile

- [ ] Create `justfile` at project root with all commands from CLAUDE.md:
  - `just build` → `zig build`
  - `just test` → `zig build test --summary all`
  - `just smoke` → `zig build test-smoke --summary all` (requires ES_URL)
  - `just integration` → `zig build test-integration --summary all` (requires ES_URL)
  - `just all` → `zig build test-all --summary all` (requires ES_URL)
  - `just es-start` → `es-start`
  - `just es-stop` → `es-stop`
  - `just es-status` → `es-status`
  - `just es-logs` → `tail -f .opensearch.log`
  - `just bench` → `zig build bench`
  - `just fmt` → `zig fmt src/ tests/ bench/ build.zig`
  - `just fmt-check` → `zig fmt --check src/ tests/ bench/ build.zig`
  - `just clean` → `rm -rf zig-out .zig-cache .opensearch-data`
  - `just docs` → `zig build-lib src/root.zig -femit-docs` (if supported)
  - `just loc` → line count summary (`find src/ -name '*.zig' | xargs wc -l`)
- [ ] Add `justfile` to `.paths` in `build.zig.zon`? — No, not needed for package consumers

#### Phase 8 — CI Hardening (`.github/workflows/ci.yml`)

CI already exists and is functional. This phase hardens it.

- [ ] Review `ci.yml` — verify all steps pass on current main branch
- [ ] Add `zig fmt --check` to cover `examples/` directory (currently only `src/ tests/ bench/ build.zig`)
- [ ] Add a dedicated "Examples Build" job:
  - `cd examples && zig build` — verifies examples compile
  - Does NOT run them (they need OpenSearch), but compilation proves the module import works
- [ ] Add build matrix comment documenting what each job does
- [ ] Review `release.yml`:
  - Currently builds a CLI binary — update to package the library tarball instead
  - Or remove binary release entirely (library consumers use `zig fetch`, not binaries)
  - Create a source tarball that matches what `zig fetch` would download
- [ ] Add GitHub Actions badge to README.md: `![CI](https://github.com/<owner>/elaztic/actions/workflows/ci.yml/badge.svg)`
- [ ] Verify Nix cache is working (DeterminateSystems/magic-nix-cache-action)

#### Phase 9 — GitHub Repository Metadata

- [ ] Set GitHub repo description: `Production-grade Elasticsearch client library for Zig. Comptime-validated query DSL. ES 7.x/8.x.`
- [ ] Add GitHub topics: `zig-package`, `elasticsearch`, `opensearch`, `zig`, `search`, `database-client`
  - `zig-package` is required for zigistry.dev auto-indexing
- [ ] Set repository URL in `build.zig.zon` or README (for discoverability)
- [ ] Verify LICENSE file is AGPL-3.0 and properly detected by GitHub
- [ ] Add a `.github/FUNDING.yml` if sponsorship is desired (optional)

#### Phase 10 — Changelog + Version Tag

- [ ] Update `Changelog.md` with M8 section:
  - List all files created/modified
  - Document README creation, examples, build.zig.zon updates
  - Include M8 checklist (following the pattern of M1–M7 entries)
- [ ] Review all milestone entries in Changelog.md for accuracy
- [ ] Add release date to the `[Unreleased]` section header → `[0.1.0] — YYYY-MM-DD`
- [ ] Create git tag `v0.1.0` after all M8 work is merged
- [ ] Verify `release.yml` triggers on the tag push and creates a GitHub Release
- [ ] Write release notes summarizing the full M1–M8 journey:
  - Transport layer with connection pooling and keep-alive
  - Comptime-validated query DSL (the key innovation)
  - Full CRUD operations
  - Bulk indexer with auto-flush (>50K docs/sec)
  - Scroll + PIT iterators for large result sets
  - Production hardening (jittered backoff, node recovery, auth, TLS, logging)
  - 211+ tests, zero memory leaks

#### Phase 11 — Publishing & Discoverability

- [ ] Verify `zig fetch --save git+https://github.com/<owner>/elaztic` works from a fresh project
- [ ] Create a minimal test project that depends on `elaztic` to verify the package is consumable:
  - `zig init`
  - Add dependency
  - `@import("elaztic")` in main.zig
  - `zig build` succeeds
- [ ] zigistry.dev — no action needed beyond adding `zig-package` topic (Phase 9)
  - Zigistry auto-crawls GitHub repos with the `zig-package` topic
  - Verify listing appears after push (may take a few hours)
- [ ] Update CLAUDE.md: replace `pkg.zig.guru` reference with `zigistry.dev`
- [ ] Consider writing a short announcement post (Ziggit forum, Reddit r/zig) — optional

#### Phase 12 — Final Verification

- [ ] `zig build test --summary all` — all 167+ unit tests pass
- [ ] `zig build test-smoke --summary all` — smoke tests pass against OpenSearch
- [ ] `zig build test-integration --summary all` — all 44+ integration tests pass
- [ ] `zig build bench` — bulk benchmark runs, >50K docs/sec on localhost
- [ ] `zig fmt --check src/ tests/ bench/ build.zig` — no formatting issues
- [ ] `cd examples && zig build` — all examples compile
- [ ] `nix build` — reproducible Nix build succeeds
- [ ] `nix flake check` — flake checks pass
- [ ] Zero memory leaks across all test suites (GPA-verified)
- [ ] README renders correctly on GitHub (check images, code blocks, badges)
- [ ] `zig fetch --save` from a clean project succeeds
- [ ] All CLAUDE.md milestone checkboxes are checked

Deliverable: `elaztic` v0.1.0 published as a first-class Zig package. README serves
as comprehensive documentation with progressive quickstart examples, full API reference,
and the comptime field validation story front and center. Standalone examples prove the
library is consumable. `zig fetch --save` works out of the box. Listed on zigistry.dev.
CI validates formatting, unit tests, smoke tests, and integration tests on every push.
211+ tests with zero memory leaks.

---

## Snowstorm-Specific Requirements

**SNOMED concept IDs are `u64`** — they exceed 32-bit range. Never use `i32`
or `u32` for concept/description/relationship IDs anywhere in the codebase.

**Branch-aware query filters** — every ES query gets wrapped with branch
visibility filters. The query DSL must support arbitrary filter injection
without breaking the builder chain.

**Multi-index search** — Snowstorm queries concept, description, and
relationship indices simultaneously. Support index patterns.

**Large ancestor arrays** — SNOMED concept documents contain `[]u64` ancestor
arrays with thousands of entries. The deserializer must handle these without
per-element allocation.

**Large `terms` queries** — ECL produces concept ID sets passed back to ES
as `terms` filters. These can contain tens of thousands of IDs. The query
serializer must handle large `[]u64` slices efficiently.

---

## Testing Strategy

### `zig build test` (unit, always runs)
- Query DSL serialization snapshot tests (no network)
- JSON serialize/deserialize round-trips
- Error envelope parsing against fixtures
- FieldPath compile-error validation

### `zig build test-smoke` (Elasticsearch, M1–M2)
- Requires `ES_URL=http://localhost:9200`
- Start with `es-start` from dev shell
- Validates transport and basic JSON round-trips

### `zig build test-integration` (Elasticsearch, M3+)
- Requires `ES_URL=http://localhost:9200`
- Start with `es-start` from dev shell
- Each test creates and destroys its own UUID-named index
- Skipped automatically if `ES_URL` is unset

---

## Justfile Commands

```
just build          # zig build
just test           # unit tests only
just smoke          # unit + smoke tests (start es-start first)
just integration    # all tests including ES integration
just es-start       # start OpenSearch on :9200 (from nix dev shell)
just es-stop        # stop OpenSearch
just es-status      # check if OpenSearch is running
just es-logs        # tail OpenSearch logs
just bench          # run throughput benchmarks
just fmt            # zig fmt
just clean          # rm -rf zig-out .zig-cache .opensearch-data
```

---

## Key References

- **ES REST API spec:** https://www.elastic.co/docs/api/doc/elasticsearch
- **ES Query DSL:** https://www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl.html
- **ES Bulk API:** https://www.elastic.co/guide/en/elasticsearch/reference/current/docs-bulk.html
- **ES PIT API:** https://www.elastic.co/guide/en/elasticsearch/reference/current/point-in-time-api.html
- **OpenSearch docs:** https://opensearch.org/docs/latest/
- **zio-elasticsearch** (architecture reference): https://github.com/lambdaworks/zio-elasticsearch
- **Snowstorm** (query patterns to support): https://github.com/IHTSDO/snowstorm

---

## Conventions

- All public symbols have doc comments (`///`)
- All allocations are explicit — no hidden allocations in library code
- Caller owns memory returned by the library; `deinit()` is always explicit
- No global state — `ESClient` is the root of all state
- Error sets are exhaustive — no `anyerror` in public API signatures
- Smoke tests are prefixed `smoke_`, integration tests prefixed `integration_`
- Comptime DSL errors use `@compileError` with human-readable messages
- Benchmarks live in `bench/` and are never mixed with correctness tests