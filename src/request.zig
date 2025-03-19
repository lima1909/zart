const std = @import("std");

const Variable = @import("vars.zig").Variable;
const Variables = @import("vars.zig").Variables;

/// URL parameter.
pub const Params = Variables;

/// Marker, marked the given Struct as Params
pub fn P(comptime S: type) type {
    return markStruct(S, Marker.P);
}

/// URL query parameter.
pub const Queries = Variables;

/// Marker, marked the given Struct as Query
pub fn Q(comptime S: type) type {
    return markStruct(S, Marker.Q);
}

/// Create an instance of an given Struct from the given Variables.
pub fn FromVars(comptime S: type, vars: []const Variable) !S {
    var instance: S = undefined;
    const vs = Variables{ .vars = vars };

    const info = @typeInfo(S);
    if (info == .Struct) {
        inline for (info.Struct.fields) |field| {
            // ignore marker fields
            if (!comptime Marker.isMarkerFieldName(field.name)) {
                @field(instance, field.name) = if (try vs.valueAs(field.type, field.name)) |val| val else undefined;
            }
        }
    } else {
        @compileError(std.fmt.comptimePrint("parms T type must be a struct, not: {s}", .{@typeName(S)}));
    }

    return instance;
}

pub const Kind = union(enum) {
    app,
    request,
    p: struct { typ: type }, // fromVars
    params,
    q: struct { typ: type }, // fromVars
    queries, // ???
    body, // ???
    fromRequest: struct { typ: type }, // argType, e.g. Body.fromRequest
};

pub const Marker = enum {
    P,
    Q,
    B,

    fn asString(self: Marker) [:0]const u8 {
        return switch (self) {
            .P => "__is_param__",
            .Q => "__is_query__",
            .B => "__is_body__",
        };
    }

    fn isMarkerFieldName(name: [:0]const u8) bool {
        return (name.len > 2 and name[0] == '_' and name[1] == '_' and name[name.len - 1] == '_' and name[name.len - 2] == '_');
    }

    fn fromField(typ: type) ?Marker {
        if (@hasField(typ, Marker.P.asString())) {
            return .P;
        } else if (@hasField(typ, Marker.Q.asString())) {
            return .Q;
        } else if (@hasField(typ, Marker.B.asString())) {
            return .B;
        }

        return null;
    }

    pub fn asKind(typ: type) ?Kind {
        if (fromField(typ)) |m| {
            const fs = @typeInfo(typ).Struct.fields;
            inline for (fs) |f| {
                if (std.mem.eql(u8, f.name, m.asString())) {
                    switch (m) {
                        .P => return Kind{ .p = .{ .typ = f.type } },
                        else => undefined,
                    }
                }
            }
        }

        return null;
    }
};

fn markStruct(comptime S: type, marker: Marker) type {
    const info = @typeInfo(S).Struct;

    var fields: [info.fields.len + 1]std.builtin.Type.StructField = undefined;
    inline for (info.fields, 0..) |field, i| {
        fields[i] = field;
    }

    fields[info.fields.len] = .{
        .name = marker.asString(),
        .type = S,
        .default_value = null,
        .is_comptime = false,
        .alignment = 0,
    };

    return @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
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
