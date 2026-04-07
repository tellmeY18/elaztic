# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-07

### Milestone M8 — Polish + Publishing ✅

**Status: Complete**

#### Added

- **`README.md`** — Comprehensive documentation covering install, quick start,
  query DSL, document CRUD, index management, bulk indexing, scroll/PIT iteration,
  configuration, error handling, and memory ownership. README serves as the primary
  docs surface following Zig ecosystem convention.
- **`examples/` directory** — Standalone example project with its own `build.zig`
  and `build.zig.zon` proving the library is consumable as a dependency:
  - `basic_search.zig` — Connect, index SNOMED concepts, search with comptime query DSL
  - `bulk_index.zig` — Batch-index 500 docs with `BulkIndexer` auto-flush
  - `scroll_large.zig` — Page through 200 docs with `ScrollIterator` and `PitIterator`
- **`justfile`** — Task runner with all dev/test commands (`just build`, `just test`,
  `just smoke`, `just integration`, `just all`, `just es-start`, `just bench`, etc.)
- **`test-all` build step** — Runs unit + smoke + integration tests in one command
- **`examples-build` CI job** — Verifies examples compile on every push
- **Module tutorial in `root.zig`** — Expanded `//!` doc comment with overview,
  compatibility, quick start examples, query DSL, bulk indexing, scrolling,
  error handling, and memory ownership sections

#### Changed

- **`build.zig`** — Cleaned up from 274 lines to 83 lines:
  - Removed all `zig init` template comments
  - Removed CLI executable (`src/main.zig`, `run` step, `exe_tests`)
  - Consolidated integration tests into a loop
  - Added `test-all` step
- **`build.zig.zon`** — Finalized for v0.1.0:
  - Version bumped from `0.0.0` to `0.1.0`
  - Added `LICENSE` and `README.md` to `.paths`
  - Removed all boilerplate template comments
- **`release.yml`** — Converted from cross-compiled binary release to source-only
  GitHub Release (library consumers use `zig fetch`, not binaries). Added
  pre-release test gate running unit + smoke + integration tests.
- **`ci.yml`** — Added `examples-build` job to verify examples compile

#### Removed

- **`src/main.zig`** — CLI executable removed; this is a library, not a CLI tool

#### M8 Checklist

- [x] Doc comment audit — all public symbols have `///` doc comments
- [x] Module tutorial in `root.zig` expanded with full usage guide
- [x] `README.md` created with comprehensive documentation
- [x] `examples/` directory with 3 standalone examples + build system
- [x] `build.zig.zon` finalized (v0.1.0, paths, clean metadata)
- [x] `build.zig` cleaned up (removed CLI, added `test-all`, loop for integration tests)
- [x] `justfile` created with all dev/test commands
- [x] CI hardened (examples build job, release workflow updated)
- [x] Changelog updated with M8 section

#### Deliverable

`elaztic` v0.1.0 prepared for public release. README serves as comprehensive
documentation with progressive quickstart examples, full API reference, and the
comptime field validation story front and center. Standalone examples prove the
library is consumable. `zig fetch --save` works out of the box. CI validates
formatting, unit tests, smoke tests, integration tests, and example compilation.
162+ unit tests with zero memory leaks.

---

### Milestone M7 — Hardening ✅

**Status: Complete**
**Test backend: Elasticsearch (OpenSearch) on port 9200**

#### Added

- **`src/pool.zig`** — Major hardening improvements to the connection pool:
  - **Jittered exponential backoff**: Replaced deterministic `backoff *= 2` with full-jitter
    using `std.crypto.random.intRangeAtMost`. Backoff capped by `max_retry_backoff_ms`
    (default 30s) to prevent unbounded growth. Prevents thundering herd on 429/503.
  - **Node health recovery**: Added `dead_since: ?i64` to `Node` for tracking when a node
    was marked unhealthy. When all nodes are unhealthy, `nextNode()` attempts to resurrect
    the node dead longest (if past `resurrect_after_ms`, default 60s). On successful request,
    `dead_since` is cleared and the node is marked healthy.
  - **Auth support**: Pre-computes `Authorization` header at init time. Supports HTTP Basic
    auth (`Authorization: Basic <base64>`) and API key auth (`Authorization: ApiKey <key>`).
    Basic auth takes precedence when both are set. Header is added to every request via
    `extra_headers`.
  - **HTTPS/TLS support**: Reads `scheme` from config (default `"http"`). Uses it when
    creating the initial node. `std.http.Client` handles TLS natively for `https://` URIs.
  - **Structured logging**: Added `LogEvent` tagged union with 6 variants (`request_start`,
    `request_success`, `request_retry`, `request_error`, `node_unhealthy`, `node_recovered`).
    Optional `log_fn` callback in config — zero overhead when null. Request timing tracked
    via `duration_ms` in success events.
  - **429 vs 5xx differentiation**: Returns `error.TooManyRequests` for 429, `error.ServerError` for 5xx.
  - 10 unit tests (6 new + 4 updated): node resurrection, jitter bounds, auth headers, scheme config, log emission.

- **`src/client.zig`** — New config fields and convenience methods:
  - `ClientConfig` extended with: `api_key`, `scheme`, `max_retry_backoff_ms`,
    `resurrect_after_ms`, `log_fn`.
  - `ESClient.initFromUrl(allocator, url)` — parses `http://host:port` or `https://host:port`
    into ClientConfig. Dupes host/scheme strings so they outlive the input URL.
  - Fixed pre-existing use-after-free in `ping()`: `std.json.Value.jsonParse` hardcodes
    `.alloc_always`, so all strings lived in the parsed arena and became dangling pointers
    after `parsed.deinit()`. Now copies `cluster_name` and `status` strings into the
    client allocator.
  - `ClusterHealth` now owns its string copies (`_name_copy`, `_status_copy`) instead of
    referencing the raw response body.

