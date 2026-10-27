//! Server options every runtime takes; each maps them onto its engine.
pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    /// 0 picks an ephemeral port; read it back with `Server.port`.
    port: u16 = 3000,
    max_connections: u32 = 1024,
    /// KickJS's default `jsonLimit` is 1mb.
    max_body_bytes: usize = 1 << 20,
    /// The whole request head must fit; larger answers 431.
    max_header_bytes: usize = 16 * 1024,
    /// Time from waiting for a request (keep-alive idle included) until its
    /// head is complete; bounds slowloris clients. 0 disables.
    head_timeout_ms: u32 = 60_000,
    /// Time to receive the body, and again to write the response. 0 disables.
    body_timeout_ms: u32 = 300_000,
    /// After `shutdown`, how long in-flight requests may take before their
    /// sockets are shut down.
    shutdown_timeout_ms: u32 = 30_000,
};
