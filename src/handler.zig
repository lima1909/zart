const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const KeyValue = @import("kv.zig").KeyValue;

const Params = arg.Params;
const Query = arg.Query;
const Body = arg.Body;

/// The main interface for creating a handler function
pub fn Handler(App: type, Request: type) type {
    return struct {
        handle: *const fn (
            allocator: Allocator,
            app: ?App,
            req: Request,
            w: *ResponseWriter,
            query: []const KeyValue,
            params: []const KeyValue,
        ) anyerror!void,
    };
}

/// Factory to create a Handler for a given function.
pub fn handlerFromFn(App: type, Request: type, func: anytype, Extractor: type) Handler(App, Request) {
    const h = struct {
        fn handle(allocator: Allocator, app: ?App, req: Request, w: *ResponseWriter, query: []const KeyValue, params: []const KeyValue) !void {
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
                        *ResponseWriter => w,
                        Params => Params{ .kvs = params },
                        Query => Query{ .kvs = query },
                        Body => try Extractor.body(std.json.Value, allocator, req),
                        else => if (@typeInfo(ty) == .@"struct")
                            if (@hasField(ty, TagFieldName))
                                switch (@FieldType(ty, TagFieldName)) {
                                    ParamTag => try (Params{ .kvs = params }).into(ty),
                                    QueryTag => try (Query{ .kvs = query }).into(ty),
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
            const result = if (@typeInfo(info.@"fn".return_type.?) == .error_union)
                try @call(.auto, func, args)
            else
                @call(.auto, func, args);

            // check the return type
            const rty = @TypeOf(result);
            switch (@typeInfo(rty)) {
                // error_union can't be nested, so we can return here
                // do nothing
                .void, .noreturn, .error_union => return,
                else => try Extractor.response(rty, allocator, req, w, result),
            }
        }
    };

    return Handler(App, Request){ .handle = h.handle };
}

// The response writer to set the Status or change the Headers.
pub const ResponseWriter = struct {
    status: std.http.Status = .ok,
    header: []const KeyValue = &.{},
};

const ParamTag = struct {};
const QueryTag = struct {};
const BodyTag = struct {};

/// arg is only a namespace for easy import all possible args
pub const arg = struct {
    /// URL parameter.
    pub const Params = KeyValues(ParamTag);
    /// Marker, marked the given Struct as Params
    pub fn P(comptime S: type) type {
        return structWithTag(S, ParamTag);
    }

    /// URL query parameter.
    pub const Query = KeyValues(QueryTag);
    /// Marker, marked the given Struct as Query
    pub fn Q(comptime S: type) type {
        return structWithTag(S, QueryTag);
    }

    /// Body from request as abstract Json-Value
    pub const Body = std.json.Value;
    /// Marker, marked the given Struct as Body
    pub fn B(comptime S: type) type {
        return structWithTag(S, BodyTag);
    }
};

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

fn KeyValues(Tag: type) type {
    return struct {
        const __TAG__: Tag = undefined; // mark the key-values for a specific type
        const Self = @This();

        kvs: []const KeyValue,

        pub inline fn value(self: *const Self, key: []const u8) ?[]const u8 {
            for (self.kvs) |v| {
                if (std.mem.eql(u8, key, v.key)) {
                    return v.value;
                }
            }

            return null;
        }

        pub inline fn valueAs(self: *const Self, T: type, key: []const u8) !?T {
            if (self.value(key)) |v| {
                return switch (@typeInfo(T)) {
                    .int => try std.fmt.parseInt(T, v, 10),
                    .float => try std.fmt.parseFloat(T, v),
                    .bool => {
                        if (std.mem.eql(u8, v, "true")) {
                            return true;
                        } else if (std.mem.eql(u8, v, "false")) {
                            return false;
                        }
                        return error.InvalidBool;
                    },
                    .pointer => |p| if (p.child == u8) v else null,
                    else => @compileError("not supported type: " ++ @typeName(T) ++ " for key: " ++ key),
                };
            }

            return null;
        }

        /// Create an instance of an given Struct from the given key-values.
        fn into(self: *const Self, comptime S: type) !S {
            var instance: S = undefined;

            const info = @typeInfo(S);
            if (info == .@"struct") {
                inline for (info.@"struct".fields) |field| {
                    if (!comptime std.mem.eql(u8, TagFieldName, field.name)) {
                        @field(instance, field.name) = if (try self.valueAs(field.type, field.name)) |val| val else undefined;
                    }
                }
            } else {
                @compileError(std.fmt.comptimePrint("parms T type must be a struct, not: {s}", .{@typeName(S)}));
            }

            return instance;
        }
    };
}

test "key-values" {
    const input = [_]KeyValue{
        .{ .key = "aint", .value = "42" },
        .{ .key = "abool", .value = "true" },
        .{ .key = "afloat", .value = "4.2" },
        .{ .key = "atxt", .value = "foo" },
    };
    const v = KeyValues(void){ .kvs = &input };

    try std.testing.expectEqual(42, (try v.valueAs(i32, "aint")).?);
    try std.testing.expectEqual(4.2, (try v.valueAs(f32, "afloat")).?);
    try std.testing.expectEqual(true, (try v.valueAs(bool, "abool")).?);
    try std.testing.expectEqual("foo", (try v.valueAs([]const u8, "atxt")).?);

    try std.testing.expectEqualStrings("foo", v.value("atxt").?);
    try std.testing.expectEqual(null, v.value("not_exist"));
}

test "fromVars string field" {
    const p = try (KeyValues(void){ .kvs = &[_]KeyValue{
        .{ .key = "name", .value = "Mario" },
    } }).into(struct { name: []const u8 });

    try std.testing.expectEqualStrings("Mario", p.name);
}

test "fromVars bool field" {
    const p = try (KeyValues(void){ .kvs = &[_]KeyValue{
        .{ .key = "maybe", .value = "true" },
    } }).into(struct { maybe: bool });

    try std.testing.expectEqual(true, p.maybe);
}

test "fromVars int and foat field" {
    const p = try (KeyValues(void){ .kvs = &[_]KeyValue{
        .{ .key = "inumber", .value = "42" },
        .{ .key = "fnumber", .value = "2.4" },
    } }).into(struct { inumber: i32, fnumber: f32 });

    try std.testing.expectEqual(42, p.inumber);
    try std.testing.expectEqual(2.4, p.fnumber);
}

test "User Body Arg" {
    const User = struct { id: i32, name: []const u8 };
    const userFn = struct {
        fn user(u: arg.B(User)) User {
            return .{ .id = u.id, .name = u.name };
        }
    }.user;
    const r = userFn(.{ .id = 21, .name = "me" });

    try std.testing.expectEqual(21, r.id);
    try std.testing.expectEqualStrings("me", r.name);
}

test "handler with no args and void return" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn foo() void {}
        }.foo,
        void,
    );

    _ = try h.handle(std.testing.allocator, null, undefined, undefined, &[_]KeyValue{}, &[_]KeyValue{});
}