- **`src/root.zig`** — Re-exports `LogEvent` and `LogLevel`.

- **`tests/integration/hardening_integration.zig`** — M7 integration tests (5 tests):
  - `integration_basic_auth` — client with `basic_auth`, ping + create/delete index + count.
  - `integration_node_failover` — adds fake dead node (192.0.2.1:19200), verifies operations
    succeed via healthy node.
  - `integration_logging_events` — verifies `request_start` and `request_success` events are
    emitted during ping and createIndex.
  - `integration_retry_on_failure` — exercises retry machinery with bulk index, search, count.
  - `integration_scheme_from_config` — explicit `scheme="http"` + `initFromUrl` validation.

- **`build.zig`** — Added `hardening_integration.zig` to `test-integration` step.

#### M7 Checklist

- [x] Jittered exponential backoff with `std.crypto.random`, capped by `max_retry_backoff_ms`
- [x] Node health recovery: `dead_since` timestamp, `resurrect_after_ms`, oldest-dead-first strategy
- [x] HTTP Basic auth: `basic_auth` config → `Authorization: Basic <base64>` header
- [x] API key auth: `api_key` config → `Authorization: ApiKey <key>` header
- [x] Basic auth takes precedence over API key when both set
- [x] HTTPS/TLS: `scheme` config field, `std.http.Client` handles TLS natively
- [x] `ESClient.initFromUrl` — parses URL, dupes host/scheme for correct lifetime
- [x] `LogEvent` tagged union with 6 event variants
- [x] `LogLevel` enum (`debug`, `info`, `warn`, `err`)
- [x] `log_fn` callback in config — zero overhead when null
- [x] Request timing (`duration_ms`) in success events
- [x] 429 → `TooManyRequests`, 5xx → `ServerError` differentiation
- [x] Fixed `ping()` use-after-free: copies strings out of parsed arena
- [x] `ClusterHealth` owns its strings via `_name_copy` / `_status_copy`
- [x] Unit tests: 10 tests (node resurrection, jitter bounds, auth, scheme, logging)
- [x] Integration tests: 5 tests (auth, failover, logging, retry, scheme)
- [x] `build.zig` — `hardening_integration.zig` in `test-integration` step
- [x] Memory safety: zero leaks in all tests (GPA-verified)

#### Deliverable

Production-ready transport layer with jittered backoff preventing thundering herd on 429/503,
automatic node health recovery with oldest-dead-first resurrection, HTTP Basic and API key
authentication, HTTPS support via std.http.Client's native TLS, and structured logging hooks
for observability. Pre-existing use-after-free in `ping()` discovered and fixed during memory
audit. 163 unit tests + 38 integration tests pass with zero memory leaks.

---

### Milestone M6 — Scroll + PIT ✅

**Status: Complete**
**Test backend: Elasticsearch (OpenSearch) on port 9200**

#### Added

- **`src/api/scroll.zig`** — Scroll API types and iterator for paging through large result sets.
  - `ScrollSearchRequest` — initial scroll search (`POST /<index>/_search?scroll=<duration>`).
    Builds the same JSON body as `SearchRequest` (query, size, from, `_source`, aggs).
  - `ScrollNextRequest` — fetch next page (`POST /_search/scroll`).
    Body: `{"scroll":"<duration>","scroll_id":"<id>"}`.
  - `ClearScrollRequest` — clear scroll context (`DELETE /_search/scroll`).
    Body: `{"scroll_id":"<id>"}`.
  - `ScrollSearchResponse(T)` — generic response with `_scroll_id`, `hits: HitsEnvelope(T)`, `took`.
  - `ScrollIterator(T)` — pages through results using a two-page memory strategy:
    - `init()` sends the initial scroll search and parses the first page.
    - `next()` returns the current page's hits (valid until next call), then prefetches the next page.
    - `deinit()` sends `DELETE /_search/scroll` (errors silently ignored) and frees all memory.
    - Uses `previous_page` / `current_page` to keep returned hits alive until the next `next()` call.
    - `scroll_id` is an owned copy — survives parsed response arena frees.
  - 14 unit tests: request method/path/body serialization, response deserialization.

- **`src/api/pit.zig`** — Point-in-Time (PIT) API types and iterator.
  - `PitOpenRequest` — open a PIT (`POST /<index>/_search/point_in_time?keep_alive=<duration>`), no body.
  - `PitOpenResponse` — parses `{"pit_id": "..."}` from the open response.
  - `PitCloseRequest` — close a PIT (`DELETE /_search/point_in_time`).
    Body: `{"pit_id":"<id>"}`.
  - `PitSearchRequest` — search with PIT context (`POST /_search`, no index in path).
    Body includes `pit`, `query`, `size`, `sort`, `search_after`.
    Defaults to `[{"_doc":"asc"}]` sort when none specified.
  - `SortField` — sort specification with `field` and `order` strings.
  - `PitHit(T)` — like `Hit(T)` but with an additional `sort: ?[]const std.json.Value` field
    for `search_after` pagination.
  - `PitHitsEnvelope(T)` — hits envelope with `total`, `hits`, `max_score`.
  - `PitSearchResponse(T)` — response with `pit_id`, `hits`, `took`.
  - `PitIterator(T)` — pages through results using PIT + `search_after`:
    - `init()` opens a PIT, sends the initial search, stores the first page.
    - `next()` returns the current page's hits and prefetches the next page; returns `null` when exhausted.
    - `deinit()` frees all memory and sends a best-effort `DELETE` to close the server-side PIT.
    - PIT ID is updated if the server returns a refreshed one.
    - Only one page of hits is live at a time (previous page freed on next `next()` call).
  - 14 unit tests: request method/path/body serialization, response deserialization.

