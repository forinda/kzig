//! RFC 9457 problem details and the framework error set.
const std = @import("std");

/// Errors a handler can return to answer with a status. `HttpProblem` means
/// the details were stored with `Ctx.fail`.
pub const Error = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    Conflict,
    PayloadTooLarge,
    UnprocessableEntity,
    TooManyRequests,
    HttpProblem,
};

pub const Problem = struct {
    status: std.http.Status,
    /// Defaults to the status phrase.
    title: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub fn statusOf(err: anyerror) ?std.http.Status {
    return switch (err) {
        error.BadRequest => .bad_request,
        error.Unauthorized => .unauthorized,
        error.Forbidden => .forbidden,
        error.NotFound => .not_found,
        error.MethodNotAllowed => .method_not_allowed,
        error.Conflict => .conflict,
        error.PayloadTooLarge => .payload_too_large,
        error.UnprocessableEntity => .unprocessable_entity,
        error.TooManyRequests => .too_many_requests,
        else => null,
    };
}

test "statusOf maps framework errors" {
    try std.testing.expectEqual(std.http.Status.not_found, statusOf(error.NotFound).?);
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, statusOf(error.UnprocessableEntity).?);
    try std.testing.expectEqual(null, statusOf(error.Foo));
    try std.testing.expectEqual(null, statusOf(error.HttpProblem));
}
