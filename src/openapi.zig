//! OpenAPI 3.0.3 from Zig types, at comptime: the request and response types
//! are the schema (KickJS needs zod schemas and typegen for this).
const std = @import("std");

/// The JSON Schema of `T`, as JSON text.
pub fn schema(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const out = switch (@typeInfo(T)) {
            .bool => "{\"type\":\"boolean\"}",
            .int => |i| std.fmt.comptimePrint("{{\"type\":\"integer\",\"format\":\"{s}\"{s}}}", .{
                if (i.bits <= 32) "int32" else "int64",
                if (i.signedness == .unsigned) ",\"minimum\":0" else "",
            }),
            .float => |f| if (f.bits <= 32) "{\"type\":\"number\",\"format\":\"float\"}" else "{\"type\":\"number\",\"format\":\"double\"}",
            .@"enum" => |e| blk: {
                var names: []const u8 = "";
                for (e.field_names, 0..) |n, i| names = names ++ (if (i > 0) "," else "") ++ "\"" ++ escape(n) ++ "\"";
                break :blk "{\"type\":\"string\",\"enum\":[" ++ names ++ "]}";
            },
            .optional => |o| blk: {
                const inner = schema(o.child);
                break :blk inner[0 .. inner.len - 1] ++ ",\"nullable\":true}";
            },
            .pointer => |p| if (p.size == .slice and p.child == u8)
                "{\"type\":\"string\"}"
            else if (p.size == .slice)
                "{\"type\":\"array\",\"items\":" ++ schema(p.child) ++ "}"
            else if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)
                "{\"type\":\"string\"}"
            else
                @compileError("no JSON schema for " ++ @typeName(T)),
            .@"struct" => |info| blk: {
                var props: []const u8 = "";
                var required: []const u8 = "";
                for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
                    props = props ++ (if (i > 0) "," else "") ++ "\"" ++ escape(name) ++ "\":" ++ schema(F);
                    if (attrs.defaultValue(F) == null and @typeInfo(F) != .optional)
                        required = required ++ (if (required.len > 0) "," else "") ++ "\"" ++ escape(name) ++ "\"";
                }
                break :blk "{\"type\":\"object\",\"properties\":{" ++ props ++ "}" ++
                    (if (required.len > 0) ",\"required\":[" ++ required ++ "]" else "") ++ "}";
            },
            else => @compileError("no JSON schema for " ++ @typeName(T)),
        };
        const result = out;
        return result;
    }
}

/// `s` as the inside of a JSON string.
pub fn escape(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| out = out ++ switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...0x1f => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
            else => &[_]u8{c},
        };
        const result = out;
        return result;
    }
}

/// One route's part of the spec, built at comptime; adapters get it in
/// `onRouteMount` (`RouteInfo.doc`).
pub const RouteDoc = struct {
    /// Lower-case, as OpenAPI keys it.
    method: []const u8,
    /// `{id}` instead of `:id`.
    path: []const u8,
    /// The OpenAPI operation object, as JSON.
    operation: []const u8,
    tags: []const []const u8,
    exclude: bool,
    bearer_auth: bool,
};

const problem_ref = "{\"application/problem+json\":{\"schema\":{\"$ref\":\"#/components/schemas/ProblemDetails\"}}}";

/// The problem body every 4xx/5xx uses (RFC 9457), for `components.schemas`.
pub const problem_schema = "{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"}," ++
    "\"status\":{\"type\":\"integer\"},\"detail\":{\"type\":\"string\"},\"errors\":{\"type\":\"array\",\"items\":{\"type\":\"object\"," ++
    "\"properties\":{\"field\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"}}}}},\"required\":[\"type\",\"title\",\"status\"]}";

