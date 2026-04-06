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

- [ ] `search`, `get`, `index`, `delete`, `count`
- [ ] `createIndex`, `deleteIndex`, `putMapping`, `putAlias`, `refresh`
- [ ] Integration test per operation

Deliverable: Complete CRUD surface.

---

### M5 — Bulk Indexer (weeks 12–13)
**Test backend: Elasticsearch (OpenSearch)**

- [ ] `BulkIndexer` with flush thresholds (doc count + byte size)
- [ ] NDJSON stream builder (no per-doc allocation)
- [ ] Per-action failure parsing
- [ ] Parallel flush support
- [ ] Benchmark: >50K docs/sec on localhost against real ES

Deliverable: Can drive RF2 import workloads.

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