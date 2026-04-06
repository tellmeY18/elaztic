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
- `zinc` (ZincSearch binary) for lightweight smoke tests
- `zinc-start` / `zinc-stop` / `zinc-status` helper scripts
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

## Test Backend Strategy

There are two tiers of test backend. Use the right one for each milestone.

### Tier 1 — ZincSearch (smoke tests, M1–M2)

ZincSearch (`zincsearch`) is available directly in the dev shell. It's a single
Go binary, starts in under a second, uses ~50MB RAM, and requires zero config.

**Important caveat:** ZincSearch is NOT a true Elasticsearch drop-in.
Its ES-compatible query API (`/es` endpoints) is explicitly "work in progress"
and does not implement the full ES Query DSL. Use it only to validate:
- Basic HTTP transport (M1): can we connect, ping, get a response?
- JSON round-trips (M2): do our serialize/deserialize types work?
- Simple index/get/delete (early M4): do basic CRUD shapes work?

Do NOT use ZincSearch to validate: nested bool queries, `terms` over large
arrays, scroll, PIT, aggregations, index mappings, or anything M3+ depends on.
It will either fail silently or return subtly wrong results.

**Starting ZincSearch:**
```
zinc-start      # starts on port 4080, data in .zinc-data/
zinc-stop       # stops it
zinc-status     # check if running
```

ZincSearch UI is available at http://localhost:4080 when running.
Default credentials: `admin` / `Complexpass#123`

ZincSearch uses port **4080**, not 9200. Set `ES_URL=http://localhost:4080`
and `ES_AUTH=admin:Complexpass#123` when running smoke tests against it.

### Tier 2 — Real Elasticsearch (integration tests, M3+)

From M3 (Query DSL) onward, all integration tests must run against a real
Elasticsearch 8.x instance. The dev shell provides a `just es-start` command
that launches ES via Docker (Docker must be installed separately — it is not
managed by Nix here).

```
just es-start    # docker run ES 8.x on port 9200, security disabled
just es-stop     # stop and remove the container
just es-logs     # tail ES logs
```

Set `ES_URL=http://localhost:9200` for integration tests against real ES.
Integration tests are skipped automatically if `ES_URL` is not set.

**Why not ES in Nix directly?** Elasticsearch changed its license to SSPL in
2021, which is not OSI-approved. nixpkgs dropped it. The Docker image is the
pragmatic path for local dev. CI uses the official Docker image too.

**OpenSearch as an alternative:** If you prefer to avoid Docker or want a
fully Nix-managed setup, OpenSearch (the Apache 2.0 ES fork) is available as
`pkgs.opensearch` in nixpkgs and is wire-compatible with ES 7.10. Add it to
the flake if needed.

**Per-test index isolation:** Every integration test creates a fresh index
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
│   ├── smoke/                # Against ZincSearch (M1-M2, no ES needed)
│   └── integration/          # Against real ES 8.x (M3+)
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
**Test backend: ZincSearch**

- [ ] `ConnectionPool` — persistent TCP connections, keep-alive, round-robin
- [ ] HTTP/1.1 request serializer and response parser
- [ ] gzip body compression (`std.compress.zlib`)
- [ ] Retry logic with exponential backoff
- [ ] Smoke test: `client.ping()` against ZincSearch on port 4080

Deliverable: `client.ping()` returns a cluster health response.

---

### M2 — JSON Infrastructure (weeks 4–5)
**Test backend: ZincSearch**

- [ ] Comptime struct serializer → ES JSON
- [ ] Comptime JSON deserializer → typed structs
- [ ] `SearchResponse(T)` — generic over `_source` document type
- [ ] `BulkResponse` — parse per-action results
- [ ] `ErrorEnvelope` — parse ES error JSON
- [ ] Unit tests with captured response fixtures (no network)
- [ ] Smoke test: round-trip a struct through ZincSearch index → get

Deliverable: Typed round-trip works against ZincSearch.

---

### M3 — Query DSL (weeks 6–8)
**Test backend: Real Elasticsearch 8.x**

Switch to real ES from this point. ZincSearch's query DSL compatibility
is too incomplete to validate correctness of the query builder.

- [ ] `FieldPath(T)` comptime field accessor with nested path support
- [ ] `Query.term`, `Query.terms`, `Query.bool`, `Query.range`
- [ ] `Query.nested`, `Query.match`, `Query.ids`, `Query.exists`, `Query.prefix`
- [ ] Aggregations: `terms`, `value_count`, `top_hits`
- [ ] Source filtering
- [ ] Unit tests: serialize each query type, diff against expected ES JSON
- [ ] Integration tests against real ES: execute each query, assert hit counts

Deliverable: Full query DSL. Compile-time field validation works.

---

### M4 — Core API Operations (weeks 9–11)
**Test backend: Real Elasticsearch 8.x**

- [ ] `search`, `get`, `index`, `delete`, `count`
- [ ] `createIndex`, `deleteIndex`, `putMapping`, `putAlias`, `refresh`
- [ ] Integration test per operation

Deliverable: Complete CRUD surface.

---

### M5 — Bulk Indexer (weeks 12–13)
**Test backend: Real Elasticsearch 8.x**

- [ ] `BulkIndexer` with flush thresholds (doc count + byte size)
- [ ] NDJSON stream builder (no per-doc allocation)
- [ ] Per-action failure parsing
- [ ] Parallel flush support
- [ ] Benchmark: >50K docs/sec on localhost against real ES

Deliverable: Can drive RF2 import workloads.

---

### M6 — Scroll + PIT (weeks 14–15)
**Test backend: Real Elasticsearch 8.x**

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
- [ ] CI via GitHub Actions (unit tests always, integration tests with ES in Docker)
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

### `zig build test-smoke` (ZincSearch, M1–M2 only)
- Requires `ZINC_URL=http://localhost:4080` and `ZINC_AUTH=admin:Complexpass#123`
- Start with `zinc-start` from dev shell
- Validates transport and basic JSON — not query DSL correctness

### `zig build test-integration` (real ES, M3+)
- Requires `ES_URL=http://localhost:9200`
- Start with `just es-start` (Docker)
- Each test creates and destroys its own UUID-named index
- Skipped automatically if `ES_URL` is unset

---

## Justfile Commands

```
just build          # zig build
just test           # unit tests only
just smoke          # unit + smoke tests (start zinc-start first)
just integration    # all tests including ES integration
just es-start       # docker run ES 8.x on :9200
just es-stop        # stop ES container
just es-logs        # tail ES container logs
just bench          # run throughput benchmarks
just fmt            # zig fmt
just clean          # rm -rf zig-out .zig-cache .zinc-data
```

---

## Key References

- **ES REST API spec:** https://www.elastic.co/docs/api/doc/elasticsearch
- **ES Query DSL:** https://www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl.html
- **ES Bulk API:** https://www.elastic.co/guide/en/elasticsearch/reference/current/docs-bulk.html
- **ES PIT API:** https://www.elastic.co/guide/en/elasticsearch/reference/current/point-in-time-api.html
- **ZincSearch ES-compat docs:** https://zincsearch-docs.zinc.dev/api-es-compatible/
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
