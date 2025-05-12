<div align="center">

# ZART: a router written in ⚡ZIG ⚡

[![Build Status](https://img.shields.io/github/actions/workflow/status/lima1909/zart/ci.yaml?style=for-the-badge)](https://github.com/lima1909/zart/actions)
![License](https://img.shields.io/github/license/lima1909/zart?style=for-the-badge)
[![Stars](https://img.shields.io/github/stars/lima1909/zart?style=for-the-badge)](https://github.com/lima1909/zart/stargazers)

</div>

ZART stands for: `Zig Adaptive Radix Tree` and is an router based on a radix tree.

This project is an experiment, with the aim of integrating HTTP handlers as  "normal" functions, so it is easy to write tests,
without using "artificial" arguments and return values (like: request and response).

- 🎯 zero dependencies
- 🚀 (blazing) fast
- 🛠️ easy to develop and to write unit test for `Handler`


## Example (code snippet) for using the Router with the std-Zig-library

See the [examples](https://github.com/lima1909/zart/tree/master/examples) folder for examples.

You can run the example with the command:

```bash
$ zig build zart_std
```

```zig
const std = @import("std");
const zart = @import("zart.zig");
const Route = zart.Route;
const arg = zart.handler.arg;

// create a Router with Routes
const router = try zart.NewRouter(http.Server.Request).init(allocator, .{
     Route("/users/:id", .{ .GET, userByID }),
     Route("/users", .{ get(listUsers), post(createUser) }),
}, .{
    .Extractor = zart.server.JsonExtractor,
    .error_handler = zart.server.ErrorHandler.handleError,
});
defer router.deinit();

// very simple HTTP server from the std library
const addr = try std.net.Address.resolveIp("127.0.0.1", 8080);
var listener = try addr.listen(.{ .reuse_address = true });
std.debug.print("Listening on {}\n", .{addr});

while (true) {
   // handle connection with routing
    try zart.server.handleConnection(void, &router, try listener.accept());
}

// possible functions args: the original Request, URL Parameter and Query and a Body from a User. 
// the result is the created User.
fn createUser(r: http.Server.Request, p: arg.Params, q: arg.Query, b: arg.B(User)) !Response(User) { }
```

## Handler

```zig
// returning a simple static string and status code OK.
// maybe for simple html or static json.
fn staticString() []const u8 {
   return "its me";
}

const User = struct { id: i32, name: []const u8 };

// this is an handler, which return an User object with status code OK.
fn getUser() User {
   return .{ .id = 42, .name = "its me" };
}

// handler with error and combined response
fn createUserWithError() !Response(User) {
   return .{ .status = .created, .content = .{ .object= .{ .id = 45, .name = "other" } } };
}

// get the User from the body and return the User to the response.
fn renameUser(user: B(User)) User {
    return .{ .name = "new name" };
}
```

### Arguments

| Arguments           | Description                                                                    |
|---------------------|--------------------------------------------------------------------------------|
| `Allocator`         | Allocator for creating dynamic objects (Strings, Lists, ...)                   |
| `App`               | The application, the main context (for example: the database connections)      |
| `Request`           | The Request (for example: `std.http.Server.Request`)                           |
| `P(T)` and `Params` | The Request parametes (key-value-pairs)                                        |
| `Q(T)` and `Query`  | The Request query (key-value-pairs)                                            |
| `B(T)` and `Body`   | The Request body, where `b` maps to a user struct and body to `std.json.Value` |
| `fromRequest`       | The Request body                                                               |

### Return

| Return           | Description                                                            |
|------------------|------------------------------------------------------------------------|
| `void`           | no return value                                                 |
| `string`         | The static Response string (error message)                             |
| `status`         | The Response status                                                    |
| `object`         | A `object` which can convert to a Response body (Strings, Lists, ...)  |
| `response`       | Combine a Response with status and body                                |
