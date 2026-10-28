//! Environment config. Each field reads its upper-cased name (`port` ←
//! `PORT`); a bad or missing value stops boot with every problem listed.
//! How the app runs (`KZIG_ENV`: development, test, production) is
//! `*const kzig.Process`'s `env`.
pub const Config = struct {
    port: u16 = 3000,
    log_level: []const u8 = "info",
};
