const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const KeyValue = @import("kv.zig").KeyValue;
const KeyValues = @import("kv.zig").KeyValues;

/// The main interface for creating handler functions
pub fn Handler(App: type, Request: type) type {
    return struct {
        handle: *const fn (app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: Allocator) anyerror!void,
    };
}

/// Factory to create an Handler for a given function.
pub fn handlerFromFn(App: type, Request: type, func: anytype, Extractor: type) Handler(App, Request) {
    const h = struct {
        fn handle(app: ?App, req: Request, query: []const KeyValue, params: []const KeyValue, allocator: Allocator) !void {
            // the switch doesn't work, if App and Request have the same type!
            const NoApp = struct {};
            const AppType: type = if (App == void and Request == void) NoApp else App;
            if (AppType == Request) {
                @compileError("App: '" ++ @typeName(App) ++ "' and Request: '" ++ @typeName(Request) ++ "' must be diffenrent types");
            }

            const info = @typeInfo(@TypeOf(func));

            // check the function args and create arg-values
            var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            inline for (info.@"fn".params, 0..) |p, i| {
                if (p.type) |ty| {
                    args[i] = switch (ty) {
                        Allocator => allocator,
                        AppType => if (app) |a| a else return error.NoAppDefined,
                        Request => req,
                        Params => Params{ .vars = params },
                        Query => Query{ .vars = query },
                        Body => try Extractor.body(std.json.Value, allocator, req),
                        else => if (@typeInfo(ty) == .@"struct")
                            if (@hasField(ty, TagFieldName))
                                switch (@FieldType(ty, TagFieldName)) {
                                    ParamTag => try FromVars(ty, params),
                                    QueryTag => try FromVars(ty, query),
                                    BodyTag => try Extractor.body(ty, allocator, req),
                                    else => unreachable,
                                }
                            else
                                ty.fromRequest(req)
                        else
                            @compileError("Not supported parameter type for a handler function: " ++ @typeName(ty)),
                    };
                } else {
                    @compileError("Missing type for parameter in function: " ++ @typeName(info.Fn));
                }
            }

            //
            // execute handler function, depending the return value has an error
            //
            // check the return type
            const return_type = ReturnType.new(info.@"fn".return_type.?);
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
                .object => Response(rty){ .content = .{ .object = result } },
                .string => Response(rty){ .content = .{ .string = result } },
            };

            try Extractor.response(rty, allocator, req, resp);
        }
    };

    return Handler(App, Request){ .handle = h.handle };
}

/// ReturnTypes of handler returns
const ReturnType = union(enum) {
    const Self = @This();

    noreturn, // void
    string,
    status, // http.Status
    object,
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
                .object,

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
            object: S,
        } = .{ .string = "" }, // default, no content = ""

        // only for meta programming
        __typeOfCcontent__: S = undefined,
    };
}

/// Marker struct for tagging the P-struct.
const ParamTag = struct {};

/// URL parameter.
pub const Params = KeyValues(ParamTag);

/// Marker, marked the given Struct as Params
pub fn P(comptime S: type) type {
    return structWithTag(S, ParamTag);
}

/// Marker struct for tagging the Q-struct.
const QueryTag = struct {};

/// URL query parameter.
pub const Query = KeyValues(QueryTag);

/// Marker, marked the given Struct as Query
pub fn Q(comptime S: type) type {
    return structWithTag(S, QueryTag);
}

/// Marker struct for tagging the B-struct.
const BodyTag = struct {};

/// Body from request as abstract Json-Value
pub const Body = std.json.Value;

/// Marker, marked the given Struct as Body
pub fn B(comptime S: type) type {
    return structWithTag(S, BodyTag);
}

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
            fn response(T: type, allocator: Allocator, _: void, resp: Response(T)) !void {
                const s = try std.json.stringifyAlloc(allocator, resp.content.object, .{});
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
            fn response(T: type, _: Allocator, _: void, resp: Response(T)) !void {
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
            fn response(T: type, _: Allocator, _: void, resp: Response(T)) !void {
                try std.testing.expectEqualStrings("with error", resp.content.string);
                try std.testing.expectEqual(.ok, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handle string with allocator" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn string(alloc: Allocator, params: Params) ![]const u8 {
                const name: ?[]const u8 = try params.valueAs([]const u8, "name");
                return std.fmt.allocPrint(alloc, "<html>Hello {s}</html>", .{name.?});
            }
        }.string,
        struct {
            fn response(T: type, alloc: Allocator, _: void, resp: Response(T)) !void {
                defer alloc.free(resp.content.string);

                try std.testing.expectEqualStrings("<html>Hello me</html>", resp.content.string);
                try std.testing.expectEqual(.ok, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{.{ .key = "name", .value = "me" }}, std.testing.allocator);
}
test "handler with Response" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUser() Response(User) {
                return .{ .status = .created, .content = .{ .object = .{ .id = 42, .name = "its me" } } };
            }
        }.createUser,
        struct {
            fn response(T: type, _: Allocator, _: void, resp: Response(T)) !void {
                const u: User = resp.content.object;
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
                return .{ .status = .created, .content = .{ .object = .{ .id = 45, .name = "other" } } };
            }
        }.createUserWithError,
        struct {
            fn response(T: type, _: Allocator, _: void, resp: Response(T)) !void {
                const u: User = resp.content.object;
                try std.testing.expectEqual(45, u.id);
                try std.testing.expectEqualStrings("other", u.name);
                try std.testing.expectEqual(.created, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}

test "handler with error!Response with List" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUserWithError(alloc: Allocator) !Response(std.ArrayList(User)) {
                var user_list = std.ArrayList(User).init(alloc);
                try user_list.append(.{ .id = 1, .name = "One" });
                try user_list.append(.{ .id = 2, .name = "Two" });
                return .{ .status = .created, .content = .{ .object = user_list } };
            }
        }.createUserWithError,
        struct {
            fn response(T: type, _: Allocator, _: void, resp: Response(T)) !void {
                const ul: std.ArrayList(User) = resp.content.object;
                defer ul.deinit();

                const user1 = ul.items[0];
                try std.testing.expectEqual(1, user1.id);
                try std.testing.expectEqualStrings("One", user1.name);
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
            fn response(T: type, _: Allocator, _: void, resp: Response(T)) !void {
                try std.testing.expectEqual(.created, resp.status);
            }
        },
    );

    _ = try h.handle(null, undefined, &[_]KeyValue{}, &[_]KeyValue{}, std.testing.allocator);
}
