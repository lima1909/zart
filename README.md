<div align="center">

# ZART

[![Build Status](https://img.shields.io/github/actions/workflow/status/lima1909/zart/ci.yaml?style=for-the-badge)](https://github.com/lima1909/zart/actions)
![License](https://img.shields.io/github/license/lima1909/zart?style=for-the-badge)
[![Stars](https://img.shields.io/github/stars/lima1909/zart?style=for-the-badge)](https://github.com/lima1909/zart/stargazers)

</div>

ZART stands for: `Zig Adaptive Radix Tree` and is an router based on a radix tree.

This project is an experiment, with the aim of integrating HTTP handlers as  "normal" functions, so it is easy to write tests,
without using "artificial" arguments and return values (request and response).

## Router

```zig
const std = @import("std");
const http = std.http;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const MyApp = struct {
  // DB connection
  // global and exchange data
};

var app = App{};

var router = Router(MyApp, http.Server.Request, JsonExtractor).initWithApp(allocator, &app, .{});
defer router.deinit();

try router.post("/user", createUser);


const User = struct { id: i32, name: []const u8 };

// possible functions arg: the original Request, URL Parameter and Query and a Body from a User. 
fn createUser(r: http.Server.Request, p: Params, q: Query, b: B(User)) !Response(User) { }
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
   return .{ .status = .created, .content = .{ .strukt = .{ .id = 45, .name = "other" } } };
}

// get the User from the body and return the User to the response.
fn renameUser(user: B(User)) User {
    return .{ .name = "new name" };
}
```

### Arguments

| Arguments        | Description                                                                    |
|------------------|--------------------------------------------------------------------------------|
| `Allocator`      | Allocator for creating dynamic objects (Strings, Lists, ...)                   |
| `App`            | The application, the main context (for example: the database connections)      |
| `Request`        | The Request (for example: `std.http.Server.Request`)                           |
| `P` and `Params` | The Request parametes (key-value-pairs)                                        |
| `Q` and `Query`  | The Request query (key-value-pairs)                                            |
| `B` and `Body`   | The Request body, where `b` maps to a user struct and body to `std.json.Value` |
| `fromRequest`    | The Request body                                                               |

### Return

| Return           | Description                                                            |
|------------------|------------------------------------------------------------------------|
| `noreturn`       | `void` no return value                                                 |
| `string`         | The static Response string (error message)                             |
| `status`         | The Response status                                                    |
| `object`         | A `object` which can convert to a Response body (Strings, Lists, ...)  |
| `response`       | Combine a Response with status and body                                |