- **`src/pool.zig`** — Added `sendBodyForMethodWithoutBody` helper for DELETE-with-body.
  Zig 0.15's `std.http.Client` hard-asserts in `sendBodyUnflushed` that the HTTP method
  supports a body (`requestHasBody()` returns `false` for DELETE). Elasticsearch legitimately
  requires DELETE with a JSON body for clear-scroll, close-PIT, and delete-by-query.
  The helper replicates the essential parts of the private `sendHead` function, writing the
  request line, headers (Host, Connection, Accept-Encoding, Content-Length, extra headers),
  body, and flushing directly to the connection's buffered writer. After this call the
  connection is in the correct state for `receiveHead`.

- **`src/client.zig`** — Added 4 convenience methods on `ESClient`:
  - `scrollSearch(comptime T, index, query, opts, scroll_duration)` → `ScrollIterator(T)` —
    creates and initializes a scroll iterator.
  - `openPit(index, keep_alive)` → `[]u8` — opens a PIT, returns the `pit_id` as an owned string.
  - `closePit(pit_id)` → `void` — closes a PIT via DELETE.
  - `pitSearch(comptime T, index, query, page_size, keep_alive)` → `PitIterator(T)` —
    creates and initializes a PIT iterator.

- **`src/request.zig`** — Replaced 4 placeholder structs with real types:
  - `ScrollRequest` → `scroll_api.ScrollSearchRequest`
  - `ClearScrollRequest` → `scroll_api.ClearScrollRequest`
  - `PitOpenRequest` → `pit_api.PitOpenRequest`
  - `PitCloseRequest` → `pit_api.PitCloseRequest`

- **`src/root.zig`** — Re-exports for all new public types:
  `ScrollSearchRequest`, `ScrollNextRequest`, `ClearScrollRequest`, `ScrollSearchResponse`,
  `ScrollIterator`, `PitOpenRequest`, `PitOpenResponse`, `PitCloseRequest`, `PitSearchRequest`,
  `SortField`, `PitSearchResponse`, `PitHit`, `PitIterator`.

- **`tests/integration/scroll_pit_integration.zig`** — M6 integration tests (11 tests):
  - `integration_scroll_basic` — 25 docs, page size 10, expects 3 pages totaling 25 hits.
  - `integration_scroll_with_query` — 20 docs with alternating active, term query filters to 10.
  - `integration_scroll_empty_result` — empty index, `next()` returns null immediately.
  - `integration_scroll_single_page` — 5 docs, page size 10, all fit in one page.
  - `integration_scroll_large_dataset` — 500 docs, page size 50, expects 10 pages.
  - `integration_scroll_auto_clear` — partial consumption then `deinit()` clears scroll context.
  - `integration_pit_open_close` — explicit open/close PIT lifecycle.
  - `integration_pit_basic` — 25 docs, page size 10, collects all via PIT iterator.
  - `integration_pit_with_query` — 20 docs with alternating active, term query filters to 10.
  - `integration_pit_empty_result` — empty index, `next()` returns null immediately.
  - `integration_pit_auto_close` — partial consumption then `deinit()` closes PIT.
  - All tests use `ESClient` directly via `elaztic` module.

- **`build.zig`** — Added `scroll_pit_integration.zig` to `test-integration` step.

- **`CLAUDE.md`** — Documented the `std.http.Client` DELETE-with-body limitation in §3a
  and enriched M6 section with detailed phase-by-phase checklist.

#### M6 Checklist

- [x] `ScrollSearchRequest` with `httpMethod()`, `httpPath()`, `httpBody()` — initial scroll search
- [x] `ScrollNextRequest` — fetch next page with scroll_id
- [x] `ClearScrollRequest` — clear scroll context (`DELETE /_search/scroll` with body)
- [x] `ScrollSearchResponse(T)` — response with `_scroll_id` field
- [x] `ScrollIterator(T)` — two-page memory strategy, auto-clear on `deinit()`
- [x] `ScrollIterator` scroll_id is an owned copy — survives parsed response arena frees
- [x] `PitOpenRequest` — open PIT (OpenSearch-compatible `/_search/point_in_time` path)
- [x] `PitOpenResponse` — parse `pit_id` from response
- [x] `PitCloseRequest` — close PIT (`DELETE /_search/point_in_time` with body)
- [x] `PitSearchRequest` — search with PIT context, `search_after`, `sort`
- [x] `PitSearchResponse(T)` — response with refreshed `pit_id`
- [x] `PitHit(T)` — hit with `sort` values for `search_after` pagination
- [x] `PitIterator(T)` — PIT + search_after pagination, auto-close on `deinit()`
- [x] `SortField` struct — sort specification with field and order
- [x] Default sort `[{"_doc":"asc"}]` for efficient full-index scans
- [x] `sendBodyForMethodWithoutBody` in pool.zig — DELETE-with-body workaround for Zig 0.15
- [x] `ESClient.scrollSearch()` — convenience method
- [x] `ESClient.openPit()` / `closePit()` — explicit PIT lifecycle
- [x] `ESClient.pitSearch()` — convenience method
- [x] `request.zig` — replaced 4 M6 placeholder structs with real types
- [x] `root.zig` — re-exports for all scroll/PIT public types
- [x] Unit tests: 28 tests (14 scroll + 14 PIT) for request/response serialization
- [x] Integration tests: 11 tests (6 scroll + 5 PIT) against OpenSearch
- [x] `build.zig` — `scroll_pit_integration.zig` in `test-integration` step
- [x] Memory safety: zero leaks in all tests (GPA-verified)

#### Deliverable

