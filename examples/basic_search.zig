//! Basic Search Example
//!
//! Demonstrates connecting to Elasticsearch, indexing documents with
//! comptime-validated field paths, searching with the query DSL,
//! and cleaning up.

const std = @import("std");
const elaztic = @import("elaztic");

const Concept = struct {
    id: u64,
    active: bool,
    module_id: u64,
    term: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to localhost:9200
    var client = try elaztic.ESClient.init(allocator, .{});
    defer client.deinit();

    // Verify cluster is reachable
    var health = try client.ping();
    defer health.deinit(allocator);
    std.debug.print("Cluster: {s} ({s})\n", .{ health.cluster_name, health.status });

    // Create a test index
    const index = "elaztic-example-basic-search";
    client.createIndex(index, .{
        .settings = .{ .number_of_shards = 1, .number_of_replicas = 0 },
    }) catch |err| {
        std.debug.print("Note: createIndex returned {}\n", .{err});
    };
    defer client.deleteIndex(index) catch {};

    // Index some SNOMED-like concepts
    const concepts = [_]Concept{
        .{ .id = 404684003, .active = true, .module_id = 900000000000207008, .term = "Clinical finding" },
        .{ .id = 138875005, .active = true, .module_id = 900000000000207008, .term = "SNOMED CT Concept" },
        .{ .id = 71388002, .active = true, .module_id = 900000000000207008, .term = "Procedure" },
        .{ .id = 362969004, .active = false, .module_id = 900000000000012004, .term = "Deprecated concept" },
        .{ .id = 123037004, .active = true, .module_id = 900000000000012004, .term = "Body structure" },
    };

    for (concepts) |concept| {
        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{concept.id}) catch unreachable;
        _ = try client.indexDoc(Concept, index, concept, .{ .id = id_str });
    }

    // Refresh to make documents searchable
    try client.refresh(index);

    // Search: active concepts in the international module
    //
    // Comptime field paths validate field names at compile time:
    //   field(Concept, "active")  → ok
    //   field(Concept, "typo")   → compile error!
    const Q = elaztic.query.Query;
    const active_field = comptime elaztic.query.field(Concept, "active");
    const module_field = comptime elaztic.query.field(Concept, "module_id");

    const query = Q.boolQuery(.{
        .must = &.{
            Q.term(active_field.name, true),
        },
        .filter = &.{
            Q.range(module_field.name).gte(@as(u64, 900000000000207008)).build(),
        },
    });

    var result = try client.searchDocs(Concept, index, query, .{ .size = 10 });
    defer result.deinit();

    const total_hits: u64 = if (result.value.hits.total) |t| t.value else 0;
    std.debug.print("\nSearch results ({d} hits):\n", .{total_hits});
    for (result.value.hits.hits) |hit| {
        if (hit._source) |concept| {
            std.debug.print("  [{d}] {s} (active={}, module={d})\n", .{
                concept.id,
                concept.term,
                concept.active,
                concept.module_id,
            });
        }
    }

    // Count all active concepts
    const active_count = try client.count(index, Q.term(active_field.name, true));
    std.debug.print("\nTotal active concepts: {d}\n", .{active_count});
}
