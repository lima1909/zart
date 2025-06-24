const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const KeyValue = @import("kv.zig").KeyValue;

pub const Query = arg.Query;
pub const Params = arg.Params;
pub const Body = arg.Body;

/// The main interface for creating a handler function
pub fn Handler(App: type, Request: type) type {
    return struct {
        handle: *const fn (
            alloc: Allocator,
            app: ?App,
            req: Request,
            w: *ResponseWriter,
            params: []const KeyValue,
            h: Handle,
        ) anyerror!void,
    };
}

/// Factory to create a Handler for a given function.
pub fn handlerFromFn(App: type, Request: type, Extractor: type, func: anytype) Handler(App, Request) {
    const h = struct {
        fn handle(
            alloc: Allocator,
            app: ?App,
            req: Request,
            w: *ResponseWriter,
            params: []const KeyValue,
            h: Handle,
        ) !void {

            // the switch doesn't work, if App and Request have the same type!
            const NoApp = struct {};
            const AppType: type = if (App == void and Request == void) NoApp else App;
            if (AppType == Request) {
                @compileError("App: '" ++ @typeName(App) ++ "' and Request: '" ++ @typeName(Request) ++ "' must be diffenrent types");
            }

            const info = @typeInfo(@TypeOf(func));
            comptime var withResponseWriter = false;

            // check the function args and create arg-values
            var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            inline for (info.@"fn".params, 0..) |p, i| {
                if (p.type) |ty| {
                    args[i] = switch (ty) {
                        Allocator => alloc,
                        AppType => if (app) |a| a else return error.NoAppDefined,
                        Request => req,
                        *ResponseWriter => blk: {
                            withResponseWriter = true;
                            break :blk w;
                        },
                        ResponseWriter => @compileError("please use '*ResponseWriter' instead of 'ResponseWriter'"),
                        Handle => h,
                        Params => Params{ .kvs = params },
                        Query => Extractor.query(alloc, &req),
                        Body => try Extractor.body(std.json.Value, alloc, req),
                        else => if (@typeInfo(ty) == .@"struct")
                            if (@hasField(ty, TagFieldName))
                                switch (@FieldType(ty, TagFieldName)) {
                                    ParamTag => try createStructFromKV(ty, Params{ .kvs = params }),
                                    QueryTag => try createStructFromKV(ty, Extractor.query(alloc, &req)),
                                    BodyTag => try Extractor.body(ty, alloc, req),
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
                // error_union can't be nested, so we can return here, do nothing
                .error_union => return,
                .void => {
                    // there is no Body, but the ResponseWriter needs to have an Extractor
                    if (withResponseWriter) {
                        try Extractor.response(?[]const u8, alloc, req, w, null);
                    }
                },
                else => try Extractor.response(rty, alloc, req, w, result),
            }
        }
    };

    return Handler(App, Request){ .handle = h.handle };
}

/// Handle is an Iterator over all Middleware Handler-Functions.
pub const Handle = struct {
    ptr: *anyopaque,
    nextFn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn next(self: Handle) !void {
        return self.nextFn(self.ptr);
    }
};

/// NoHandle implement the Handle interface, but do nothing.
pub fn noHandle() Handle {
    return .{
        .ptr = undefined, // we never use this pointer
        .nextFn = struct {
            pub fn next(_: *anyopaque) !void {}
        }.next,
    };
}

/// Executor execute all Handlers saved in the Middleware and after that, the Route-Hanlder will be execute.
pub fn Executor(App: type, Request: type) type {
    return struct {
        const Self = @This();

        index: usize,
        middleware: Middleware(App, Request),
        handler: ?Handler(App, Request) = null,

        // all parameter for calling the Middleware-Handler
        // and the Handler for the route, if it exist
        alloc: Allocator = undefined,
        app: ?App = null,
        req: Request = undefined,
        w: *ResponseWriter = undefined,
        params: []const KeyValue = undefined,

        /// start: execute the first Handler
        /// The next Handler is executing by calling next()
        pub fn initAndStart(
            alloc: Allocator,
            middleware: Middleware(App, Request),
            app: ?App,
            req: Request,
            w: *ResponseWriter,
            params: []const KeyValue,
            handler: ?Handler(App, Request),
        ) !Self {
            var self = Self{
                .index = 0,
                .middleware = middleware,
                .alloc = alloc,
                .app = app,
                .req = req,
                .w = w,
                .params = params,
                .handler = handler,
            };

            try next(&self);
            return self;
        }

        pub fn next(ptr: *anyopaque) !void {
            var self: *Self = @ptrCast(@alignCast(ptr));

            if (self.middleware.next(self.index)) |h| {
                self.index += 1;
                return h.handle(self.alloc, self.app, self.req, self.w, self.params, self.handle());
            }

            // all Middleware-Handlers are called
            else if (self.index == self.middleware.len) {
                self.index += 1;
                // if and Handler from the route is defined, than call this Handler
                if (self.handler) |h| {
                    return h.handle(self.alloc, self.app, self.req, self.w, self.params, self.handle());
                }
            }
        }

        pub fn handle(self: *Self) Handle {
            return .{
                .ptr = self,
                .nextFn = next,
            };
        }
    };
}

// Iterator over handlers
pub fn Middleware(App: type, Request: type) type {
    return struct {
        len: usize = 0,
        next: *const fn (usize) ?Handler(App, Request),
    };
}

/// Factory to create a Middleware from a given list of Handler-Functions: funcs.
pub inline fn middlewareFromFns(App: type, Request: type, Extractor: type, funcs: anytype) Middleware(App, Request) {
    comptime var handlers: [funcs.len]Handler(App, Request) = undefined;

    for (funcs, 0..) |f, i| {
        handlers[i] = handlerFromFn(App, Request, Extractor, f);
    }

    const hanlde = struct {
        fn next(index: usize) ?Handler(App, Request) {
            if (index >= handlers.len) {
                return null;
            }

            return handlers[index];
        }
    };

    return .{
        .len = handlers.len,
        .next = hanlde.next,
    };
}

/// The response writer to set the Status or change the Headers.
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
    pub const Params = struct {
        kvs: []const KeyValue,

        pub inline fn value(self: *const @This(), key: []const u8) ?[]const u8 {
            for (self.kvs) |v| {
                if (std.mem.eql(u8, key, v.key)) {
                    return v.value;
                }
            }

            return null;
        }

        pub inline fn valueAs(self: *const @This(), T: type, key: []const u8) !?T {
            return stringValueAs(T, self.value(key));
        }
    };

    /// Marker, marked the given Struct as Params
    pub fn P(comptime S: type) type {
        return structWithTag(S, ParamTag);
    }

    /// URL query parameter.
    pub const Query = struct {
        ptr: *const anyopaque,
        valueFn: *const fn (ptr: *const anyopaque, key: []const u8) ?[]const u8,
        len: ?usize,

        pub fn init(
            ptr: anytype,
            comptime valueFn: fn (ptr: @TypeOf(ptr), key: []const u8) callconv(.@"inline") ?[]const u8,
            len: ?usize,
        ) @This() {
            const Ptr = @TypeOf(ptr);
            const gen = struct {
                fn value(p: *const anyopaque, key: []const u8) ?[]const u8 {
                    const self: Ptr = @ptrCast(@alignCast(p));
                    return valueFn(self, key);
                }
            };

            return .{
                .ptr = ptr,
                .valueFn = gen.value,
                .len = len,
            };
        }

        /// Is a mapping from a given Key to the Value.
        /// For example by a Query: ?foo=bar, return Value: bar for given Key: foo
        pub inline fn value(self: *const @This(), key: []const u8) ?[]const u8 {
            return self.valueFn(self.ptr, key);
        }

        pub inline fn valueAs(self: *const @This(), T: type, key: []const u8) !?T {
            return stringValueAs(T, self.value(key));
        }
    };

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

/// Convert a string value in a concrete Value
inline fn stringValueAs(T: type, value: ?[]const u8) !?T {
    if (value) |v| {
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
            .pointer => |p| if (p.child == u8) v else @compileError("not supported type: " ++ @typeName(T) ++ " for value: " ++ value),
            else => @compileError("not supported type: " ++ @typeName(T) ++ " for value: " ++ value),
        };
    }

    return null;
}

/// Field name for the Tags.
const TagFieldName = "__TAG__";

/// Create an instance of an given Struct from the given key-values.
fn createStructFromKV(comptime S: type, v: anytype) !S {
    var instance: S = undefined;

    const info = @typeInfo(S);
    if (info == .@"struct") {
        inline for (info.@"struct".fields) |field| {
            if (!comptime std.mem.eql(u8, TagFieldName, field.name)) {
                const string_value = v.value(field.name);
                @field(instance, field.name) = if (try stringValueAs(field.type, string_value)) |val| val else undefined;
            }
        }
    } else {
        @compileError(std.fmt.comptimePrint("parms T type must be a struct, not: {s}", .{@typeName(S)}));
    }

    return instance;
}

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

test "Params" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "aint", .value = "42" },
            .{ .key = "abool", .value = "true" },
            .{ .key = "afloat", .value = "4.2" },
            .{ .key = "atxt", .value = "foo" },
        },
    };

    try std.testing.expectEqual(42, (try p.valueAs(i32, "aint")).?);
    try std.testing.expectEqual(4.2, (try p.valueAs(f32, "afloat")).?);
    try std.testing.expectEqual(true, (try p.valueAs(bool, "abool")).?);
    try std.testing.expectEqual("foo", (try p.valueAs([]const u8, "atxt")).?);

    try std.testing.expectEqualStrings("foo", p.value("atxt").?);
    try std.testing.expectEqual(null, p.value("not_exist"));
}