/// Builds a route's doc from its controller and route options (`docs`), the
/// request types its pipeline decodes (`P.Body` / `P.Query` / `P.Params`)
/// and the handler's return type.
pub fn routeDoc(
    comptime method: std.http.Method,
    comptime path: []const u8,
    comptime module_name: []const u8,
    comptime C: type,
    comptime handler: []const u8,
    comptime route: anytype,
    comptime P: type,
) RouteDoc {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const cdocs = if (@hasDecl(C, "docs")) C.docs else .{};
        const rdocs = if (@hasField(@TypeOf(route), "docs")) route.docs else .{};
        const tags: []const []const u8 = opt(rdocs, "tags", opt(cdocs, "tags", @as([]const []const u8, &.{module_name})));
        const bearer = opt(rdocs, "bearer_auth", opt(cdocs, "bearer_auth", false));
        const exclude = opt(rdocs, "exclude", opt(cdocs, "exclude", false));

        var op: []const u8 = "{\"tags\":[";
        for (tags, 0..) |t, i| op = op ++ (if (i > 0) "," else "") ++ "\"" ++ escape(t) ++ "\"";
        op = op ++ "]";
        if (@hasField(@TypeOf(rdocs), "summary")) op = op ++ ",\"summary\":\"" ++ escape(rdocs.summary) ++ "\"";
        if (@hasField(@TypeOf(rdocs), "description")) op = op ++ ",\"description\":\"" ++ escape(rdocs.description) ++ "\"";
        op = op ++ ",\"operationId\":\"" ++ escape(opt(rdocs, "operation_id", @as([]const u8, shortName(C) ++ "_" ++ handler))) ++ "\"";
        if (opt(rdocs, "deprecated", false)) op = op ++ ",\"deprecated\":true";

        const params = parameters(path, P.Params, P.Query);
        if (params.len > 0) op = op ++ ",\"parameters\":[" ++ params ++ "]";
        if (P.Body) |B| op = op ++ ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":" ++ schema(B) ++ "}}}";

        var responses: []const u8 = "";
        if (@hasField(@TypeOf(rdocs), "responses")) {
            for (rdocs.responses) |r| responses = responses ++ (if (responses.len > 0) "," else "") ++
                response(r.status, opt(r, "description", @as([]const u8, "Successful operation")), if (@hasField(@TypeOf(r), "body")) r.body else null);
        } else {
            const status: u16 = switch (method) {
                .POST => 201,
                .DELETE => 204,
                else => 200,
            };
            responses = response(status, "Successful operation", returnSchemaType(C, handler));
        }
        if (P.Body != null) responses = responses ++ ",\"400\":{\"description\":\"Malformed JSON\",\"content\":" ++ problem_ref ++ "}";
        if (P.Body != null or P.Query != null or P.Params != null)
            responses = responses ++ ",\"422\":{\"description\":\"Validation error\",\"content\":" ++ problem_ref ++ "}";
        op = op ++ ",\"responses\":{" ++ responses ++ "}";
        if (bearer) op = op ++ ",\"security\":[{\"BearerAuth\":[]}]";
        op = op ++ "}";

        const final_op = op;
        const final_tags = tags;
        return .{
            .method = lower(@tagName(method)),
            .path = openapiPath(path),
            .operation = final_op,
            .tags = final_tags,
            .exclude = exclude,
            .bearer_auth = bearer,
        };
    }
}

fn response(comptime status: u16, comptime description: []const u8, comptime Body: ?type) []const u8 {
    const content = if (Body) |B|
        ",\"content\":{\"application/json\":{\"schema\":" ++ schema(B) ++ "}}"
    else if (status >= 400)
        ",\"content\":" ++ problem_ref
    else
        "";
    return std.fmt.comptimePrint("\"{d}\":{{\"description\":\"{s}\"{s}}}", .{ status, escape(description), content });
}

/// The JSON-sent part of a handler's return type, or null when it sends
/// nothing describable (`void`, a status, a type with `sendResponse`).
fn returnSchemaType(comptime C: type, comptime handler: []const u8) ?type {
    const R0 = @typeInfo(@TypeOf(@field(C, handler))).@"fn".return_type.?;
    const R = switch (@typeInfo(R0)) {
        .error_union => |e| e.payload,
        else => R0,
    };
    if (R == void or R == std.http.Status) return null;
    if (@typeInfo(R) == .@"struct" and @hasDecl(R, "sendResponse")) return null;
    return R;
}