test "handler with no args and error_union with void return" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn foo() !void {}
        }.foo,
        void,
    );

    _ = try h.handle(std.testing.allocator, null, undefined, undefined, &[_]KeyValue{}, &[_]KeyValue{});
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
            fn response(T: type, allocator: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                const s = try std.json.stringifyAlloc(allocator, resp, .{});
                defer allocator.free(s);

                try std.testing.expectEqualStrings(
                    \\{"id":42,"name":"its me"}
                , s);
                try std.testing.expectEqual(.ok, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{});
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
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                try std.testing.expectEqualStrings("its me", resp);
                try std.testing.expectEqual(.ok, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{});
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
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                try std.testing.expectEqualStrings("with error", resp);
                try std.testing.expectEqual(.ok, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{});
}

test "handle string with allocator" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn string(alloc: Allocator, params: arg.Params) ![]const u8 {
                const name: ?[]const u8 = try params.valueAs([]const u8, "name");
                return std.fmt.allocPrint(alloc, "<html>Hello {s}</html>", .{name.?});
            }
        }.string,
        struct {
            fn response(T: type, alloc: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                defer alloc.free(resp);

                try std.testing.expectEqualStrings("<html>Hello me</html>", resp);
                try std.testing.expectEqual(.ok, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{.{ .key = "name", .value = "me" }});
}
test "handler with Response" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUser(w: *ResponseWriter) User {
                w.status = .created;
                return .{ .id = 42, .name = "its me" };
            }
        }.createUser,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                const u: User = resp;
                try std.testing.expectEqual(42, u.id);
                try std.testing.expectEqualStrings("its me", u.name);
                try std.testing.expectEqual(.created, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{});
}

test "handler with error!Response" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUserWithError(w: *ResponseWriter) !User {
                w.status = .created;
                return .{ .id = 45, .name = "other" };
            }
        }.createUserWithError,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                const u: User = resp;
                try std.testing.expectEqual(45, u.id);
                try std.testing.expectEqualStrings("other", u.name);
                try std.testing.expectEqual(.created, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{});
}

test "handler with error!Response with List" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUserWithError(alloc: Allocator, w: *ResponseWriter) !std.ArrayList(User) {
                var user_list = std.ArrayList(User).init(alloc);
                try user_list.append(.{ .id = 1, .name = "One" });
                try user_list.append(.{ .id = 2, .name = "Two" });

                w.status = .created;
                return user_list;
            }
        }.createUserWithError,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                const ul: std.ArrayList(User) = resp;
                defer ul.deinit();

                const user1 = ul.items[0];
                try std.testing.expectEqual(1, user1.id);
                try std.testing.expectEqualStrings("One", user1.name);
                try std.testing.expectEqual(.created, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{});
    try std.testing.expectEqual(.created, rw.status);
}

test "handler with setting the http-state" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn createUser(w: *ResponseWriter) void {
                w.status = .created;
                return;
            }
        }.createUser,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, _: T) !void {
                try std.testing.expectEqual(.created, w.status);
            }
        },
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, &[_]KeyValue{});
    try std.testing.expectEqual(.created, rw.status);
}
