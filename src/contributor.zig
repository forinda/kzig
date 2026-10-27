//! Context contributors (KickJS `defineContextDecorator`), resolved at
//! comptime: a route's contributors are merged by precedence, ordered by what
//! each one's `got` parameter reads, and every read is checked against what
//! the route provides — a dropped contributor is a compile error, not a
//! `ctx.get` that fails open.
//!
//! A contributor is a service struct with `pub const key`, and
//! `pub fn resolve(self, ctx) !V` or `resolve(self, ctx, got: struct { … })`.
//! `pub const optional = true` turns an error into `null`;
//! `pub const before_validation = true` runs it before validation and
//! route middleware.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;

pub fn isContributor(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "key") and @hasDecl(T, "resolve");
}

/// What `resolve` returns, without its error set.
pub fn Value(comptime C: type) type {
    const R = @typeInfo(@TypeOf(C.resolve)).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |e| e.payload,
        else => R,
    };
}

pub fn isOptional(comptime C: type) bool {
    return @hasDecl(C, "optional") and C.optional;
}

fn isEarly(comptime C: type) bool {
    return @hasDecl(C, "before_validation") and C.before_validation;
}

/// The `got` struct a function takes as its third parameter, if any.
pub fn GotOf(comptime f: anytype) ?type {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return if (params.len == 3) params[2].? else null;
}

/// Contributor entries (a tuple of types) as a slice.
pub fn types(comptime entries: anytype, comptime where: []const u8) []const type {
    comptime {
        var out: []const type = &.{};
        for (entries) |e| {
            if (@TypeOf(e) != type or !isContributor(e))
                @compileError(where ++ ": contributor must be a struct with `pub const key` and `pub fn resolve`");
            out = out ++ .{e};
        }
        const result = out;
        return result;
    }
}

/// `levels` from lowest to highest precedence: global, module, controller,
/// method. `handler_got` is the handler's `got` struct, if it takes one.
pub fn Plan(comptime levels: [4][]const type, comptime handler_got: ?type, comptime where: []const u8) type {
    comptime {
        var merged: []const type = &.{};
        for (levels) |level| {
            for (level, 0..) |C, i| {
                for (level[0..i]) |D| if (std.mem.eql(u8, C.key, D.key))
                    @compileError(where ++ ": contributor key '" ++ C.key ++ "' registered twice");
                merged = shadow(merged, C);
            }
        }
        for (merged) |C| {
            if (GotOf(C.resolve)) |G| checkGot(merged, G, where, @typeName(C) ++ ".resolve");
        }
        if (handler_got) |G| checkGot(merged, G, where, "the handler");

        const sorted = topoSort(merged, where);
        var early: []const type = &.{};
        var late: []const type = &.{};
        for (sorted) |C| {
            if (isEarly(C)) {
                if (GotOf(C.resolve)) |G| for (@typeInfo(G).@"struct".field_names) |f| {
                    if (!isEarly(byKey(merged, f).?))
                        @compileError(where ++ ": early contributor '" ++ C.key ++ "' reads '" ++ f ++ "', which runs later");
                };
                early = early ++ .{C};
            } else late = late ++ .{C};
        }

        var names: [merged.len][]const u8 = undefined;
        var field_types: [merged.len]type = undefined;
        var attrs: [merged.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (merged, 0..) |C, i| {
            const F = ?Value(C);
            const none: F = null;
            names[i] = C.key;
            field_types[i] = F;
            attrs[i] = .{ .default_value_ptr = @ptrCast(&none) };
        }
        const early_final = early;
        const late_final = late;
        const StoreT = @Struct(.auto, null, &names, &field_types, &attrs);
        return struct {
            pub const early_order: []const type = early_final;
            pub const late_order: []const type = late_final;
            /// One `?V` per key; null until its contributor ran (or failed, if optional).
            pub const Store = StoreT;
        };
    }
}

/// `C` replaces a lower-precedence contributor with the same key.
fn shadow(comptime list: []const type, comptime C: type) []const type {
    var out: []const type = &.{};
    for (list) |D| {
        if (!std.mem.eql(u8, D.key, C.key)) out = out ++ .{D};
    }
    return out ++ .{C};
}

fn byKey(comptime list: []const type, comptime key: []const u8) ?type {
    for (list) |C| if (std.mem.eql(u8, C.key, key)) return C;
    return null;
}

fn checkGot(comptime merged: []const type, comptime G: type, comptime where: []const u8, comptime reader: []const u8) void {
    const info = @typeInfo(G).@"struct";
    for (info.field_names, info.field_types) |f, F| {
        const C = byKey(merged, f) orelse
            @compileError(where ++ ": " ++ reader ++ " needs '" ++ f ++ "' but no contributor on this route provides it");
        const V = Value(C);
        if (isOptional(C)) {
            if (F != ?V) @compileError(where ++ ": '" ++ f ++ "' is optional; " ++ reader ++ " must declare it as " ++ @typeName(?V));
        } else if (F != V) {
            @compileError(where ++ ": '" ++ f ++ "' is " ++ @typeName(V) ++ ", not " ++ @typeName(F) ++ " (in " ++ reader ++ ")");
        }
    }
}

fn topoSort(comptime merged: []const type, comptime where: []const u8) []const type {
    const Walk = struct {
        state: [merged.len]enum { new, active, done } = @splat(.new),
        out: []const type = &.{},
        path: []const u8 = "",

        fn visit(w: *@This(), i: usize) void {
            const C = merged[i];
            switch (w.state[i]) {
                .done => return,
                .active => @compileError(where ++ ": contributor cycle " ++ w.path ++ C.key),
                .new => {},
            }
            w.state[i] = .active;
            const saved = w.path;
            w.path = w.path ++ C.key ++ " -> ";
            if (GotOf(C.resolve)) |G| for (@typeInfo(G).@"struct".field_names) |f| {
                for (merged, 0..) |D, j| if (std.mem.eql(u8, D.key, f)) w.visit(j);
            };
            w.path = saved;
            w.state[i] = .done;
            w.out = w.out ++ .{C};
        }
    };
    var w: Walk = .{};
    for (0..merged.len) |i| w.visit(i);
    return w.out;
}

/// Fills a `got` struct from the store; non-optional reads are known set.
pub fn fill(comptime G: type, store: anytype) G {
    var g: G = undefined;
    inline for (@typeInfo(G).@"struct".field_names, @typeInfo(G).@"struct".field_types) |f, F| {
        const v = @field(store, f);
        @field(g, f) = if (@TypeOf(v) == F) v else v.?;
    }
    return g;
}

/// Runs contributor `C` (instance `inst`) into `store`.
pub fn run(comptime C: type, inst: *C, ctx: *Ctx, store: anytype) !void {
    const r = if (comptime GotOf(C.resolve)) |G| C.resolve(inst, ctx, fill(G, store.*)) else C.resolve(inst, ctx);
    const is_err = @typeInfo(@TypeOf(r)) == .error_union;
    @field(store, C.key) = if (comptime isOptional(C))
        (if (is_err) (r catch null) else r)
    else if (is_err) try r else r;
}