`ScrollIterator` and `PitIterator` page through arbitrarily large result sets without
buffering more than one page in memory. Auto-clear/close on `deinit()` prevents leaked
server-side resources. Both iterators use the same document type `T` from `SearchResponse`.
Integration tests verify pagination (25 docs across 3 pages, 500 docs across 10 pages),
query filtering, empty results, single-page results, and resource cleanup against OpenSearch.
The DELETE-with-body workaround in pool.zig enables clear-scroll and close-PIT operations
despite Zig 0.15's `std.http.Client` limitation. 153 unit tests + 33 integration tests pass.

---

### Milestone M5 — Bulk Indexer ✅

**Status: Complete**
**Test backend: Elasticsearch (OpenSearch) on port 9200**

#### Added

- **`src/api/bulk_indexer.zig`** — Bulk indexer for batching documents and flushing to `_bulk`.
  - `BulkConfig` struct — `max_docs` (default 1000), `max_bytes` (default 5MB), `flush_interval_ms` (reserved).
  - `BulkIndexer` struct — accumulates NDJSON in a single `ArrayList(u8)` buffer, no per-doc allocation.
  - `BulkIndexer.init(allocator, *ConnectionPool, compression, BulkConfig)` — creates indexer.
  - `BulkIndexer.deinit()` — frees buffer (does NOT auto-flush; caller must flush first).
  - `BulkIndexer.add(comptime T, index, ?id, doc)` — serialize doc to JSON, append NDJSON lines.
    Returns `?BulkResult` if auto-flush was triggered.
  - `BulkIndexer.addRaw(index, ?id, json_bytes)` — append pre-serialized JSON (no double-serialize).
  - `BulkIndexer.addDelete(index, id)` — append delete action (no source line).
  - `BulkIndexer.flush()` — send buffered NDJSON to `POST /_bulk`, parse `BulkResponse`, reset buffer.
  - `BulkIndexer.pendingCount()` / `pendingBytes()` — inspect buffered state.
  - Auto-flush: triggers when `max_docs` or `max_bytes` threshold is exceeded.
  - Action line format: `{"index":{"_index":"<idx>","_id":"<id>"}}\n` (or `{"delete":...}`).
  - NDJSON ends with trailing newline (ES requirement).
  - 10 unit tests: init/deinit, NDJSON format, pending counts, add without ID, mixed actions,
    empty flush, trailing newline, typed doc serialization, BulkResult.hasFailures.

- **`BulkResult`** — Result of a bulk flush operation.
  - `total`, `succeeded`, `failed`, `took_ms` — summary counters.
  - `items: []BulkItemResult` — per-action results for inspection.
  - `hasFailures()` → `bool`.
  - `deinit()` — frees underlying `BulkResponse` arena.

- **`src/client.zig`** — Added `ESClient.bulkIndexer(BulkConfig)` convenience method.
  Returns a `BulkIndexer` bound to the client's connection pool.

- **`src/pool.zig`** — Fixed missing `Content-Type: application/json` header.
  Now automatically sets the header when a request body is present. This fixes
  `ESClient` convenience methods (createIndex, putMapping, etc.) which were failing
  against OpenSearch without the header.

- **`src/root.zig`** — Re-exports `BulkIndexer`, `BulkConfig`, `BulkResult`.

- **`tests/integration/bulk_integration.zig`** — M5 integration tests (6 tests):
  - `integration_bulk_index_basic` — bulk index 10 docs, flush, verify all succeeded, count confirms 10.
  - `integration_bulk_auto_flush` — `max_docs=5`, add 7 docs, auto-flush at 5, manual flush for 2, count 7.
  - `integration_bulk_mixed_actions` — bulk insert 3 + bulk delete 1 + add 1, count stays 3.
  - `integration_bulk_large_batch` — index 1000 docs in one flush, verify all succeeded.
  - `integration_bulk_byte_threshold` — `max_bytes=500`, auto-flush triggers on buffer size.
  - `integration_bulk_empty_flush` — flush with nothing pending, zero result, no error.
  - All tests use `ESClient` directly via `elaztic` module.

- **`bench/bulk_bench.zig`** — Throughput benchmark harness.
  - Indexes 50,000 docs with batch size 1000 against localhost OpenSearch.
  - Reports wall-clock time, ES server time, throughput (docs/sec), avg latency per flush.
  - Verifies final document count via `client.count()`.
  - Debug mode: ~17K docs/sec. ReleaseSafe: ~40K docs/sec.
  - Run with `zig build bench` or `zig build bench -Doptimize=ReleaseSafe`.

- **`build.zig`** — Added `bulk_integration.zig` to `test-integration` step.
  Added `bench` build step for the throughput benchmark executable.

#### M5 Checklist

- [x] `BulkConfig` struct with `max_docs`, `max_bytes`, `flush_interval_ms` thresholds
- [x] `BulkIndexer` with single `ArrayList(u8)` buffer — no per-doc allocation
- [x] `BulkIndexer.add()` — serialize typed doc, append NDJSON action+source lines
- [x] `BulkIndexer.addRaw()` — append pre-serialized JSON
- [x] `BulkIndexer.addDelete()` — delete action (no source line)
- [x] Auto-flush on `max_docs` or `max_bytes` threshold
- [x] `BulkIndexer.flush()` — POST `/_bulk`, parse `BulkResponse`, return `BulkResult`
- [x] `BulkIndexer.pendingCount()` / `pendingBytes()` — inspect state
- [x] NDJSON format: action line + source line + trailing newline
- [x] `BulkResult` with `total`, `succeeded`, `failed`, `took_ms`, `items`, `hasFailures()`, `deinit()`
- [x] `ESClient.bulkIndexer(config)` — convenience method
- [x] `Content-Type: application/json` header fix in `pool.zig`
- [x] Per-action failure parsing via existing `parseBulkResponse`
- [x] Unit tests: NDJSON format, pending counts, empty flush, mixed actions
- [x] Integration tests: 6 tests covering all flush modes against OpenSearch
- [x] Benchmark: 50K docs, ~40K docs/sec in ReleaseSafe
- [x] `build.zig` — `bench` step and `bulk_integration.zig` in `test-integration`

