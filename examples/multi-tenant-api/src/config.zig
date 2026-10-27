pub const Config = struct {
    port: u16 = 3000,
    node_env: enum { development, production, @"test" } = .development,
};
