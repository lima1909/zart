//!
//! Run:  zig build zap
//!
const std = @import("std");
const zap = @import("zap");
const zart = @import("zart");
const KeyValue = zart.KeyValue;

const share = @import("zart_share");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const ZapQuery = struct {
    it: zap.Request.ParamSliceIterator,
    len: isize,

    pub fn value(ptr: *const anyopaque, key: []const u8) ?[]const u8 {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        var s: *@This() = @constCast(self); // the iterator want to write

        while (s.it.next()) |param| {
            if (std.mem.eql(u8, param.name, key)) {
                return param.value;
            }
        }
        return null;
    }

    pub fn query(self: *const ZapQuery) zart.handler.Query {
        return .{ .ptr = self, .valueFn = value, .len = @intCast(self.len) };
    }
};

pub const JsonExtractor = struct {
    // convert zap query parameter to zart query parameter
    pub fn query(r: zap.Request) zart.handler.Query {
        r.parseQuery();

        const q = ZapQuery{ .it = r.getParamSlices(), .len = r.getParamCount() };
        return q.query();
    }

    // create parameter objects
    pub fn body(T: type, allocator: std.mem.Allocator, r: zap.Request) !T {
        return try std.json.parseFromSliceLeaky(T, allocator, r.body.?, .{});
    }

    // create response strings
    pub fn response(T: type, allocator: std.mem.Allocator, r: zap.Request, w: *zart.ResponseWriter, resp: ?T) !void {
        if (resp) |resp_body| {
            const content = try std.json.stringifyAlloc(allocator, resp_body, .{});
            try r.sendJson(content);
        }
        r.setStatus(@enumFromInt(@intFromEnum(w.status)));
    }
};

// create your own error-handler
pub const ErrorHandler = struct {
    pub fn handleError(r: zap.Request, err: zart.HttpError) void {
        r.setStatus(@enumFromInt(@intFromEnum(err.status)));
        r.sendBody(err.message) catch |e| {
            std.debug.print("error by sending the response: {} ({s})\n", .{ e, @tagName(err.status) });
        };
    }
}.handleError;

const Router = zart.Router(void, zap.Request, zap.http.Method, JsonExtractor);
var router: Router = undefined;

fn on_request(r: zap.Request) !void {
    router.resolve(r.methodAsEnum(), r.path.?, r, JsonExtractor.query(r));
}

// a second handler which return a static string
fn staticStr(r: zap.Request) !void {
    try r.sendBody("hello world");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    router = try Router.init(
        gpa.allocator(),
        null,
        .{
            zart.Route("/", .{ .{ .GET, share.index }, .{ .POST, share.index } }),
            zart.Route("/str", .{ .GET, staticStr }),
            zart.Route("/echo", .{ .GET, share.echoUser }),
            zart.Route("/params/:id", .{ .GET, share.params }),
            zart.Route("/query", .{ .GET, share.query }), // TODO: query not work in the moment
            zart.Route("/forbidden", .{ .GET, share.forbidden }),
        },
        .configWithMiddleware(
            .{
                .error_handler = ErrorHandler,
            },
            .{
                share.printDurationMiddleware,
            },
        ),
    );
    defer router.deinit();

    var listener = zap.HttpListener.init(.{
        .on_request = on_request,
        .port = 8080,
        .log = false,
        .max_clients = 100,
    });
    try listener.listen();
    std.debug.print("Listening on 127.0.0.1:8080\n", .{});

    zap.start(.{ .threads = 4, .workers = 4 });
}
