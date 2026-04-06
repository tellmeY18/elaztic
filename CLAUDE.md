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

- [ ] `ScrollIterator` — page through results, auto-clear on `deinit`
- [ ] Point-in-time: `openPit`, `closePit`, search with `search_after`
- [ ] `PitIterator` — preferred over scroll for read-heavy queries
- [ ] Memory cap: never buffer more than one page

Deliverable: Can page through 500K+ concept documents.

---

### M7 — Hardening (weeks 16–17)

- [ ] Node failover and re-add after health check
- [ ] Connection leak detection in tests
- [ ] 429 handling with jitter backoff
- [ ] TLS support (`std.crypto.tls`)
- [ ] HTTP Basic auth + API key auth
- [ ] Structured logging hooks (caller-provided function)
- [ ] Memory leak audit with `GeneralPurposeAllocator`

---

### M8 — Polish + Publishing (weeks 18–20)

- [ ] Full doc comments on every public symbol
- [ ] README with quickstart and examples
- [ ] `build.zig.zon` for `zig fetch`
- [ ] CI via GitHub Actions (unit tests always, integration tests with ES)
- [ ] Examples: `basic_search.zig`, `bulk_index.zig`, `scroll_large.zig`
- [ ] Publish to pkg.zig.guru

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