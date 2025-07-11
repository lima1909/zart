<div align="center">

# ZART: a Router written in ⚡ZIG ⚡

[![Build Status](https://img.shields.io/github/actions/workflow/status/lima1909/zart/ci.yaml?style=for-the-badge)](https://github.com/lima1909/zart/actions)
![License](https://img.shields.io/github/license/lima1909/zart?style=for-the-badge)
[![Stars](https://img.shields.io/github/stars/lima1909/zart?style=for-the-badge)](https://github.com/lima1909/zart/stargazers)

</div>

`ZART` stands for: `Zig Adaptive Radix Tree` and is an `Router` based on a radix tree.

`ZART` is an abstraction over different implementations: 

- [zap](https://github.com/zigzap/zap)
- [zig-std](https://ziglang.org/documentation/master/std/#std.http.Server)
- [httpz](https://github.com/karlseguin/http.zig)
- ... 

The abstraction are:

- Request
- HTTP Methods
- Extractor (for the body, query and path parameters, response)



This project is an experiment, with the aim of integrating HTTP handlers as  "normal" functions, so it is easy to write tests,
without using "artificial" arguments and return values (like: request and response).

- 🎯 zero dependencies
- 🚀 fast
- 🛠️ easy to develop `Handler` (write unit test) and easy to adapt


## Example (code snippet) for using the Router with the std-Zig-library

See the [examples](https://github.com/lima1909/zart/tree/master/examples) folder for examples.

You can run the examples with the commands:

- example with [zap](https://github.com/zigzap/zap)

```bash
$ zig build zap
```

- example with ZIG std library

```bash
$ zig build std
```

- example for defining a Router

```zig
// An optional (thread safe) App as global context over all requests.
const MyApp = struct {
   database: MyDatabase,
   sessions: MySessionManager,
   ...
};

// create a Router with Routes 
const router = try zart.Router(*MyApp, zap.Request, zap.http.Method, JsonExtractor) 
   .init(
       allocator,
       &myapp,
   .{
       Route("/users/:id", .{ .GET, userByID }),
       Route("/users", .{ get(listUsers), post(createUser) }),
   },
   // configuration:
  .{
       .error_handler = ErrorHandler.handleError,
   },
);

defer router.deinit();
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
// curl -X GET http://localhost:8080/users/42
fn getUser(app: *MyApp, p: Params) !User {
   return try app.database.loadUser(try p.valueAs(i32, "id"));
}

// handler with error and combined response
fn createUserWithError(w: ResponseWriter) !User {
   w.status = .created;
   return .{ .id = 45, .name = "other" };
}

// get the User from the body and return the User to the response.
// curl -X PATCH http://localhost:8080/users -d '{"id": 41, "name": "its me"}'
fn renameUser(user: B(User)) User {
    return .{ .name = "new name" };
}

// possible functions args: the original Request, URL Parameter and Query and a Body from a User. 
// the result is the created User.
fn createUser(r: Request, p: arg.Params, q: arg.Query, b: arg.B(User)) !User { }
```

### Arguments

| Arguments           | Description                                                                    |
|---------------------|--------------------------------------------------------------------------------|
| `Allocator`         | Allocator for creating dynamic objects (Strings, Lists, ...)                   |
| `App`               | The application, the main context (for example: the database connections)      |
| `Request`           | The Request (for example: `std.http.Server.Request`)                           |
| `*ResponseWriter`   | The ResponseWriter, to write the response `Status` or `Headers`                |
| `P(T)` and `Params` | The Request parametes (key-value-pairs)                                        |
| `Q(T)` and `Query`  | The Request query (key-value-pairs)                                            |
| `B(T)` and `Body`   | The Request body, where `b` maps to a user struct and body to `std.json.Value` |
| `fromRequest`       | The Request body                                                               |

### Return

| Return           | Description                                                            |
|------------------|------------------------------------------------------------------------|
| `void`           | no return value                                                        |
| `string`         | The static Response string                                             |
| `object`         | A `object` which can convert to a Response body (Strings, Lists, ...)  |
