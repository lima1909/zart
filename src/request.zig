const std = @import("std");

const KeyValue = @import("kv.zig").KeyValue;
const KeyValues = @import("kv.zig").KeyValues;

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

pub const Response = struct {
    content: ?[]const u8 = null,
    status: std.http.Status = .ok,
};

/// ArgTypes of handler Args (parts of an request)
const ArgType = union(enum) {
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

/// ReturnTypes of handler returns
const ReturnType = union(enum) {
    none,
    strukt,
    error_union: std.builtin.Type.ErrorUnion,
};

// Examples for Handler function signatures:
//   - fn (req: Request)
//   - fn (req: Request, params: Params)
//   - fn (app: App, req: Request, params: P(MyParam))
//   - fn (app: App, req: Request)
//
pub fn Handler(App: type, Request: type) type {
    return struct {
        handle: *const fn (app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: std.mem.Allocator) anyerror!?Response,
    };
}

pub fn handlerFromFn(App: type, Request: type, func: anytype, DeEncoder: type) Handler(App, Request) {
    const meta = @typeInfo(@TypeOf(func));
    comptime var arg_types: [meta.@"fn".params.len]ArgType = undefined;

    // check the function args
    inline for (meta.@"fn".params, 0..) |p, i| {
        if (p.type) |ty| {
            arg_types[i] = switch (ty) {
                App => .app,
                Request => .request,
                Params => .params,
                Query => .query,
                Body => .body,
                else => if (@typeInfo(ty) == .@"struct")
                    if (@hasField(ty, TagFieldName))
                        @FieldType(ty, TagFieldName).argType(ty)
                    else
                        ArgType{ .fromRequest = .{ .typ = ty } }
                else
                    @compileError("Not supported parameter type for a handler function: " ++ @typeName(ty)),
            };
        } else {
            @compileError("Missing type for parameter in function: " ++ @typeName(meta.Fn));
        }
    }

    // check the return type
    const return_type: ReturnType = if (meta.@"fn".return_type) |ty|
        switch (@typeInfo(ty)) {
            .error_union => |err| ReturnType{ .error_union = err },
            .void => .none,
            .@"struct" => .strukt,
            else => @compileError("Not supported return type: " ++ @typeName(ty)),
        }
    else
        @compileError("Not supported return type found");

    const h = struct {
        fn handle(app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: std.mem.Allocator) !?Response {
            const Args = std.meta.ArgsTuple(@TypeOf(func));
            var args: Args = undefined;

            inline for (0..arg_types.len) |i| {
                args[i] = switch (arg_types[i]) {
                    .app => app.?,
                    .request => req,
                    .p => |p| try FromVars(p.typ, params),
                    .params => Params{ .vars = params },
                    .q => |q| try FromVars(q.typ, query),
                    .query => Query{ .vars = query },
                    .b => |b| try DeEncoder.decode(b.typ, req, allocator),
                    .body => try DeEncoder.decode(std.json.Value, req, allocator),
                    .fromRequest => |r| r.typ.fromRequest(req),
                };
            }

            switch (return_type) {
                .none => {
                    // mapping void to null (no Response available)
                    _ = @call(.auto, func, args);
                    return null;
                },
                .strukt => {
                    const b = @call(.auto, func, args);
                    try DeEncoder.response(req, allocator, b);
                    return .{};
                },
                .error_union => |eu| {
                    // mapping void to null (no Response available)
                    if (@typeInfo(eu.payload) == .void) {
                        _ = try @call(.auto, func, args);
                        return null;
                    }
                    return @call(.auto, func, args);
                },
            }
        }
    };

    return Handler(App, Request){ .handle = h.handle };
}

const ParamTag = struct {
    fn argType(comptime T: type) ArgType {
        return ArgType{ .p = .{ .typ = T } };
    }
};

/// URL parameter.
pub const Params = KeyValues(ParamTag);

/// Marker, marked the given Struct as Params
pub fn P(comptime S: type) type {
    return structWithTag(S, ParamTag);
}

const QueryTag = struct {
    fn argType(comptime T: type) ArgType {
        return ArgType{ .q = .{ .typ = T } };
    }
};

/// URL query parameter.
pub const Query = KeyValues(QueryTag);

/// Marker, marked the given Struct as Query
pub fn Q(comptime S: type) type {
    return structWithTag(S, QueryTag);
}

const BodyTag = struct {
    fn argType(comptime T: type) ArgType {
        return ArgType{ .b = .{ .typ = T } };
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
        .@"struct" = .{
            .layout = .auto,
            .fields = @typeInfo(S).@"struct".fields ++ [1]std.builtin.Type.StructField{.{
                .name = TagFieldName,
                .type = Tag,
                .default_value_ptr = &Tag{},
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
    if (info == .@"struct") {
        inline for (info.@"struct".fields) |field| {
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

test "handler with no args and void return" {
    const h = handlerFromFn(void, void, struct {
        fn foo() void {}
    }.foo, void);

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handler with no args and error_union with void return" {
    const h = handlerFromFn(void, void, struct {
        fn foo() !void {}
    }.foo, void);

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handler response with body" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn getUser() User {
                return .{ .id = 42, .name = "its me" };
            }
        }.getUser,
        struct {
            fn response(_: void, allocator: std.mem.Allocator, u: User) !void {
                const s = try std.json.stringifyAlloc(allocator, u, .{});
                try std.testing.expectEqualStrings(
                    \\{"id":42,"name":"its me"}
                , s);
                allocator.free(s);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}
