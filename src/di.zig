//! Comptime DI. Every service is one singleton slot in the container; a field
//! typed `*S` or `*const S` is wired to the slot of `S`, so a missing service
//! is a compile error instead of KickJS's runtime "No provider for X".
const std = @import("std");

/// `types` without repeats, first occurrence kept: a service listed by two
/// modules is still one singleton.
pub fn unique(comptime types: []const type) []const type {
    comptime {
        var out: []const type = &.{};
        for (types) |T| {
            if (indexOf(out, T) == null) out = out ++ .{T};
        }
        const result = out;
        return result;
    }
}

fn indexOf(comptime types: []const type, comptime T: type) ?usize {
    inline for (types, 0..) |U, i| if (U == T) return i;
    return null;
}

/// The service a field is wired to, or null for a plain field.
fn depOf(comptime services: []const type, comptime S: type, comptime name: []const u8, comptime F: type) ?usize {
    const p = switch (@typeInfo(F)) {
        .pointer => |p| p,
        else => return null,
    };
    if (p.size != .one) return null;
    return indexOf(services, p.child) orelse
        @compileError(@typeName(S) ++ "." ++ name ++ ": no service " ++ @typeName(p.child));
}

/// Service indices with every service after its dependencies.
fn initOrder(comptime services: []const type) [services.len]usize {
    comptime {
        const Walk = struct {
            state: [services.len]enum { new, active, done } = @splat(.new),
            order: [services.len]usize = undefined,
            len: usize = 0,
            path: []const u8 = "",

            fn visit(w: *@This(), i: usize) void {
                const S = services[i];
                switch (w.state[i]) {
                    .done => return,
                    .active => @compileError("dependency cycle: " ++ w.path ++ @typeName(S)),
                    .new => {},
                }
                w.state[i] = .active;
                const saved = w.path;
                w.path = w.path ++ @typeName(S) ++ " -> ";
                const info = @typeInfo(S).@"struct";
                for (info.field_names, info.field_types) |name, F| {
                    if (depOf(services, S, name, F)) |d| w.visit(d);
                }
                w.path = saved;
                w.state[i] = .done;
                w.order[w.len] = i;
                w.len += 1;
            }
        };
        var w: Walk = .{};
        for (0..services.len) |i| w.visit(i);
        const result = w.order;
        return result;
    }
}

fn checkHooks(comptime S: type) void {
    if (@hasDecl(S, "init")) {
        const f = @typeInfo(@TypeOf(S.init)).@"fn";
        const R = f.return_type.?;
        const ok_ret = R == void or (@typeInfo(R) == .error_union and @typeInfo(R).error_union.payload == void);
        if (f.param_types.len != 1 or f.param_types[0] != *S or !ok_ret)
            @compileError(@typeName(S) ++ ".init must be fn (*" ++ @typeName(S) ++ ") !void");
    }
    if (@hasDecl(S, "deinit")) {
        const f = @typeInfo(@TypeOf(S.deinit)).@"fn";
        if (f.param_types.len != 1 or f.param_types[0] != *S or f.return_type.? != void)
            @compileError(@typeName(S) ++ ".deinit must be fn (*" ++ @typeName(S) ++ ") void");
    }
}

