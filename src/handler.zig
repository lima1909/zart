const std = @import("std");
const http = std.http;

const KeyValue = @import("kv.zig").KeyValue;
const KeyValues = @import("kv.zig").KeyValues;

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
    const Self = @This();

    noreturn, // void
    string,
    status, // http.Status
    strukt,
    response: type, // the inner type

    // return type combined with error
    error_union: struct {
        error_set: type,
        payload: ReturnType,
    },

    fn new(ty: type) Self {
        return switch (@typeInfo(ty)) {
            .void => .noreturn,
            // static string
            .pointer => |p| if (p.child == u8)
                .string
            else
                @compileError("Not supported return type pointer: " ++ @typeName(ty)),
            // status
            .@"enum" => .status,

            // Response or struct
            .@"struct" => if (@hasField(ty, "__typeOfCcontent__"))
                .{ .response = @FieldType(ty, "__typeOfCcontent__") }
            else
                .strukt,

            // with error
            .error_union => |err| ReturnType{ .error_union = .{
                .error_set = err.error_set,
                .payload = new(err.payload),
            } },

            else => @compileError("Not supported return type: " ++ @typeName(ty)),
        };
    }

    fn payload(self: Self) Self {
        return switch (self) {
            .error_union => |eu| eu.payload,
            else => self,
        };
    }
};

// The response with Content (Body)
pub fn Response(S: type) type {
    return struct {
        status: http.Status = .ok,

        // content is the Body-Content
        content: union(enum) {
            string: []const u8,
            strukt: S,
        } = .{ .string = "" }, // default, no content = ""

        // only for meta programming
        __typeOfCcontent__: S = undefined,
    };
}

/// The main interface for creating handler functions
pub fn Handler(App: type, Request: type) type {
    return struct {
        handle: *const fn (app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: std.mem.Allocator) anyerror!void,
    };
}

pub fn handlerFromFn(App: type, Request: type, func: anytype, Extractor: type) Handler(App, Request) {
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
    const return_type = ReturnType.new(meta.@"fn".return_type.?);

    // create Handler
    const h = struct {
        fn handle(app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: std.mem.Allocator) !void {
            const Args = std.meta.ArgsTuple(@TypeOf(func));
            var args: Args = undefined;

            // create arg-values
            inline for (0..arg_types.len) |i| {
                args[i] = switch (arg_types[i]) {
                    .app => if (app) |a| a else return error.NoAppDefined,
                    .request => req,
                    .p => |p| try FromVars(p.typ, params),
                    .params => Params{ .vars = params },
                    .q => |q| try FromVars(q.typ, query),
                    .query => Query{ .vars = query },
                    .b => |b| try Extractor.body(b.typ, allocator, req),
                    .body => try Extractor.body(std.json.Value, allocator, req),
                    .fromRequest => |r| r.typ.fromRequest(req),
                };
            }

            //
            // execute handler function, depending the return value has an error
            //
            const result = if (return_type == .error_union)
                try @call(.auto, func, args)
            else
                @call(.auto, func, args);

            comptime var rty = @TypeOf(result);
            const resp = blk: switch (return_type.payload()) {
                .noreturn, .error_union => return, // error_union can't be nested, so we can return here
                .response => |ty| {
                    rty = ty;
                    break :blk result;
                },
                .status => {
                    rty = void;
                    break :blk Response(void){ .status = result };
                },
                .strukt => Response(rty){ .content = .{ .strukt = result } },
                .string => Response(rty){ .content = .{ .string = result } },
            };

            try Extractor.response(rty, allocator, req, resp);
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
            fn response(T: type, allocator: std.mem.Allocator, _: void, resp: Response(T)) !void {
                const s = try std.json.stringifyAlloc(allocator, resp.content.strukt, .{});
                defer allocator.free(s);

                try std.testing.expectEqualStrings(
                    \\{"id":42,"name":"its me"}
                , s);
                try std.testing.expectEqual(.ok, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handle static string" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn string() []const u8 {
                return "its me";
            }
        }.string,
        struct {
            fn response(T: type, _: std.mem.Allocator, _: void, resp: Response(T)) !void {
                try std.testing.expectEqualStrings("its me", resp.content.string);
                try std.testing.expectEqual(.ok, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handle error!static string" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn string() ![]const u8 {
                return "with error";
            }
        }.string,
        struct {
            fn response(T: type, _: std.mem.Allocator, _: void, resp: Response(T)) !void {
                try std.testing.expectEqualStrings("with error", resp.content.string);
                try std.testing.expectEqual(.ok, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handler with Response" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUser() Response(User) {
                return .{ .status = .created, .content = .{ .strukt = .{ .id = 42, .name = "its me" } } };
            }
        }.createUser,
        struct {
            fn response(T: type, _: std.mem.Allocator, _: void, resp: Response(T)) !void {
                const u: User = resp.content.strukt;
                try std.testing.expectEqual(42, u.id);
                try std.testing.expectEqualStrings("its me", u.name);
                try std.testing.expectEqual(.created, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handler with error!Response" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUserWithError() !Response(User) {
                return .{ .status = .created, .content = .{ .strukt = .{ .id = 45, .name = "other" } } };
            }
        }.createUserWithError,
        struct {
            fn response(T: type, _: std.mem.Allocator, _: void, resp: Response(T)) !void {
                const u: User = resp.content.strukt;
                try std.testing.expectEqual(45, u.id);
                try std.testing.expectEqualStrings("other", u.name);
                try std.testing.expectEqual(.created, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handler with return state" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUser() std.http.Status {
                return .created;
            }
        }.createUser,
        struct {
            fn response(T: type, _: std.mem.Allocator, _: void, resp: Response(T)) !void {
                try std.testing.expectEqual(.created, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}
