//! Compile-time validated field paths for Elasticsearch queries.
//!
//! This module provides the `FieldPath` type and the `field` function, which
//! together give compile-time assurance that field names used in query builders
//! actually exist on the Zig struct that models the Elasticsearch document.
//!
//! Dotted paths (e.g. `"inner.value"`) are supported: each segment is validated
//! against the corresponding nested struct type, unwrapping optionals as needed.

const std = @import("std");

/// A compile-time validated field path for use in Elasticsearch queries.
/// Carries the dotted field name string that will appear in serialized ES JSON.
pub const FieldPath = struct {
    /// The dotted field name string (e.g. `"active"` or `"inner.value"`).
    name: []const u8,
};

/// Validates at compile time that `name` is a valid field (or dotted path) on
/// struct type `T`. Returns a `FieldPath` that can be passed to query builders.
///
/// For nested paths like `"inner.value"`, walks the struct type chain:
/// first checks `T` has field `"inner"`, then checks the type of `"inner"` has
/// field `"value"`.
///
/// Optional types are unwrapped automatically — if a field is `?InnerType`,
/// the next segment is validated against `InnerType`.
///
/// Produces a `@compileError` with a human-readable message if any segment is
/// invalid or if the path is empty.
///
/// ## Example
///
/// ```zig
/// const Concept = struct { id: u64, active: bool, module_id: u64 };
/// const fp = field(Concept, "active");
/// // fp.name == "active"
/// ```
pub fn field(comptime T: type, comptime name: []const u8) FieldPath {
    comptime {
        if (name.len == 0) {
            @compileError("Field path must not be empty");
        }

        validatePath(T, name);

        return .{ .name = name };
    }
}

/// Recursively validates a dotted path against the struct type hierarchy at
/// comptime. Splits on `'.'` and walks one segment at a time.
fn validatePath(comptime T: type, comptime path: []const u8) void {
    comptime {
        const resolved = unwrapOptional(T);

        const info = switch (@typeInfo(resolved)) {
            .@"struct" => |s| s,
            else => @compileError(
                "Expected struct type, got " ++ @typeName(resolved),
            ),
        };

        const segment, const rest = splitFirst(path);

        // Check the segment exists on the current struct.
        if (!@hasField(resolved, segment)) {
            @compileError("Field '" ++ segment ++ "' does not exist on " ++ @typeName(resolved));
        }

        // If there are more segments, recurse into the field's type.
        if (rest) |remaining| {
            const FieldType = fieldType(info.fields, segment);
            validatePath(FieldType, remaining);
        }
    }
}

/// Splits `path` at the first `'.'`, returning the first segment and an
/// optional remainder. If there is no `'.'`, the remainder is `null`.
///
/// Examples (comptime):
///   `"a.b.c"` → `("a", "b.c")`
///   `"active"` → `("active", null)`
fn splitFirst(comptime path: []const u8) struct { []const u8, ?[]const u8 } {
    comptime {
        for (path, 0..) |c, i| {
            if (c == '.') {
                if (i == 0) {
                    @compileError("Field path must not start with '.'");
                }
                if (i + 1 >= path.len) {
                    @compileError("Field path must not end with '.'");
                }
                return .{ path[0..i], path[i + 1 ..] };
            }
        }
        return .{ path, null };
    }
}

/// Returns the type of the struct field named `name` within the given fields
/// slice. This is used to walk into nested struct types during path validation.
fn fieldType(comptime fields: []const std.builtin.Type.StructField, comptime name: []const u8) type {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return f.type;
        }
    }
    // Should be unreachable — we already checked `@hasField` before calling this.
    @compileError("Field '" ++ name ++ "' not found (internal error)");
}

/// Unwraps an optional type `?T` → `T`. If `T` is not optional, returns `T`
/// unchanged. This lets dotted paths walk through optional struct fields.
fn unwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "simple field — valid" {
    const Concept = struct {
        id: u64,
        active: bool,
        module_id: u64,
    };

    const fp = comptime field(Concept, "active");
    try std.testing.expectEqualStrings("active", fp.name);

    const fp2 = comptime field(Concept, "id");
    try std.testing.expectEqualStrings("id", fp2.name);

    const fp3 = comptime field(Concept, "module_id");
    try std.testing.expectEqualStrings("module_id", fp3.name);
}

test "nested field — valid" {
    const Inner = struct {
        value: u32,
        label: []const u8,
    };
    const Outer = struct {
        inner: Inner,
        name: []const u8,
    };

    const fp = comptime field(Outer, "inner.value");
    try std.testing.expectEqualStrings("inner.value", fp.name);

    const fp2 = comptime field(Outer, "inner.label");
    try std.testing.expectEqualStrings("inner.label", fp2.name);
}

test "nested field through optional — valid" {
    const Deep = struct {
        score: f64,
    };
    const Inner = struct {
        deep: ?Deep,
        count: u32,
    };
    const Outer = struct {
        inner: ?Inner,
        id: u64,
    };

    // Walk through two levels of optionals.
    const fp = comptime field(Outer, "inner.deep.score");
    try std.testing.expectEqualStrings("inner.deep.score", fp.name);

    // Walk through one level of optional.
    const fp2 = comptime field(Outer, "inner.count");
    try std.testing.expectEqualStrings("inner.count", fp2.name);
}

test "FieldPath name is the original dotted path" {
    const S = struct { x: u8 };
    const fp = comptime field(S, "x");
    try std.testing.expectEqualStrings("x", fp.name);
}

// ---------------------------------------------------------------------------
// Compile-error cases (cannot be tested at runtime).
//
// The following calls would each produce a `@compileError` if uncommented:
//
//   field(Concept, "typo")
//     → "Field 'typo' does not exist on field.test.simple field — valid.Concept"
//
//   field(Outer, "inner.nope")
//     → "Field 'nope' does not exist on field.test.nested field — valid.Inner"
//
//   field(Concept, "")
//     → "Field path must not be empty"
//
//   field(Concept, ".active")
//     → "Field path must not start with '.'"
//
//   field(Concept, "active.")
//     → "Field path must not end with '.'"
// ---------------------------------------------------------------------------