test "Params to struct instance" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "name", .value = "Mario" },
            .{ .key = "maybe", .value = "true" },
            .{ .key = "inumber", .value = "42" },
            .{ .key = "fnumber", .value = "2.4" },
        },
    };

    const s = struct {
        name: []const u8,
        maybe: bool,
        inumber: i32,
        fnumber: f32,
    };

    const instance = try createStructFromKV(s, p);

    try std.testing.expectEqualStrings("Mario", instance.name);
    try std.testing.expectEqual(true, instance.maybe);
    try std.testing.expectEqual(42, instance.inumber);
    try std.testing.expectEqual(2.4, instance.fnumber);
}

test "Query" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "aint", .value = "42" },
            .{ .key = "abool", .value = "true" },
            .{ .key = "afloat", .value = "4.2" },
            .{ .key = "atxt", .value = "foo" },
        },
    };
    const q = Query.init(&p, Params.value, p.kvs.len);

    try std.testing.expectEqual(4, q.len.?);

    try std.testing.expectEqual(42, (try q.valueAs(i32, "aint")).?);
    try std.testing.expectEqual(4.2, (try q.valueAs(f32, "afloat")).?);
    try std.testing.expectEqual(true, (try q.valueAs(bool, "abool")).?);
    try std.testing.expectEqual("foo", (try q.valueAs([]const u8, "atxt")).?);

    try std.testing.expectEqualStrings("foo", q.value("atxt").?);
    try std.testing.expectEqual(null, q.value("not_exist"));
}

