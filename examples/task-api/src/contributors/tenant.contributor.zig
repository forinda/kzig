const std = @import("std");
const kzig = @import("kzig");
const auth = @import("../auth.zig");

pub const Tenant = struct { id: []const u8, name: []const u8 };

pub const TenantRepository = struct {
    const rows = [_]struct { []const u8, Tenant }{
        .{ "acme", .{ .id = "tenant-acme", .name = "Acme Corp" } },
        .{ "globex", .{ .id = "tenant-globex", .name = "Globex" } },
    };

    pub fn findBySubdomain(_: *TenantRepository, slug: []const u8) ?Tenant {
        for (rows) |r| if (std.mem.eql(u8, r[0], slug)) return r[1];
        return null;
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
        return self.repo.findBySubdomain(slug) orelse ctx.fail(.not_found, "Unknown tenant");
    }
};

fn subdomain(host: []const u8) []const u8 {
    return host[0 .. std.mem.findScalar(u8, host, '.') orelse host.len];
}