pub fn Container(comptime listed: []const type) type {
    const services = unique(listed);
    const order = initOrder(services);
    for (services) |S| checkHooks(S);

    return struct {
        const Self = @This();

        instances: @Tuple(services),
        /// Services whose `init` finished, so `deinit` applies.
        live: [services.len]bool,

        pub fn get(self: *Self, comptime S: type) *S {
            const i = comptime indexOf(services, S) orelse @compileError("no service " ++ @typeName(S));
            return &self.instances[i];
        }

        /// Builds every service in place; `self` must not move afterwards.
        /// `seeds` is a tuple of ready-made instances (config, overrides):
        /// they keep their field values and skip `init`/`deinit`, but their
        /// pointer fields are still wired.
        pub fn initWith(self: *Self, seeds: anytype) !void {
            const Seeds = @TypeOf(seeds);
            self.live = @splat(false);
            inline for (@typeInfo(Seeds).@"struct".field_names) |f| {
                const T = @TypeOf(@field(seeds, f));
                const i = comptime indexOf(services, T) orelse @compileError("seed " ++ @typeName(T) ++ " is not a service");
                self.instances[i] = @field(seeds, f);
            }
            inline for (services, 0..) |S, i| {
                const seeded = comptime isSeed(Seeds, S);
                const info = @typeInfo(S).@"struct";
                inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
                    if (comptime depOf(services, S, name, F)) |d| {
                        @field(self.instances[i], name) = &self.instances[d];
                    } else if (!seeded) {
                        @field(self.instances[i], name) = comptime attrs.defaultValue(F) orelse
                            @compileError(@typeName(S) ++ "." ++ name ++ " needs a default or a service type");
                    }
                }
            }
            errdefer self.deinit();
            inline for (order) |i| {
                const S = services[i];
                if (comptime !isSeed(Seeds, S)) {
                    if (@hasDecl(S, "init")) {
                        const r = S.init(&self.instances[i]);
                        if (@typeInfo(@TypeOf(r)) == .error_union) try r;
                    }
                    self.live[i] = true;
                }
            }
        }

        /// `deinit` hooks in reverse dependency order, for services whose
        /// `init` finished.
        pub fn deinit(self: *Self) void {
            comptime var k = order.len;
            inline while (k > 0) {
                k -= 1;
                const i = order[k];
                const S = services[i];
                if (self.live[i]) {
                    self.live[i] = false;
                    if (@hasDecl(S, "deinit")) S.deinit(&self.instances[i]);
                }
            }
        }

        fn isSeed(comptime Seeds: type, comptime S: type) bool {
            inline for (@typeInfo(Seeds).@"struct".field_types) |T| if (T == S) return true;
            return false;
        }
    };
}

const testing = std.testing;

const Log = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,
    fail_on: u8 = 0,

    fn add(self: *Log, c: u8) void {
        self.buf[self.len] = c;
        self.len += 1;
    }
    fn items(self: *const Log) []const u8 {
        return self.buf[0..self.len];
    }
};

const Repo = struct {
    log: *Log,
    rows: u32 = 3,
    pub fn init(self: *Repo) !void {
        self.log.add('r');
        if (self.log.fail_on == 'r') return error.Boom;
    }
    pub fn deinit(self: *Repo) void {
        self.log.add('R');
    }
};

const Service = struct {
    repo: *Repo,
    log: *Log,
    pub fn init(self: *Service) !void {
        self.log.add('s');
        if (self.log.fail_on == 's') return error.Boom;
    }
    pub fn deinit(self: *Service) void {
        self.log.add('S');
    }
};

const Controller = struct {
    service: *const Service,
    log: *Log,
    pub fn init(self: *Controller) void {
        self.log.add('c');
    }
    pub fn deinit(self: *Controller) void {
        self.log.add('C');
    }
};

// Declared out of dependency order on purpose.
const C = Container(&.{ Controller, Service, Repo, Log });

test "wires pointer fields by type" {
    var c: C = undefined;
    try c.initWith(.{Log{}});
    defer c.deinit();
    try testing.expectEqual(c.get(Repo), c.get(Service).repo);
    try testing.expectEqual(@as(*const Service, c.get(Service)), c.get(Controller).service);
}

test "defaults fill other fields" {
    var c: C = undefined;
    try c.initWith(.{Log{}});
    defer c.deinit();
    try testing.expectEqual(3, c.get(Repo).rows);
}

test "init hooks run after their deps" {
    var c: C = undefined;
    try c.initWith(.{Log{}});
    defer c.deinit();
    try testing.expectEqualStrings("rsc", c.get(Log).items());
}

test "deinit runs in reverse" {
    var c: C = undefined;
    try c.initWith(.{Log{}});
    c.deinit();
    try testing.expectEqualStrings("rscCSR", c.get(Log).items());
}

test "failing init rolls back in reverse" {
    var c: C = undefined;
    try testing.expectError(error.Boom, c.initWith(.{Log{ .fail_on = 's' }}));
    // Service's own deinit doesn't run: its init never finished.
    try testing.expectEqualStrings("rsR", c.get(Log).items());
}

test "seeded services skip hooks" {
    var c: C = undefined;
    try c.initWith(.{ Log{}, Repo{ .log = undefined, .rows = 9 } });
    defer c.deinit();
    try testing.expectEqual(9, c.get(Repo).rows);
    // A seed's own pointer fields are still wired.
    try testing.expectEqual(c.get(Log), c.get(Repo).log);
    try testing.expectEqualStrings("sc", c.get(Log).items());
}

test "unique removes duplicates" {
    const u = comptime unique(&.{ Repo, Log, Repo, Service, Log });
    try testing.expectEqual(3, u.len);
    try testing.expect(u[0] == Repo and u[1] == Log and u[2] == Service);
}