test "Query to struct instance" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "name", .value = "Mario" },
            .{ .key = "maybe", .value = "true" },
            .{ .key = "inumber", .value = "42" },
            .{ .key = "fnumber", .value = "2.4" },
        },
    };
    const q = Query.init(&p, Params.value, p.kvs.len);

    const s = struct {
        name: []const u8,
        maybe: bool,
        inumber: i32,
        fnumber: f32,
    };

    const instance = try createStructFromKV(s, q);
    try std.testing.expectEqualStrings("Mario", instance.name);
    try std.testing.expectEqual(true, instance.maybe);
    try std.testing.expectEqual(42, instance.inumber);
    try std.testing.expectEqual(2.4, instance.fnumber);
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

test "handler with ResponseWriter" {
    const Extractor = struct {
        pub fn query(_: std.mem.Allocator, _: *const void) Query {
            return undefined;
        }

        pub fn response(T: type, _: std.mem.Allocator, _: void, _: *ResponseWriter, _: T) !void {}
    };

    const h = handlerFromFn(
        void,
        void,
        Extractor,
        struct {
            fn foo(w: *ResponseWriter) void {
                w.status = .bad_request;
            }
        }.foo,
    );

    var w = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &w, &[_]KeyValue{}, undefined);
    try std.testing.expectEqual(.bad_request, w.status);
}

