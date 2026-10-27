const std = @import("std");
const kzig = @import("kzig");
const auth = @import("../auth.zig");

const TenantDatabase = @import("../db/tenant.database.zig").TenantDatabase;

pub const Tenant = struct { id: []const u8, name: []const u8 };

/// The `tenants` registry.
pub const TenantRepository = struct {
    database: *TenantDatabase,

    pub fn findBySubdomain(self: *TenantRepository, arena: std.mem.Allocator, slug: []const u8) !?Tenant {
        const db = try self.database.client();
        const row = try db.selectFrom(.tenants).select(.{ .id, .name }).where(.subdomain, .eq, slug).executeTakeFirst(arena) orelse return null;
        return .{ .id = row.id, .name = row.name };
    }
};

/// `tenant`: from `x-tenant`, else the host's subdomain. A tenant the user
/// doesn't belong to answers like an unknown one, so tenants can't be
/// enumerated.
pub const LoadTenant = struct {
    pub const key = "tenant";
    repo: *TenantRepository,

    pub fn resolve(self: *LoadTenant, ctx: *kzig.Ctx, got: struct { user: auth.AuthUser }) !Tenant {
        const slug = ctx.header("x-tenant") orelse subdomain(ctx.header("host") orelse "");
        for (got.user.tenants) |t| {
            if (std.mem.eql(u8, t, slug)) break;
        } else return ctx.fail(.not_found, "Unknown tenant");
        return try self.repo.findBySubdomain(ctx.arena, slug) orelse ctx.fail(.not_found, "Unknown tenant");
    }
};

fn subdomain(host: []const u8) []const u8 {
    return host[0 .. std.mem.findScalar(u8, host, '.') orelse host.len];
}
