const kzig = @import("kzig");
const ChatController = @import("chat.controller.zig").ChatController;
const ChatGateway = @import("chat.gateway.zig").ChatGateway;
const ChatAuth = @import("chat.auth.zig").ChatAuth;
const Presence = @import("presence.repository.zig").Presence;
const ChatSettings = @import("chat.settings.zig").ChatSettings;
const Clock = @import("../../clock.zig").Clock;

/// ws-chat: REST under /api/v1/chat, the socket at /ws/chat.
pub const ChatModule = kzig.Module(.{
    .name = "ChatModule",
    .path = "/chat",
    .controllers = &.{ChatController},
    .gateways = &.{ChatGateway},
    .services = &.{ ChatAuth, Presence, Clock },
    .settings = &.{ChatSettings},
});