test "handler with no args and void return" {
    const h = handlerFromFn(
        void,
        void,
        void,
        struct {
            fn foo() void {}
        }.foo,
    );

    _ = try h.handle(std.testing.allocator, null, undefined, undefined, &[_]KeyValue{}, undefined);
}

test "handler with no args and error_union with void return" {
    const h = handlerFromFn(
        void,
        void,
        void,
        struct {
            fn foo() !void {}
        }.foo,
    );

    _ = try h.handle(std.testing.allocator, null, undefined, undefined, &[_]KeyValue{}, undefined);
}

test "handler response with body" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
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
        struct {
            fn getUser() User {
                return .{ .id = 42, .name = "its me" };
            }
        }.getUser,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, undefined);
}

test "handle static string" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                try std.testing.expectEqualStrings("its me", resp);
                try std.testing.expectEqual(.ok, w.status);
            }
        },
        struct {
            fn string() []const u8 {
                return "its me";
            }
        }.string,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, undefined);
}

test "handle error!static string" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                try std.testing.expectEqualStrings("with error", resp);
                try std.testing.expectEqual(.ok, w.status);
            }
        },
        struct {
            fn string() ![]const u8 {
                return "with error";
            }
        }.string,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, undefined);
}

test "handle string with allocator" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn response(T: type, alloc: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                defer alloc.free(resp);

                try std.testing.expectEqualStrings("<html>Hello me</html>", resp);
                try std.testing.expectEqual(.ok, w.status);
            }
        },
        struct {
            fn string(alloc: Allocator, params: arg.Params) ![]const u8 {
                const name: ?[]const u8 = try params.valueAs([]const u8, "name");
                return std.fmt.allocPrint(alloc, "<html>Hello {s}</html>", .{name.?});
            }
        }.string,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{.{ .key = "name", .value = "me" }}, undefined);
}
test "handler with Response" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                const u: User = resp;
                try std.testing.expectEqual(42, u.id);
                try std.testing.expectEqualStrings("its me", u.name);
                try std.testing.expectEqual(.created, w.status);
            }
        },
        struct {
            fn createUser(w: *ResponseWriter) User {
                w.status = .created;
                return .{ .id = 42, .name = "its me" };
            }
        }.createUser,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, undefined);
}

test "handler with error!Response" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, resp: T) !void {
                const u: User = resp;
                try std.testing.expectEqual(45, u.id);
                try std.testing.expectEqualStrings("other", u.name);
                try std.testing.expectEqual(.created, w.status);
            }
        },
        struct {
            fn createUserWithError(w: *ResponseWriter) !User {
                w.status = .created;
                return .{ .id = 45, .name = "other" };
            }
        }.createUserWithError,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, undefined);
}

