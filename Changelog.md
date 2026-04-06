# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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