fn parameters(comptime path: []const u8, comptime Params: ?type, comptime Query: ?type) []const u8 {
    var out: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg[0] != ':' and !std.mem.eql(u8, seg, "*")) continue;
        const name = if (seg[0] == ':') seg[1..] else "wildcard";
        const s = if (Params) |T| (if (@hasField(T, name)) schema(@FieldType(T, name)) else schema([]const u8)) else schema([]const u8);
        out = out ++ (if (out.len > 0) "," else "") ++ "{\"name\":\"" ++ escape(name) ++ "\",\"in\":\"path\",\"required\":true,\"schema\":" ++ s ++ "}";
    }
    if (Query) |Q| {
        if (@hasDecl(Q, "kzig_list_query")) {
            out = out ++ (if (out.len > 0) "," else "") ++ list_query_params;
        } else {
            const info = @typeInfo(Q).@"struct";
            for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
                const required = attrs.defaultValue(F) == null and @typeInfo(F) != .optional;
                const is_list = @typeInfo(F) == .pointer and F != []const u8;
                out = out ++ (if (out.len > 0) "," else "") ++ "{\"name\":\"" ++ escape(name) ++ "\",\"in\":\"query\",\"required\":" ++
                    (if (required) "true" else "false") ++ (if (is_list) ",\"explode\":true" else "") ++ ",\"schema\":" ++ schema(F) ++ "}";
            }
        }
    }
    return out;
}

const list_query_params =
    "{\"name\":\"filter\",\"in\":\"query\",\"required\":false,\"explode\":true,\"description\":\"field:op:value (eq, neq, gt, gte, lt, lte, between, in, contains, starts, ends)\",\"schema\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}," ++
    "{\"name\":\"sort\",\"in\":\"query\",\"required\":false,\"description\":\"-field or field:desc, comma-separated\",\"schema\":{\"type\":\"string\"}}," ++
    "{\"name\":\"page\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":1}}," ++
    "{\"name\":\"limit\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":1}}," ++
    "{\"name\":\"q\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"string\"}}";

fn openapiPath(comptime path: []const u8) []const u8 {
    var out: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| out = out ++ "/" ++ (if (seg[0] == ':') "{" ++ seg[1..] ++ "}" else if (std.mem.eql(u8, seg, "*")) "{wildcard}" else seg);
    return if (out.len == 0) "/" else out;
}

fn lower(comptime s: []const u8) []const u8 {
    var buf: [s.len]u8 = undefined;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const result = buf;
    return &result;
}

/// `ProjectController` from `modules.projects.ProjectController`.
fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    return full[if (std.mem.findScalarLast(u8, full, '.')) |i| i + 1 else 0..];
}

fn opt(comptime spec: anytype, comptime name: []const u8, comptime default: anytype) @TypeOf(default) {
    return if (@hasField(@TypeOf(spec), name)) @field(spec, name) else default;
}

const testing = std.testing;

fn expectSchema(comptime T: type, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, comptime schema(T));
}

const Tag = enum { open, done };

test "scalars" {
    try expectSchema([]const u8, "{\"type\":\"string\"}");
    try expectSchema(u32, "{\"type\":\"integer\",\"format\":\"int32\",\"minimum\":0}");
    try expectSchema(i64, "{\"type\":\"integer\",\"format\":\"int64\"}");
    try expectSchema(f64, "{\"type\":\"number\",\"format\":\"double\"}");
    try expectSchema(bool, "{\"type\":\"boolean\"}");
    try expectSchema(Tag, "{\"type\":\"string\",\"enum\":[\"open\",\"done\"]}");
}

test "optionals and slices" {
    try expectSchema(?[]const u8, "{\"type\":\"string\",\"nullable\":true}");
    try expectSchema([]const u32, "{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"format\":\"int32\",\"minimum\":0}}");
}

test "structs list required fields" {
    const Task = struct {
        title: []const u8,
        done: bool = false,
        note: ?[]const u8,
        tags: []const Tag = &.{},
    };
    try expectSchema(Task, "{\"type\":\"object\",\"properties\":{" ++
        "\"title\":{\"type\":\"string\"}," ++
        "\"done\":{\"type\":\"boolean\"}," ++
        "\"note\":{\"type\":\"string\",\"nullable\":true}," ++
        "\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"enum\":[\"open\",\"done\"]}}" ++
        "},\"required\":[\"title\"]}");
}

test "escape" {
    try testing.expectEqualStrings("a\\\"b\\\\c\\n", comptime escape("a\"b\\c\n"));
}
