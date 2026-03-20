const std = @import("std");
const uri = @import("uri.zig");

const Workspace = @This();

allocator: std.mem.Allocator,
root_path: ?[]const u8,
is_pnpm_workspace: bool,

pub fn init(allocator: std.mem.Allocator, root_uri: []const u8) !Workspace {
    const root_path = try uri.uriToPath(allocator, root_uri);
    const pnpm = isPnpmWorkspace(root_path);
    std.log.info("Workspace initialized: {s} (pnpm: {})", .{ root_path, pnpm });
    return .{
        .allocator = allocator,
        .root_path = root_path,
        .is_pnpm_workspace = pnpm,
    };
}

pub fn deinit(self: *Workspace) void {
    if (self.root_path) |p| self.allocator.free(p);
    self.root_path = null;
}

/// Returns the most specific package root directory for the given file path.
/// Caller owns the returned memory.
pub fn getRootForFile(self: *const Workspace, file_path: []const u8) !?[]const u8 {
    // First check for a pnpm workspace root up the tree
    if (try findPnpmRoot(self.allocator, file_path)) |pnpm_root| {
        return pnpm_root;
    }
    // Walk up looking for a package.json
    if (try walkUpForFile(self.allocator, file_path, "package.json")) |pkg_root| {
        return pkg_root;
    }
    // Fall back to workspace root
    if (self.root_path) |rp| {
        return try self.allocator.dupe(u8, rp);
    }
    return null;
}

/// Returns the best ESLint binary for the given workspace root directory.
/// Caller owns the returned memory.
pub fn findEslintBinary(self: *const Workspace, workspace_root: []const u8) ![]const u8 {
    // 1. Local eslint_d in node_modules
    const local_eslint_d = try std.fs.path.join(self.allocator, &.{ workspace_root, "node_modules/.bin/eslint_d" });
    defer self.allocator.free(local_eslint_d);
    if (fileExists(local_eslint_d)) {
        std.log.info("Using local eslint_d from node_modules (fast daemon mode!)", .{});
        return self.allocator.dupe(u8, local_eslint_d);
    }

    // 2. System eslint_d in PATH
    if (commandExists(self.allocator, "eslint_d")) {
        std.log.info("Using system eslint_d from PATH (fast daemon mode!)", .{});
        return self.allocator.dupe(u8, "eslint_d");
    }

    // 3. Local eslint in node_modules
    const local_eslint = try std.fs.path.join(self.allocator, &.{ workspace_root, "node_modules/.bin/eslint" });
    defer self.allocator.free(local_eslint);
    if (fileExists(local_eslint)) {
        std.log.info("Using local eslint from node_modules", .{});
        return self.allocator.dupe(u8, local_eslint);
    }

    // 4. pnpm local eslint
    const pnpm_eslint = try std.fs.path.join(self.allocator, &.{ workspace_root, ".pnpm/node_modules/.bin/eslint" });
    defer self.allocator.free(pnpm_eslint);
    if (fileExists(pnpm_eslint)) {
        std.log.info("Using eslint from .pnpm", .{});
        return self.allocator.dupe(u8, pnpm_eslint);
    }

    // 5. System eslint (fallback)
    std.log.info("Using system eslint from PATH (slower)", .{});
    return self.allocator.dupe(u8, "eslint");
}

/// Returns the nearest package root (directory containing package.json),
/// stopping at a pnpm workspace root boundary. Caller owns the returned memory.
pub fn findPackageRoot(self: *const Workspace, file_path: []const u8) !?[]const u8 {
    const dir = std.fs.path.dirname(file_path) orelse return null;
    var current: []const u8 = try self.allocator.dupe(u8, dir);
    defer self.allocator.free(current);

    while (true) {
        const pkg_json = try std.fs.path.join(self.allocator, &.{ current, "package.json" });
        const found = fileExists(pkg_json);
        self.allocator.free(pkg_json);
        if (found) {
            std.log.debug("Found package root: {s}", .{current});
            return try self.allocator.dupe(u8, current);
        }

        const parent = std.fs.path.dirname(current) orelse break;

        // Stop if the parent is a pnpm workspace root
        if (isPnpmWorkspace(parent)) break;

        const new_current = try self.allocator.dupe(u8, parent);
        self.allocator.free(current);
        current = new_current;

        // Stop at filesystem root
        if (std.mem.eql(u8, current, "/")) break;
    }
    return null;
}

