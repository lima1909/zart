const std = @import("std");

const Variable = @import("vars.zig").Variable;
const Variables = @import("vars.zig").Variables;

/// Kinds of handler Args (parts of an request)
const Kind = union(enum) {
    app,
    request,
    p: struct { typ: type }, // fromVars
    params,
    q: struct { typ: type }, // fromVars
    query,
    body,
    fromRequest: struct { typ: type }, // argType, e.g. Body.fromRequest
};

// Examples for Handler function signatures:
//   - fn (req: Request)
//   - fn (req: Request, params: Params)
//   - fn (app: App, req: Request, params: P(MyParam))
//   - fn (app: App, req: Request)
//
pub fn Handler(comptime App: type, comptime Request: type) type {
    return struct {
        handle: *const fn (app: ?App, req: Request, query: []const Variable, params: []const Variable) anyerror!void,
    };
}

pub fn handlerFromFn(comptime App: type, comptime Request: type, func: anytype) Handler(App, Request) {
    const meta = @typeInfo(@TypeOf(func));
    comptime var kinds: [meta.Fn.params.len]Kind = undefined;

    inline for (meta.Fn.params, 0..) |p, i| {
        if (p.type) |ty| {
            if (ty == App) {
                kinds[i] = .app;
            } else if (ty == Request) {
                kinds[i] = .request;
            } else if (ty == Params) {
                kinds[i] = .params;
            } else if (ty == Query) {
                kinds[i] = .query;
            } else if (@hasField(ty, TagFieldName)) {
                const fs = @typeInfo(ty).Struct.fields;
                inline for (fs) |f| {
                    if (comptime std.mem.eql(u8, f.name, TagFieldName)) {
                        kinds[i] = f.type.kind();
                    }
                }
            } else {
                kinds[i] = Kind{ .fromRequest = .{ .typ = ty } };
            }
        } else {
            @compileError("Missing type for parameter in function: " ++ @typeName(meta.Fn));
        }
    }

    const h = struct {
        fn handle(app: ?App, req: Request, query: []const Variable, params: []const Variable) !void {
            const Args = std.meta.ArgsTuple(@TypeOf(func));
            var args: Args = undefined;

            inline for (0..kinds.len) |i| {
                args[i] = switch (kinds[i]) {
                    .app => app.?,
                    .request => req,
                    .p => |p| try FromVars(P(p.typ), params),
                    .params => Params{ .vars = params },
                    .q => |q| try FromVars(Q(q.typ), query),
                    .query => Query{ .vars = query },
                    .fromRequest => |r| r.typ.fromRequest(req),
                    .body => @panic("BODY is not implemented yet!"),
                };
            }

            return @call(.auto, func, args);
        }
    };

    return Handler(App, Request){ .handle = h.handle };
}

fn ParamTag(comptime T: type) type {
    return struct {
        fn kind() Kind {
            return Kind{ .p = .{ .typ = T } };
        }
    };
}

/// URL parameter.
pub const Params = Variables(ParamTag(void));

/// Marker, marked the given Struct as Params
pub fn P(comptime S: type) type {
    return structWithTag(S, ParamTag(S));
}

fn QueryTag(comptime T: type) type {
    return struct {
        pub fn kind() Kind {
            return Kind{ .q = .{ .typ = T } };
        }
    };
}

/// URL query parameter.
pub const Query = Variables(QueryTag(void));

/// Marker, marked the given Struct as Query
pub fn Q(comptime S: type) type {
    return structWithTag(S, QueryTag(S));
}

const TagFieldName = "__TAG__";

fn structWithTag(comptime S: type, comptime Tag: type) type {
    return @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = @typeInfo(S).Struct.fields ++ [1]std.builtin.Type.StructField{.{
                .name = TagFieldName,
                .type = Tag,
                .default_value = null,
                .is_comptime = false,
                .alignment = 0,
            }},
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

/// Create an instance of an given Struct from the given Variables.
fn FromVars(comptime S: type, vars: []const Variable) !S {
    var instance: S = undefined;
    const vs = Variables(void){ .vars = vars };

    const info = @typeInfo(S);
    if (info == .Struct) {
        inline for (info.Struct.fields) |field| {
            if (!comptime std.mem.eql(u8, TagFieldName, field.name)) {
                @field(instance, field.name) = if (try vs.valueAs(field.type, field.name)) |val| val else undefined;
            }
        }
    } else {
        @compileError(std.fmt.comptimePrint("parms T type must be a struct, not: {s}", .{@typeName(S)}));
    }

    return instance;
}

test "fromVars string field" {
    const X = struct { name: []const u8 };
    const p = try FromVars(X, &[_]Variable{.{ .key = "name", .value = "Mario" }});

    try std.testing.expectEqualStrings("Mario", p.name);
}

test "fromVars bool field" {
    const X = struct { maybe: bool };
    const p = try FromVars(X, &[_]Variable{.{ .key = "maybe", .value = "true" }});

    try std.testing.expectEqual(true, p.maybe);
}

test "fromVars int and foat field" {
    const X = struct { inumber: i32, fnumber: f32 };
    const p = try FromVars(X, &[_]Variable{ .{ .key = "inumber", .value = "42" }, .{ .key = "fnumber", .value = "2.4" } });

    try std.testing.expectEqual(42, p.inumber);
    try std.testing.expectEqual(2.4, p.fnumber);
}