#### Deliverable

`BulkIndexer` handles batching, NDJSON serialization, auto-flush on doc count and byte
size thresholds, and per-action failure reporting. Throughput benchmark achieves ~40K
docs/sec in ReleaseSafe against localhost OpenSearch. Integration tests verify all
flush modes — basic, auto-flush, mixed actions, large batch, byte threshold, empty flush.

---

### Milestone M4 — Core API Operations ✅

**Status: Complete**
**Test backend: Elasticsearch (OpenSearch) on port 9200**

#### Added

- **`src/api/index_mgmt.zig`** — Index management request types.
  - `CreateIndexRequest` — index name, optional `IndexSettings` (shards, replicas), optional mappings JSON.
  - `DeleteIndexRequest` — index name.
  - `RefreshRequest` — index name (or `_all`).
  - `PutMappingRequest` — index name + mapping body (JSON `[]u8`).
  - `PutAliasRequest` — index name + alias name.
  - Each type has uniform `httpMethod()`, `httpPath(allocator)`, `httpBody(allocator)` interface.
  - 21 unit tests: correct HTTP method, path, and body for each request type, including
    settings-only, mappings-only, both, and neither for CreateIndexRequest.

- **`src/api/document.zig`** — Document CRUD request/response types.
  - `IndexDocRequest` — index name, optional doc ID, serialized document body.
    PUT with explicit ID, POST without (auto-generated).
  - `GetDocRequest` — index name + doc ID.
  - `DeleteDocRequest` — index name + doc ID.
  - `GetDocResponse(T)` — generic over `_source` document type, with `_index`, `_id`, `_version`, `found`.
  - `IndexDocResponse` — `_index`, `_id`, `_version`, `result` ("created"/"updated").
  - `DeleteDocResponse` — `_index`, `_id`, `_version`, `result` ("deleted"/"not_found").
  - `IndexDocOptions` — optional doc ID for indexing.
  - 15 unit tests: method/path generation, body duplication, response deserialization from
    JSON fixtures (including SNOMED u64 concept IDs).

- **`src/api/search.zig`** — Search and count request/response types.
  - `SearchRequest` — index name/pattern, optional `Query`, `SearchOptions` (size, from, source filter, aggs).
  - `SearchRequest.httpBody(allocator)` → full `{"query": {...}, "size": N, ...}` body.
  - `CountRequest` — index name/pattern, optional query.
  - `CountResponse` — `count: u64`, optional `ShardsInfo`.
  - 12 unit tests: path, method, body with all combinations of options, count body with/without
    query, CountResponse deserialization.

- **`src/client.zig`** — ESClient convenience methods (10 new public methods).
  - `createIndex(index, opts)` → void (or error).
  - `deleteIndex(index)` → void (or error).
  - `refresh(index)` → void.
  - `putMapping(index, mapping_body)` → void.
  - `putAlias(index, alias)` → void.
  - `indexDoc(comptime T, index, doc, opts)` → `IndexDocResponse`.
  - `getDoc(comptime T, index, id)` → `Parsed(GetDocResponse(T))`.
  - `deleteDoc(index, id)` → `DeleteDocResponse`.
  - `searchDocs(comptime T, index, query, opts)` → `Parsed(SearchResponse(T))`.
  - `count(index, query)` → `u64`.
  - 3 private generic dispatch helpers: `executeSimple`, `executeTyped`, `executeTypedParsed`.
  - `handleErrorResponse` — parses `ErrorEnvelope` → `ESError`, proper body ownership handling.

- **`src/request.zig`** — Replaced placeholder structs with real API types.
  - `ElasticRequest` variants now carry actual request data from `api/` modules.
  - Added `index_doc` and `put_alias` variants.
  - Kept placeholders for M5/M6 types (BulkRequest, ScrollRequest, PitOpenRequest, etc.).

- **`src/root.zig`** — Re-exports all new API types:
  `CreateIndexRequest`, `DeleteIndexRequest`, `RefreshRequest`, `PutMappingRequest`,
  `PutAliasRequest`, `IndexSettings`, `IndexDocRequest`, `GetDocRequest`, `DeleteDocRequest`,
  `IndexDocResponse`, `DeleteDocResponse`, `GetDocResponse`, `IndexDocOptions`,
  `SearchRequest`, `SearchOptions`, `CountRequest`, `CountResponse`.

- **`tests/integration/api_integration.zig`** — M4 integration tests (10 tests):
  - `integration_create_delete_index` — create with settings, verify exists, delete, verify gone.
  - `integration_index_get_doc` — index a Concept doc, GET by ID, verify all fields.
  - `integration_delete_doc` — index a doc, delete it, verify 404 on re-GET.
  - `integration_search_with_query` — index 3 docs, term query, verify 2 hits.
  - `integration_count` — count all (3) and filtered (2) via `_count` endpoint.
  - `integration_refresh` — verify doc not searchable before refresh, searchable after.
  - `integration_put_mapping` — add new keyword field, verify accepted.
  - `integration_put_alias` — create alias, search via alias, verify hits.
  - `integration_index_without_id` — POST without ID, verify auto-generated `_id`.
  - `integration_error_index_not_found` — search nonexistent index, verify 404.
  - Each test creates UUID-named index, performs operation, asserts, cleans up.

- **`build.zig`** — Added `api_integration.zig` to the `test-integration` step.

