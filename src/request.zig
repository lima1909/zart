const std = @import("std");

const Variable = @import("vars.zig").Variable;
const Variables = @import("vars.zig").Variables;

/// Marker, marked the given Struct as Params
pub fn P(comptime S: type) S {
    return S;
}

/// URL parameter.
pub const Params = Variables;

/// Marker, marked the given Struct as Query
pub fn Q(comptime S: type) S {
    return S;
}

/// URL query parameter.
pub const Queries = Variables;

/// Create an instance of an given Struct from the given Variables.
pub fn FromVars(comptime S: type, vars: []const Variable) !S {
    var instance: S = undefined;
    const vs = Variables{ .vars = vars };

    const info = @typeInfo(S);
    if (info == .Struct) {
        inline for (info.Struct.fields) |field| {
            @field(instance, field.name) = if (try vs.valueAs(field.type, field.name)) |val| val else undefined;
        }
    } else {
        @compileError(std.fmt.comptimePrint("parmas T type must be a struct, not: {s}", .{@typeName(S)}));
    }

    return instance;
}

test "from vars string field" {
    const X = struct { name: []const u8 };
    const p = try FromVars(X, &[_]Variable{.{ .key = "name", .value = "Mario" }});

    try std.testing.expectEqualStrings("Mario", p.name);
}

test "from vars bool field" {
    const X = struct { maybe: bool };
    const p = try FromVars(X, &[_]Variable{.{ .key = "maybe", .value = "true" }});

    try std.testing.expectEqual(true, p.maybe);
}

test "from vars int and foat field" {
    const X = struct { inumber: i32, fnumber: f32 };
    const p = try FromVars(X, &[_]Variable{ .{ .key = "inumber", .value = "42" }, .{ .key = "fnumber", .value = "2.4" } });

    try std.testing.expectEqual(42, p.inumber);
    try std.testing.expectEqual(2.4, p.fnumber);
}
