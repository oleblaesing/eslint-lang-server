const std = @import("std");
const Server = @import("Server.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = Server.init(allocator);
    defer server.deinit();
    try server.run();

    std.log.info("ESLint Language Server shutting down", .{});
}

// Pull in tests from all modules
test {
    _ = @import("uri.zig");
    _ = @import("Workspace.zig");
    _ = @import("Eslint.zig");
    _ = @import("Server.zig");
}