#### M4 Checklist

- [x] `CreateIndexRequest` with optional settings and mappings (`src/api/index_mgmt.zig`)
- [x] `DeleteIndexRequest` — index name (`src/api/index_mgmt.zig`)
- [x] `RefreshRequest` — index name or `_all` (`src/api/index_mgmt.zig`)
- [x] `PutMappingRequest` — index name + mapping body (`src/api/index_mgmt.zig`)
- [x] `PutAliasRequest` — index name + alias name (`src/api/index_mgmt.zig`)
- [x] `IndexDocRequest` — PUT with ID / POST without, document body (`src/api/document.zig`)
- [x] `GetDocRequest` / `GetDocResponse(T)` — typed document retrieval (`src/api/document.zig`)
- [x] `DeleteDocRequest` / `DeleteDocResponse` (`src/api/document.zig`)
- [x] `IndexDocResponse` — created/updated result (`src/api/document.zig`)
- [x] `SearchRequest` with query, size, from, source filter, aggs (`src/api/search.zig`)
- [x] `CountRequest` / `CountResponse` (`src/api/search.zig`)
- [x] `ESClient.createIndex`, `deleteIndex`, `refresh`, `putMapping`, `putAlias`
- [x] `ESClient.indexDoc`, `getDoc`, `deleteDoc`, `searchDocs`, `count`
- [x] `executeSimple`, `executeTyped`, `executeTypedParsed` generic dispatch helpers
- [x] `handleErrorResponse` — ErrorEnvelope → ESError mapping
- [x] `ElasticRequest` tagged union uses real request types from `api/` modules
- [x] Unit tests: HTTP method, path, body for all request types; response deserialization
- [x] Integration tests: 10 tests covering all CRUD operations against OpenSearch
- [x] `build.zig` — `api_integration.zig` added to `test-integration` step

#### Deliverable

Complete CRUD surface. All operations available through `ESClient` convenience methods
or via typed request structs. Error responses parsed into `ESError` via `ErrorEnvelope`.
10 integration tests verify every operation against OpenSearch — index lifecycle, document
CRUD, search, count, refresh, mappings, aliases, auto-ID, and error handling.

---

### Milestone M3 — Query DSL ✅

**Status: Complete**
**Test backend: Elasticsearch (OpenSearch) on port 9200**

#### Added

- **`src/query/field.zig`** — Comptime-validated field path accessor.
  - `FieldPath` struct holding the dotted field name string for ES JSON serialization.
  - `field(comptime T, comptime name)` — validates field exists via `@hasField`, returns `FieldPath`.
  - Nested path support: `field(Outer, "inner.value")` splits on `.` and walks struct types at comptime.
  - Optional unwrapping: paths walk through `?T` fields automatically.
  - `@compileError` with human-readable messages on invalid fields, empty paths, leading/trailing dots.
  - Unit tests: simple fields, nested paths, nested through optionals, name preservation.

- **`src/query/builder.zig`** — Comptime query DSL builder for Elasticsearch.
  - `Query` tagged union with variants for all query types, composable via `std.json.Value` trees.
  - `Query.term(field_name, value)` → `{"term": {"field": value}}` — supports bool, u64, i64, f64, string.
  - `Query.terms(field_name, values)` → `{"terms": {"field": [...]}}` — handles large `[]u64` slices.
  - `Query.match(field_name, text)` → `{"match": {"field": text}}`.
  - `Query.matchAll()` → `{"match_all": {}}`.
  - `Query.boolQuery(opts)` with `.must`, `.filter`, `.should`, `.must_not` (each `?[]const Query`).
  - `Query.range(field_name)` returns `RangeBuilder` with chainable `.gt()`, `.gte()`, `.lt()`, `.lte()`, `.build()`.
  - `Query.exists(field_name)` → `{"exists": {"field": "name"}}`.
  - `Query.prefix(field_name, value)` → `{"prefix": {"field": value}}`.
  - `Query.ids(values)` → `{"ids": {"values": [...]}}`.
  - `Query.nested(path, query)` → `{"nested": {"path": "...", "query": {...}}}`.
  - `Query.wildcard(field_name, pattern)` → `{"wildcard": {"field": pattern}}`.
  - `toJsonValue(allocator)` → `std.json.Value` tree for composability.
  - `toJson(allocator)` → caller-owned `[]u8` (arena internally for value tree).
  - Comptime value coercion: `toTermValue`, `toTermsValues`, `toRangeValue` handle comptime_int,
    signed/unsigned ints, floats, and strings via `@typeInfo`.
  - 20 unit tests covering every query type, edge cases (negative i64, all range bounds,
    deeply nested bool, all bool clause types).

- **`src/query/aggregation.zig`** — Aggregation DSL for Elasticsearch.
  - `Aggregation` struct with `name`, `agg_type` (tagged union), and optional `sub_aggs`.
  - `Aggregation.termsAgg(name, field_name, size)` → `{"name": {"terms": {"field": "...", "size": N}}}`.
  - `Aggregation.valueCount(name, field_name)` → `{"name": {"value_count": {"field": "..."}}}`.
  - `Aggregation.topHits(name, size)` → `{"name": {"top_hits": {"size": N}}}`.
  - `withSubAggs(sub_aggs)` for nesting aggregations (e.g. terms → top_hits).
  - `aggsToJsonValue(aggs, allocator)` → full `"aggs"` object value.
  - `aggsToJson(aggs, allocator)` → caller-owned `[]u8`.
  - 6 unit tests: each agg type, sub-aggregation nesting, multiple aggs, full round-trip.

