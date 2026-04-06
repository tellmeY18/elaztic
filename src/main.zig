const std = @import("std");
const elaztic = @import("elaztic");

pub fn main() !void {
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    _ = allocator;
    _ = elaztic;

    std.debug.print("elaztic — Zig Elasticsearch client library\n", .{});
}

test "library imports resolve" {
    _ = elaztic.ESClient;
    _ = elaztic.ClientConfig;
    _ = elaztic.ElasticRequest;
    _ = elaztic.ESError;
    _ = elaztic.ConnectionPool;
}
