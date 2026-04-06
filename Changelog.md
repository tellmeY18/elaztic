# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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