// ---- Private helpers ----

fn isPnpmWorkspace(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const yaml_path = std.fmt.bufPrint(&buf, "{s}/pnpm-workspace.yaml", .{path}) catch return false;
    if (fileExists(yaml_path)) return true;
    const lock_path = std.fmt.bufPrint(&buf, "{s}/pnpm-lock.yaml", .{path}) catch return false;
    return fileExists(lock_path);
}

/// Walk up from `start_path` looking for a directory that contains `target` file.
/// Returns the directory path on success. Caller owns the returned memory.
fn walkUpForFile(allocator: std.mem.Allocator, start_path: []const u8, target: []const u8) !?[]const u8 {
    var dir: []const u8 = std.fs.path.dirname(start_path) orelse return null;
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ dir, target });
        const found = fileExists(candidate);
        allocator.free(candidate);
        if (found) {
            return try allocator.dupe(u8, dir);
        }
        dir = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, dir, "/")) return null;
    }
}

/// Walk up looking for a pnpm workspace root.
/// Caller owns returned memory.
fn findPnpmRoot(allocator: std.mem.Allocator, file_path: []const u8) !?[]const u8 {
    var dir: []const u8 = std.fs.path.dirname(file_path) orelse return null;
    while (true) {
        if (isPnpmWorkspace(dir)) {
            return try allocator.dupe(u8, dir);
        }
        dir = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, dir, "/")) return null;
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn commandExists(allocator: std.mem.Allocator, cmd: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "which", cmd },
    }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return result.term == .Exited and result.term.Exited == 0;
}

// ---- Tests ----

test "isPnpmWorkspace detects pnpm-workspace.yaml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("pnpm-workspace.yaml", .{});
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    try std.testing.expect(isPnpmWorkspace(tmp_path));
}

test "isPnpmWorkspace detects pnpm-lock.yaml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("pnpm-lock.yaml", .{});
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    try std.testing.expect(isPnpmWorkspace(tmp_path));
}

test "isPnpmWorkspace returns false when no pnpm files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    try std.testing.expect(!isPnpmWorkspace(tmp_path));
}

test "findPackageRoot finds nearest package.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create: root/pkg/src/file.ts with package.json at root/pkg/
    try tmp.dir.makePath("pkg/src");
    const pkg_json = try tmp.dir.createFile("pkg/package.json", .{});
    pkg_json.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const workspace = Workspace{
        .allocator = std.testing.allocator,
        .root_path = tmp_path,
        .is_pnpm_workspace = false,
    };

    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/pkg/src/file.ts", .{tmp_path});
    defer std.testing.allocator.free(file_path);

    const result = try workspace.findPackageRoot(file_path);
    defer if (result) |r| std.testing.allocator.free(r);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/pkg", .{tmp_path});
    defer std.testing.allocator.free(expected);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(expected, result.?);
}

test "findPackageRoot stops at pnpm workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create: root/ (pnpm root) / packages/pkg/src/file.ts
    // No package.json between file and pnpm root
    try tmp.dir.makePath("packages/pkg/src");
    const pnpm_yaml = try tmp.dir.createFile("pnpm-workspace.yaml", .{});
    pnpm_yaml.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const workspace = Workspace{
        .allocator = std.testing.allocator,
        .root_path = tmp_path,
        .is_pnpm_workspace = true,
    };

    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/packages/pkg/src/file.ts", .{tmp_path});
    defer std.testing.allocator.free(file_path);

    const result = try workspace.findPackageRoot(file_path);
    defer if (result) |r| std.testing.allocator.free(r);

    // Should return null since we hit pnpm workspace root without finding package.json
    try std.testing.expect(result == null);
}
