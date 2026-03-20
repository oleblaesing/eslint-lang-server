const std = @import("std");

/// Strips the "file://" prefix from a URI, returning the path portion.
/// Caller owns returned memory.
pub fn uriToPath(allocator: std.mem.Allocator, raw_uri: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw_uri, "file://")) {
        return allocator.dupe(u8, raw_uri["file://".len..]);
    }
    return allocator.dupe(u8, raw_uri);
}

/// Prepends "file://" to a filesystem path.
/// Caller owns returned memory.
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

test "uriToPath strips file:// prefix" {
    const path = try uriToPath(std.testing.allocator, "file:///home/user/file.js");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/file.js", path);
}

test "uriToPath passes through non-file URIs" {
    const path = try uriToPath(std.testing.allocator, "/home/user/file.js");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/file.js", path);
}

test "pathToUri prepends file://" {
    const uri = try pathToUri(std.testing.allocator, "/home/user/file.js");
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("file:///home/user/file.js", uri);
}