- **`src/query/source_filter.zig`** — Source filtering for ES search requests.
  - `SourceFilter` tagged union with three modes:
    - `.disabled` → `"_source": false`
    - `.includes` → `"_source": ["field1", "field2"]`
    - `.full` → `"_source": {"includes": [...], "excludes": [...]}`
  - `toJsonValue(allocator)` and `toJson(allocator)` serialization methods.
  - 6 unit tests: disabled, includes, empty includes, full form, empty full form,
    disabled-no-allocate.

- **`src/root.zig`** — Re-exports query DSL under `pub const query`:
  `Query`, `BoolOpts`, `RangeBuilder`, `TermValue`, `TermsValues`, `RangeValue`,
  `FieldPath`, `field`, `Aggregation`, `SourceFilter`.

- **`tests/integration/query_integration.zig`** — M3 integration tests (6 tests):
  - `integration_term_query` — index 3 docs, term query on `active=true`, assert 2 hits.
  - `integration_terms_query` — terms query with `[]u64` concept IDs, assert 2 hits.
  - `integration_bool_query` — must + filter combination, verify correct count.
  - `integration_range_query` — range on `module_id` with `.gte()`, verify boundaries.
  - `integration_match_all` — matchAll query, assert all 3 docs returned.
  - `integration_exists_query` — filter docs with/without optional field, assert count.
  - Each test creates UUID-named index, indexes docs, refreshes, queries, asserts, deletes index.
  - Tests skip automatically if `ES_URL` is not set.

- **`build.zig`** — Added `test-integration` build step wiring up integration test files.

#### M3 Checklist

- [x] `FieldPath` struct with comptime field name validation (`src/query/field.zig`)
- [x] `field(T, name)` with `@hasField` validation and `@compileError` messages
- [x] Nested path support: splits on `.` and walks struct types, unwraps optionals
- [x] `Query.term` — bool, u64, i64, f64, string values
- [x] `Query.terms` — large `[]u64` slice support
- [x] `Query.match` — full-text match
- [x] `Query.matchAll` — match all documents
- [x] `Query.boolQuery` — must, filter, should, must_not
- [x] `Query.range` — chainable gt/gte/lt/lte via `RangeBuilder`
- [x] `Query.exists` — field existence check
- [x] `Query.prefix` — prefix matching
- [x] `Query.ids` — document ID filtering
- [x] `Query.nested` — nested object queries
- [x] `Query.wildcard` — wildcard pattern matching
- [x] All queries serialize to `std.json.Value` for composability
- [x] `Aggregation.termsAgg`, `valueCount`, `topHits` with sub-aggregation nesting
- [x] `SourceFilter` — disabled, includes, full include/exclude modes
- [x] Unit tests per query type: construct → serialize → diff against expected JSON
- [x] Integration tests against ES: 6 tests, each with index lifecycle
- [x] `build.zig` — `test-integration` step added

#### Deliverable

Full query DSL with compile-time field validation. All query types (term, terms,
match, matchAll, bool, range, exists, prefix, ids, nested, wildcard) serialize to
correct ES JSON. Aggregations (terms, value_count, top_hits) with sub-agg nesting.
Source filtering in all three ES modes. Integration tests pass against OpenSearch.

---

### Milestone M2 — JSON Infrastructure ✅

**Status: Complete**
**Test backend: Elasticsearch (OpenSearch) on port 9200**

#### Added

- **`src/json/serialize.zig`** — Comptime JSON serializer for Elasticsearch, built on `std.json`.
  - `toJson(allocator, value)` — serialize any struct to caller-owned `[]u8`.
  - `toJsonWithOptions(allocator, value, options)` — same with explicit `SerializeOptions`.
  - `toJsonWriter(writer, value)` — stream directly into a writer (zero heap allocation).
  - `SerializeOptions` with `pretty` and `omit_null_optional_fields` knobs.
  - Null optional fields omitted by default (ES treats missing and `null` differently).
  - `u64` values (SNOMED concept IDs) serialize as JSON numbers.
  - Enums serialize as lowercase name strings.
  - Unit tests: all field types, null omission, nested structs, `[]u64` slices, enum fields,
    round-trip verification, writer parity, pretty-print, and explicit-null mode.

- **`src/json/deserialize.zig`** — Comptime JSON deserializer for Elasticsearch responses.
  - `fromJson(T, allocator, json_bytes)` — returns `std.json.Parsed(T)` with arena ownership.
  - `fromJsonLeaky(T, allocator, json_bytes)` — allocates into caller-provided allocator (arena-friendly).
  - Pre-configured with `ignore_unknown_fields = true` and `allocate = .alloc_always`.
  - `SearchResponse(T)` — generic ES `_search` response envelope over document type `T`.
  - `HitsEnvelope(T)` — the `hits` object with `total`, `max_score`, and `hits` array.
  - `Hit(T)` — a single hit with `_index`, `_id`, `_score`, `_source`.
  - `TotalHits` — `total` object with `value` and `relation`.
  - Unit tests: simple struct, unknown fields ignored, optional fields (present/absent/null),
    nested structs, `[]u64` arrays, realistic ES search response, malformed JSON, arena
    allocation, and enum parsing.

- **`src/api/bulk.zig`** — Bulk API response types and parsing.
  - `BulkResponse` — parsed response with `took`, `errors`, `items`, `failureCount()`,
    `successCount()`, and arena-based `deinit()`.
  - `BulkItemResult` — per-action result with `action`, `index`, `id`, `version`, `result`,
    `status`, `error_type`, `error_reason`, and `isSuccess()`.
  - `parseBulkResponse(allocator, body)` — parse raw JSON into typed `BulkResponse`.
  - Uses internal arena allocator for string ownership (not raw body slices).
  - Unit tests: all-success, mixed success/failure, counter helpers, `isSuccess()` boundaries,
    error detail extraction, malformed JSON (8 sub-cases), and empty items.

