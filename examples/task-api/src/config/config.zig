//! Project environment config. Each field reads its upper-cased name from the
//! environment (`port` ← `PORT`); a bad or missing value stops boot with every
//! problem listed.
pub const Config = struct {
    port: u16 = 3000,
    node_env: enum { development, production, @"test" } = .development,
    log_level: []const u8 = "info",
};
