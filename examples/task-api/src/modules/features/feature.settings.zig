/// `FEATURES_*`, read and validated only because `FeaturesModule` is mounted.
pub const FeatureSettings = struct {
    pub const prefix = "FEATURES";

    /// Accept new sign-ups.
    signups: bool = true,
    /// Show the beta banner to everyone.
    beta_banner: bool = false,
    max_upload_mb: u32 = 10,
    /// Always see the beta banner (comma-separated emails).
    beta_testers: []const []const u8 = &.{},
};