- **`src/error.zig`** — Added `ErrorEnvelope` and `parseErrorEnvelope`.
  - `ErrorEnvelope` struct with `status`, `error_type`, `reason`, `index`, and arena-based `deinit()`.
  - `parseErrorEnvelope(allocator, body)` — parse ES error JSON into typed envelope.
  - `toESError()` — map ES exception type strings to `ESError` values:
    `index_not_found_exception` → `IndexNotFound`, `document_missing_exception` → `DocumentNotFound`,
    `version_conflict_engine_exception` → `VersionConflict`,
    `mapper_parsing_exception`/`illegal_argument_exception` → `MappingConflict`, else → `UnexpectedResponse`.
  - Uses arena allocator for string ownership (fixes use-after-free with `std.json` `.alloc_always`).
  - Unit tests: index_not_found, version_conflict, all known mappings, and malformed JSON (5 sub-cases).

- **`src/root.zig`** — Re-exports `serialize`, `deserialize`, `BulkResponse`, `BulkItemResult`,
  and `parseBulkResponse`.

- **`tests/smoke/smoke_roundtrip.zig`** — M2 smoke tests:
  - `smoke_serialize_deserialize_roundtrip` — serialize a `Concept` struct, deserialize back,
    verify all fields including optionals (no network).
  - `smoke_search_response_parse` — parse a realistic ES `_search` response JSON into
    `SearchResponse(Concept)`, verify envelope and hit fields (no network).
  - `smoke_es_index_roundtrip` — full end-to-end: serialize a doc with `elaztic.serialize`,
    PUT it to Elasticsearch via `std.http.Client`, search for it, deserialize
    the `SearchResponse` with `elaztic.deserialize`, verify field-level equality, and clean up.

- **`build.zig`** — Added `smoke_roundtrip.zig` to the `test-smoke` build step.

#### M2 Checklist

- [x] Comptime struct serializer → ES JSON (`src/json/serialize.zig`)
- [x] Comptime JSON deserializer → typed structs (`src/json/deserialize.zig`)
- [x] `SearchResponse(T)` — generic over `_source` document type
- [x] `BulkResponse` — parse per-action results
- [x] `ErrorEnvelope` — parse ES error JSON
- [x] Unit tests with captured response fixtures (no network)
- [x] Smoke test: round-trip a struct through Elasticsearch index → search

#### Deliverable

Typed JSON round-trip works: Zig structs serialize to ES-compatible JSON and
ES responses (search, bulk, error) deserialize into typed Zig structs. Full
end-to-end verified against Elasticsearch (OpenSearch).

---

### Milestone M1 — Transport Layer ✅

**Status: Complete**
**Test backend: Elasticsearch (OpenSearch) on port 9200**

#### Added

- **`src/client.zig`** — `ESClient` struct with `init`, `deinit`, `ping`, `rawRequest`, and `addNode`.
  - `ClientConfig` with host, port, retry, backoff, compression, and basic auth options.
  - `ClusterHealth` response struct with JSON parsing from `/_cluster/health`.
  - `rawRequest` escape hatch for arbitrary HTTP methods and paths.

- **`src/pool.zig`** — `ConnectionPool` with round-robin node selection and health tracking.
  - Uses `std.http.Client` under the hood for proper HTTP/1.1 keep-alive and gzip.
  - `Node` struct with scheme, host, port, healthy flag, and last-seen timestamp.
  - `sendRequest` with retry logic and exponential backoff (doubles each attempt).
  - Retries on 429 (Too Many Requests) and 5xx (server errors).
  - Nodes marked unhealthy on connection failures; re-marked healthy on success.
  - Unit tests for round-robin selection and unhealthy node skipping.

- **`src/error.zig`** — `ESError` error set covering all Elasticsearch error conditions.
  - `shouldRetry` helper for classifying retryable errors.

- **`src/request.zig`** — `ElasticRequest` tagged union with placeholder variants for all
  future operations (search, bulk, get, delete, scroll, PIT, etc.).

- **`src/root.zig`** — Public API surface re-exporting `ESClient`, `ClientConfig`,
  `ClusterHealth`, `ElasticRequest`, `ESError`, `ConnectionPool`, `HttpResponse`, and `Node`.

- **`tests/smoke/smoke_ping.zig`** — Smoke tests against Elasticsearch (OpenSearch):
  - `smoke_ping_healthz` — verifies `/_cluster/health` returns a valid response.
  - `smoke_raw_request_root` — verifies a raw GET returns 200.
  - `smoke_connection_pool_reuse` — issues 5 sequential requests to verify keep-alive reuse.

- **`build.zig`** — Added `test-smoke` build step that compiles and runs smoke tests
  with the `elaztic` module imported.

#### M1 Checklist

- [x] `ConnectionPool` — persistent HTTP connections, keep-alive, round-robin node selection
- [x] HTTP/1.1 request serializer and response parser (via `std.http.Client`)
- [x] gzip body compression (`std.http.Client` negotiates Accept-Encoding automatically)
- [x] Retry logic with exponential backoff (configurable count and initial delay)
- [x] Smoke test: `client.rawRequest("GET", "/", null)` against Elasticsearch (OpenSearch) on port 9200

#### Deliverable

`ESClient` connects to Elasticsearch (OpenSearch), issues HTTP requests, receives and parses JSON
responses, retries on transient failures, and reuses connections via keep-alive.

---

### Initial Setup

- Nix flake (`flake.nix`) with stable, nightly, and CI dev shells.
- Elasticsearch helper scripts: `es-start`, `es-stop`, `es-status`, `es-logs`.
- `build.zig` and `build.zig.zon` for Zig 0.15.2.
- `CLAUDE.md` project documentation with architecture, milestones, and conventions.