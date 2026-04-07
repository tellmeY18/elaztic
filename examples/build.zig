const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const elaztic_dep = b.dependency("elaztic", .{});
    const elaztic_mod = elaztic_dep.module("elaztic");

    const examples = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "basic-search", .src = "basic_search.zig" },
        .{ .name = "bulk-index", .src = "bulk_index.zig" },
        .{ .name = "scroll-large", .src = "scroll_large.zig" },
    };

    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.src),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "elaztic", .module = elaztic_mod }},
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step(
            b.fmt("run-{s}", .{ex.name}),
            b.fmt("Run the {s} example", .{ex.name}),
        );
        run_step.dependOn(&run_cmd.step);
    }
}
