const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library module ──────────────────────────────────────────────────
    const mod = b.addModule("elaztic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ── Unit tests ──────────────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // ── Smoke tests (require ES_URL) ────────────────────────────────────
    const smoke_ping = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke/smoke_ping.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "elaztic", .module = mod }},
        }),
    });
    const smoke_roundtrip = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke/smoke_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "elaztic", .module = mod }},
        }),
    });

    const smoke_step = b.step("test-smoke", "Run smoke tests (requires ES_URL)");
    smoke_step.dependOn(&b.addRunArtifact(smoke_ping).step);
    smoke_step.dependOn(&b.addRunArtifact(smoke_roundtrip).step);

    // ── Integration tests (require ES_URL) ──────────────────────────────
    const integration_files = [_][]const u8{
        "tests/integration/query_integration.zig",
        "tests/integration/api_integration.zig",
        "tests/integration/bulk_integration.zig",
        "tests/integration/scroll_pit_integration.zig",
        "tests/integration/hardening_integration.zig",
    };

    const integration_step = b.step("test-integration", "Run integration tests (requires ES_URL)");
    for (integration_files) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "elaztic", .module = mod }},
            }),
        });
        integration_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── All tests ───────────────────────────────────────────────────────
    const all_step = b.step("test-all", "Run all tests (unit + smoke + integration)");
    all_step.dependOn(test_step);
    all_step.dependOn(smoke_step);
    all_step.dependOn(integration_step);

    // ── Benchmarks ──────────────────────────────────────────────────────
    const bench_exe = b.addExecutable(.{
        .name = "bulk-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bulk_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "elaztic", .module = mod }},
        }),
    });

    const bench_step = b.step("bench", "Run throughput benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}
