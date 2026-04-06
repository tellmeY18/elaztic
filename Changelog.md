# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Milestone M2 — JSON Infrastructure ✅

**Status: Complete**
**Test backend: ZincSearch on port 4080**

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
  - `smoke_zinc_index_roundtrip` — full end-to-end: serialize a doc with `elaztic.serialize`,
    PUT it to ZincSearch via `std.http.Client` with Basic auth, search for it, deserialize
    the `SearchResponse` with `elaztic.deserialize`, verify field-level equality, and clean up.
    Uses float64-safe IDs (ZincSearch stores numbers as float64, losing precision above 2^53).

- **`build.zig`** — Added `smoke_roundtrip.zig` to the `test-smoke` build step.

#### M2 Checklist

- [x] Comptime struct serializer → ES JSON (`src/json/serialize.zig`)
- [x] Comptime JSON deserializer → typed structs (`src/json/deserialize.zig`)
- [x] `SearchResponse(T)` — generic over `_source` document type
- [x] `BulkResponse` — parse per-action results
- [x] `ErrorEnvelope` — parse ES error JSON
- [x] Unit tests with captured response fixtures (no network)
- [x] Smoke test: round-trip a struct through ZincSearch index → search

#### Deliverable

Typed JSON round-trip works: Zig structs serialize to ES-compatible JSON and
ES responses (search, bulk, error) deserialize into typed Zig structs. Full
end-to-end verified against ZincSearch.

#### Known Limitations (ZincSearch only)

- ZincSearch stores numbers as float64 — SNOMED concept IDs above 2^53
  (e.g. `900000000000207008`) lose precision. Real Elasticsearch does not
  have this limitation.
- ZincSearch does not implement `GET /es/<index>/_doc/<id>` — smoke test
  uses `_search` instead.
- `ESClient` does not wire `basic_auth` into HTTP request headers yet — smoke
  test uses `std.http.Client` directly with manual Authorization header.

---

### Milestone M1 — Transport Layer ✅

**Status: Complete**
**Test backend: ZincSearch on port 4080**

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

- **`tests/smoke/smoke_ping.zig`** — Smoke tests against ZincSearch:
  - `smoke_ping_healthz` — verifies `/healthz` returns `{"status":"ok"}`.
  - `smoke_raw_request_root` — verifies a raw GET returns 200.
  - `smoke_connection_pool_reuse` — issues 5 sequential requests to verify keep-alive reuse.

- **`build.zig`** — Added `test-smoke` build step that compiles and runs smoke tests
  with the `elaztic` module imported.

#### M1 Checklist

- [x] `ConnectionPool` — persistent HTTP connections, keep-alive, round-robin node selection
- [x] HTTP/1.1 request serializer and response parser (via `std.http.Client`)
- [x] gzip body compression (`std.http.Client` negotiates Accept-Encoding automatically)
- [x] Retry logic with exponential backoff (configurable count and initial delay)
- [x] Smoke test: `client.rawRequest("GET", "/healthz", null)` against ZincSearch on port 4080

#### Deliverable

`ESClient` connects to ZincSearch, issues HTTP requests, receives and parses JSON
responses, retries on transient failures, and reuses connections via keep-alive.

---

### Initial Setup

- Nix flake (`flake.nix`) with stable, nightly, and CI dev shells.
- ZincSearch helper scripts: `zinc-start`, `zinc-stop`, `zinc-status`.
- Elasticsearch Docker helpers: `es-start`, `es-stop`, `es-logs`, `es-status`.
- `build.zig` and `build.zig.zon` for Zig 0.15.2.
- `CLAUDE.md` project documentation with architecture, milestones, and conventions.