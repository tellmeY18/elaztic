# elaztic — Zig Elasticsearch client library

# Default recipe: show available commands
default:
    @just --list

# Build the library
build:
    zig build

# Run unit tests
test:
    zig build test --summary all

# Run smoke tests (requires ES_URL=http://localhost:9200)
smoke:
    zig build test-smoke --summary all

# Run integration tests (requires ES_URL=http://localhost:9200)
integration:
    zig build test-integration --summary all

# Run all tests (requires ES_URL=http://localhost:9200)
all:
    zig build test-all --summary all

# Start OpenSearch on port 9200
es-start:
    es-start

# Stop OpenSearch
es-stop:
    es-stop

# Check if OpenSearch is running
es-status:
    es-status

# Tail OpenSearch logs
es-logs:
    tail -f .opensearch.log

# Run throughput benchmarks (requires ES_URL=http://localhost:9200)
bench:
    zig build bench

# Format all Zig source files
fmt:
    zig fmt src/ tests/ bench/ build.zig

# Check formatting without modifying files
fmt-check:
    zig fmt --check src/ tests/ bench/ build.zig

# Clean build artifacts and data
clean:
    rm -rf zig-out .zig-cache .opensearch-data

# Count lines of Zig source code
loc:
    find src/ -name '*.zig' | xargs wc -l