test "handler with error!Response with List" {
    const User = struct { id: i32, name: []const u8 };

    const h = handlerFromFn(
        void,
        void,
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
        struct {
            fn createUserWithError(alloc: Allocator, w: *ResponseWriter) !std.ArrayList(User) {
                var user_list = std.ArrayList(User).init(alloc);
                try user_list.append(.{ .id = 1, .name = "One" });
                try user_list.append(.{ .id = 2, .name = "Two" });

                w.status = .created;
                return user_list;
            }
        }.createUserWithError,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, undefined);
    try std.testing.expectEqual(.created, rw.status);
}

test "handler with setting the http-state" {
    const h = handlerFromFn(
        void,
        void,
        struct {
            fn response(T: type, _: Allocator, _: void, w: *ResponseWriter, _: T) !void {
                try std.testing.expectEqual(.created, w.status);
            }
        },
        struct {
            fn createUser(w: *ResponseWriter) void {
                w.status = .created;
                return;
            }
        }.createUser,
    );

    var rw = ResponseWriter{};
    _ = try h.handle(std.testing.allocator, null, undefined, &rw, &[_]KeyValue{}, undefined);
    try std.testing.expectEqual(.created, rw.status);
}

test "middleware handlers" {
    const middleware = struct {
        fn hanlder1(r: *i32) void {
            r.* += 1;
        }
        fn hanlder2(r: *i32) void {
            r.* += 2;
        }
        fn hanlder4(r: *i32) void {
            r.* += 4;
        }
    };

    const mw = comptime middlewareFromFns(
        void,
        *i32,
        void,
        .{
            middleware.hanlder1,
            middleware.hanlder2,
            middleware.hanlder4,
        },
    );

    var w = ResponseWriter{};
    var req: i32 = 0;

    const E = Executor(void, *i32);
    var exec = try E.initAndStart(std.testing.allocator, mw, null, &req, &w, undefined, null);

    try std.testing.expectEqual(1, req);

    try E.next(&exec);
    try std.testing.expectEqual(3, req);
    try E.next(&exec);
    try std.testing.expectEqual(7, req);

    // no more middleware exist
    try E.next(&exec);
    try std.testing.expectEqual(7, req);
}

test "middleware handlers with cancel" {
    const middleware = struct {
        fn hanlder1(r: *i32) void {
            r.* += 1;
        }
        fn hanlder2(r: *i32) void {
            r.* += 2;
        }
        fn hanlder4() !void {
            // throw an error, no next Handler is executing
            return error.MiddlewareError;
        }
    };

    const mw = comptime middlewareFromFns(
        void,
        *i32,
        void,
        .{
            middleware.hanlder1,
            middleware.hanlder2,
            middleware.hanlder4,
        },
    );

    var req: i32 = 0;
    var w = ResponseWriter{};

    const E = Executor(void, *i32);
    var exec = try E.initAndStart(std.testing.allocator, mw, null, &req, &w, undefined, null);
    try std.testing.expectEqual(1, req);

    try E.next(&exec);
    try std.testing.expectEqual(3, req);

    E.next(&exec) catch |err| {
        try std.testing.expectEqual(error.MiddlewareError, err);
    };
}

test "middleware handlers with route Handler" {
    const def = struct {
        fn middleware(r: *i32) void {
            r.* += 1;
        }
        fn handler(r: *i32) void {
            r.* += 2;
        }
    };

    const mw = comptime middlewareFromFns(
        void,
        *i32,
        void,
        .{
            def.middleware,
        },
    );

    var w = ResponseWriter{};
    var req: i32 = 0;

    const E = Executor(void, *i32);
    var exec = try E.initAndStart(
        std.testing.allocator,
        mw,
        null,
        &req,
        &w,
        undefined,
        handlerFromFn(void, *i32, void, def.handler),
    );

    // calling the middleware
    try std.testing.expectEqual(1, req);

    // calling the handler
    try E.next(&exec);
    try std.testing.expectEqual(3, req);

    // no more middleware exist
    try E.next(&exec);
    try std.testing.expectEqual(3, req);
}
