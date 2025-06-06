pub const router = @import("router.zig");
pub const HttpError = router.HttpError;
pub const Router = router.Router;
pub const Route = router.Route;

pub const handler = @import("handler.zig");
pub const ResponseWriter = handler.ResponseWriter;

pub const KeyValue = @import("kv.zig").KeyValue;

test {
    _ = @import("./handler.zig");
    _ = @import("./kv.zig");
    _ = @import("./middleware.zig");
    _ = @import("./node.zig");
    _ = @import("./router.zig");
    _ = @import("./tree.zig");
}

// - find first wildcard = parsePath() -> (prefix, suffix, KEY) OR None OR Error
//
// KEY:
//  - static (no parser)    -> match = equals (exact match)
//  - variable              -> match = replace unil '/' or end (ignore suffix!)
//  - wildcard (catch-all)  -> match = until end
//
//  Tree:
//
//  insert: commonPrefixLen (cpl) and remainingPrefixLen (rpl)
//      - cpl == 0 : no prefix found:
//              create a new root and add the child nodes
//              e.g. root: app, new node: foo ->
//              (new_root)
//                  /\
//               app  foo
//      - cpl == rpl :
//          the node already exist and HAS a value? : error OR overwrite?
//      - cpl < rpl
//              split current node and extract the common prefix into a parent.
//              e.g: 'app' on current node; 'apple' is new input -> app ++ le
//      - otherwise, traverse the tree down for the remaining path
//
//
//  search: inputSearchPath (isp) and currentNodePath (cnp)
//      - if isp (remains) len == 0 or remains < cnp EXIT
//      (- isp > cnp)
//      - current node matched IF: isp[..cnp.len] == cnp (exact match)
//          - if child no variable/wildcard -> find child with:w
//
//
