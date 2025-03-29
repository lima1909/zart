const std = @import("std");

const KeyValue = @import("kv.zig").KeyValue;
const KeyValues = @import("kv.zig").KeyValues;

/// Kinds of handler Args (parts of an request)
const Kind = union(enum) {
    app,
    request,
    p: struct { typ: type }, // fromVars
    params,
    q: struct { typ: type }, // fromVars
    query,
    b: struct { typ: type }, // decoder
    body,
    fromRequest: struct { typ: type }, // argType, e.g. Body.fromRequest
};

/// Is created by every Request.
pub fn OnRequest(Request: type) type {
    return struct {
        method: std.http.Method,
        path: []const u8,
        query: []const KeyValue = &[_]KeyValue{},

        // the original Request
        request: Request,
    };
}

// Examples for Handler function signatures:
//   - fn (req: Request)
//   - fn (req: Request, params: Params)
//   - fn (app: App, req: Request, params: P(MyParam))
//   - fn (app: App, req: Request)
//
pub fn Handler(App: type, Request: type) type {
    return struct {
        handle: *const fn (app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: std.mem.Allocator) anyerror!void,
    };
}

pub fn handlerFromFn(App: type, Request: type, func: anytype, decode: anytype) Handler(App, Request) {
    const meta = @typeInfo(@TypeOf(func));
    comptime var kinds: [meta.Fn.params.len]Kind = undefined;

    inline for (meta.Fn.params, 0..) |p, i| {
        if (p.type) |ty| {
            switch (ty) {
                App => kinds[i] = .app,
                Request => kinds[i] = .request,
                Params => kinds[i] = .params,
                Query => kinds[i] = .query,
                Body => kinds[i] = .body,
                else => if (@hasField(ty, TagFieldName)) {
                    // TODO: zig 0.14
                    // kinds[i] = @FieldType(ty, TagFieldName).kind(ty);
                    const fs = @typeInfo(ty).Struct.fields;
                    inline for (fs) |f| {
                        if (comptime std.mem.eql(u8, f.name, TagFieldName)) {
                            kinds[i] = f.type.kind(ty);
                        }
                    }
                } else {
                    kinds[i] = Kind{ .fromRequest = .{ .typ = ty } };
                },
            }
        } else {
            @compileError("Missing type for parameter in function: " ++ @typeName(meta.Fn));
        }
    }

    const h = struct {
        fn handle(app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: std.mem.Allocator) !void {
            const Args = std.meta.ArgsTuple(@TypeOf(func));
            var args: Args = undefined;

            inline for (0..kinds.len) |i| {
                args[i] = switch (kinds[i]) {
                    .app => app.?,
                    .request => req,
                    .p => |p| try FromVars(p.typ, params),
                    .params => Params{ .vars = params },
                    .q => |q| try FromVars(q.typ, query),
                    .query => Query{ .vars = query },
                    .b => |b| try decode(b.typ, req, allocator),
                    .body => try decode(std.json.Value, req, allocator),
                    .fromRequest => |r| r.typ.fromRequest(req),
                };
            }

            return @call(.auto, func, args);
        }
    };

    return Handler(App, Request){ .handle = h.handle };
}

const ParamTag = struct {
    fn kind(comptime T: type) Kind {
        return Kind{ .p = .{ .typ = T } };
    }
};

/// URL parameter.
pub const Params = KeyValues(ParamTag);

/// Marker, marked the given Struct as Params
pub fn P(comptime S: type) type {
    return structWithTag(S, ParamTag);
}

const QueryTag = struct {
    fn kind(comptime T: type) Kind {
        return Kind{ .q = .{ .typ = T } };
    }
};

/// URL query parameter.
pub const Query = KeyValues(QueryTag);

/// Marker, marked the given Struct as Query
pub fn Q(comptime S: type) type {
    return structWithTag(S, QueryTag);
}

const BodyTag = struct {
    fn kind(comptime T: type) Kind {
        return Kind{ .b = .{ .typ = T } };
    }
};

/// Marker, marked the given Struct as Body
pub fn B(comptime S: type) type {
    return structWithTag(S, BodyTag);
}

/// Body from request as abstract Json-Value
pub const Body = std.json.Value;

/// Field name for the Tags.
const TagFieldName = "__TAG__";

fn structWithTag(comptime S: type, comptime Tag: type) type {
    return @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = @typeInfo(S).Struct.fields ++ [1]std.builtin.Type.StructField{.{
                .name = TagFieldName,
                .type = Tag,
                .default_value = &Tag{},
                .is_comptime = false,
                .alignment = 0,
            }},
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

/// Create an instance of an given Struct from the given key-values.
fn FromVars(comptime S: type, vars: []const KeyValue) !S {
    var instance: S = undefined;
    const vs = KeyValues(void){ .vars = vars };

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
    const p = try FromVars(X, &[_]KeyValue{.{ .key = "name", .value = "Mario" }});

    try std.testing.expectEqualStrings("Mario", p.name);
}

test "fromVars bool field" {
    const X = struct { maybe: bool };
    const p = try FromVars(X, &[_]KeyValue{.{ .key = "maybe", .value = "true" }});

    try std.testing.expectEqual(true, p.maybe);
}

test "fromVars int and foat field" {
    const X = struct { inumber: i32, fnumber: f32 };
    const p = try FromVars(X, &[_]KeyValue{ .{ .key = "inumber", .value = "42" }, .{ .key = "fnumber", .value = "2.4" } });

    try std.testing.expectEqual(42, p.inumber);
    try std.testing.expectEqual(2.4, p.fnumber);
}
