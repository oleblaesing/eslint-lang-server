const std = @import("std");
const Workspace = @import("Workspace.zig");

const Eslint = @This();

pub const Diagnostic = struct {
    line: i32,
    column: i32,
    end_line: i32,
    end_column: i32,
    severity: i32, // 1=warning, 2=error (ESLint convention)
    message: []const u8,
    rule_id: ?[]const u8,
    fixable: bool,
};

pub const LintResult = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    diagnostics: []Diagnostic,
    fixed_output: ?[]const u8,

    pub fn deinit(self: *LintResult) void {
        for (self.diagnostics) |*d| {
            self.allocator.free(d.message);
            if (d.rule_id) |r| self.allocator.free(r);
        }
        self.allocator.free(self.diagnostics);
        self.allocator.free(self.file_path);
        if (self.fixed_output) |o| self.allocator.free(o);
    }
};

allocator: std.mem.Allocator,
workspace: *Workspace,

pub fn init(allocator: std.mem.Allocator, workspace: *Workspace) Eslint {
    return .{
        .allocator = allocator,
        .workspace = workspace,
    };
}

/// Lint a file, optionally with in-memory content (unsaved buffer).
/// Returns null if ESLint produces no output or the binary is not found.
/// Caller must call LintResult.deinit() on the returned value.
pub fn lintFile(self: *Eslint, file_path: []const u8, content: ?[]const u8) !?LintResult {
    const eslint_bin = try self.findBinary(file_path);
    defer self.allocator.free(eslint_bin);

    const workspace_root = try self.workspace.getRootForFile(file_path);
    defer if (workspace_root) |r| self.allocator.free(r);

    const package_root = try self.workspace.findPackageRoot(file_path);
    defer if (package_root) |r| self.allocator.free(r);

    const cwd = package_root orelse workspace_root;

    std.log.debug("Running ESLint: {s} on {s} (working dir: {s}, stdin: {})", .{
        eslint_bin,
        file_path,
        cwd orelse "(none)",
        content != null,
    });

    const json_output = try self.runCommand(.{
        .eslint_bin = eslint_bin,
        .file_path = file_path,
        .cwd = cwd,
        .fix = false,
        .content = content,
    }) orelse return null;
    defer self.allocator.free(json_output);

    return self.parseOutput(json_output, file_path);
}

/// Run ESLint with --fix on a file. Returns the result with fixed_output if fixes applied.
/// Caller must call LintResult.deinit() on the returned value.
pub fn fixFile(self: *Eslint, file_path: []const u8) !?LintResult {
    const eslint_bin = try self.findBinary(file_path);
    defer self.allocator.free(eslint_bin);

    const workspace_root = try self.workspace.getRootForFile(file_path);
    defer if (workspace_root) |r| self.allocator.free(r);

    const package_root = try self.workspace.findPackageRoot(file_path);
    defer if (package_root) |r| self.allocator.free(r);

    const cwd = package_root orelse workspace_root;

    std.log.debug("Running ESLint fix: {s} on {s}", .{ eslint_bin, file_path });

    const json_output = try self.runCommand(.{
        .eslint_bin = eslint_bin,
        .file_path = file_path,
        .cwd = cwd,
        .fix = true,
        .content = null,
    }) orelse return null;
    defer self.allocator.free(json_output);

    return self.parseOutput(json_output, file_path);
}

// ---- Private ----

fn findBinary(self: *Eslint, file_path: []const u8) ![]const u8 {
    const root = try self.workspace.getRootForFile(file_path);
    defer if (root) |r| self.allocator.free(r);
    const workspace_root = root orelse return self.allocator.dupe(u8, "eslint");
    return self.workspace.findEslintBinary(workspace_root);
}

const RunArgs = struct {
    eslint_bin: []const u8,
    file_path: []const u8,
    cwd: ?[]const u8,
    fix: bool,
    content: ?[]const u8,
};

/// Spawns ESLint as a child process and returns its stdout.
/// Returns null on spawn failure. Caller owns the returned slice.
fn runCommand(self: *Eslint, args: RunArgs) !?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, args.eslint_bin);
    try argv.append(self.allocator, "--format");
    try argv.append(self.allocator, "json");
    if (args.fix) try argv.append(self.allocator, "--fix");

    // stdin-filename flag — must outlive the argv list
    var stdin_flag_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    if (args.content != null) {
        const stdin_flag = try std.fmt.bufPrint(
            &stdin_flag_buf,
            "--stdin-filename={s}",
            .{args.file_path},
        );
        try argv.append(self.allocator, "--stdin");
        try argv.append(self.allocator, stdin_flag);
    } else {
        try argv.append(self.allocator, args.file_path);
    }

    var child = std.process.Child.init(argv.items, self.allocator);
    child.stdin_behavior = if (args.content != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    if (args.cwd) |cwd| child.cwd = cwd;

    child.spawn() catch |err| {
        std.log.err("Failed to spawn ESLint: {}", .{err});
        return null;
    };

    // Write content to stdin if provided
    if (args.content) |content| {
        child.stdin.?.writeAll(content) catch {};
        child.stdin.?.close();
        child.stdin = null;
    }

    // Read all stdout
    var out_buf: [1024 * 1024]u8 = undefined; // 1 MiB read buffer
    var reader = child.stdout.?.readerStreaming(&out_buf);
    const stdout = reader.interface.allocRemaining(self.allocator, .unlimited) catch |err| {
        _ = child.wait() catch {};
        std.log.err("Failed to read ESLint output: {}", .{err});
        return null;
    };

    _ = child.wait() catch {};
    return stdout;
}

// ESLint JSON output types for typed deserialization
const EslintFix = struct {
    range: [2]i32 = .{ 0, 0 },
    text: []const u8 = "",
};

const EslintMessage = struct {
    line: i32 = 0,
    column: i32 = 0,
    endLine: ?i32 = null,
    endColumn: ?i32 = null,
    severity: i32 = 0,
    message: []const u8 = "",
    ruleId: ?[]const u8 = null,
    fix: ?EslintFix = null,
};

const EslintFileResult = struct {
    filePath: []const u8 = "",
    messages: []EslintMessage = &.{},
    output: ?[]const u8 = null,
};

/// Parse ESLint `--format json` output into a LintResult.
/// Returns null if the JSON is invalid or empty.
fn parseOutput(self: *Eslint, json_bytes: []const u8, file_path: []const u8) !?LintResult {
    // ESLint may emit non-JSON preamble (startup messages, warnings).
    // Find the first '[' to skip any prefix noise.
    const json_start = std.mem.indexOfScalar(u8, json_bytes, '[') orelse {
        std.log.warn("ESLint output contains no JSON array", .{});
        return null;
    };

    const parsed = std.json.parseFromSlice(
        []EslintFileResult,
        self.allocator,
        json_bytes[json_start..],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.log.warn("Failed to parse ESLint JSON output: {}", .{err});
        return null;
    };
    defer parsed.deinit();

    if (parsed.value.len == 0) {
        return LintResult{
            .allocator = self.allocator,
            .file_path = try self.allocator.dupe(u8, file_path),
            .diagnostics = &.{},
            .fixed_output = null,
        };
    }

    const file_result = parsed.value[0];

    // Convert EslintMessage[] -> Diagnostic[]
    var diags = try self.allocator.alloc(Diagnostic, file_result.messages.len);
    errdefer self.allocator.free(diags);

    var diag_count: usize = 0;
    errdefer {
        for (diags[0..diag_count]) |*d| {
            self.allocator.free(d.message);
            if (d.rule_id) |r| self.allocator.free(r);
        }
    }

    for (file_result.messages, 0..) |msg, i| {
        diags[i] = .{
            .line = msg.line,
            .column = msg.column,
            .end_line = msg.endLine orelse msg.line,
            .end_column = msg.endColumn orelse msg.column,
            .severity = msg.severity,
            .message = try self.allocator.dupe(u8, msg.message),
            .rule_id = if (msg.ruleId) |r| try self.allocator.dupe(u8, r) else null,
            .fixable = msg.fix != null,
        };
        diag_count += 1;
    }

    const fixed_output = if (file_result.output) |o| try self.allocator.dupe(u8, o) else null;

    return LintResult{
        .allocator = self.allocator,
        .file_path = try self.allocator.dupe(u8, file_path),
        .diagnostics = diags,
        .fixed_output = fixed_output,
    };
}

// ---- Tests ----

test "parseOutput parses ESLint JSON output" {
    const Workspace_ = @import("Workspace.zig");
    var fake_workspace = Workspace_{
        .allocator = std.testing.allocator,
        .root_path = null,
        .is_pnpm_workspace = false,
    };
    var eslint = Eslint.init(std.testing.allocator, &fake_workspace);

    const json =
        \\[{"filePath":"/test.ts","messages":[{"line":1,"column":5,"endLine":1,"endColumn":10,"severity":2,"message":"no-unused-vars","ruleId":"no-unused-vars","fix":{"range":[4,9],"text":""}}]}]
    ;

    var result = (try eslint.parseOutput(json, "/test.ts")).?;
    defer result.deinit();

    try std.testing.expectEqualStrings("/test.ts", result.file_path);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);

    const d = result.diagnostics[0];
    try std.testing.expectEqual(@as(i32, 1), d.line);
    try std.testing.expectEqual(@as(i32, 5), d.column);
    try std.testing.expectEqual(@as(i32, 1), d.end_line);
    try std.testing.expectEqual(@as(i32, 10), d.end_column);
    try std.testing.expectEqual(@as(i32, 2), d.severity);
    try std.testing.expectEqualStrings("no-unused-vars", d.message);
    try std.testing.expectEqualStrings("no-unused-vars", d.rule_id.?);
    try std.testing.expect(d.fixable);
}

test "parseOutput handles empty messages array" {
    const Workspace_ = @import("Workspace.zig");
    var fake_workspace = Workspace_{
        .allocator = std.testing.allocator,
        .root_path = null,
        .is_pnpm_workspace = false,
    };
    var eslint = Eslint.init(std.testing.allocator, &fake_workspace);

    const json =
        \\[{"filePath":"/test.ts","messages":[]}]
    ;

    var result = (try eslint.parseOutput(json, "/test.ts")).?;
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "parseOutput handles missing optional fields" {
    const Workspace_ = @import("Workspace.zig");
    var fake_workspace = Workspace_{
        .allocator = std.testing.allocator,
        .root_path = null,
        .is_pnpm_workspace = false,
    };
    var eslint = Eslint.init(std.testing.allocator, &fake_workspace);

    const json =
        \\[{"filePath":"/test.ts","messages":[{"line":3,"column":1,"severity":1,"message":"some warning"}]}]
    ;

    var result = (try eslint.parseOutput(json, "/test.ts")).?;
    defer result.deinit();

    const d = result.diagnostics[0];
    try std.testing.expectEqual(@as(i32, 3), d.end_line); // defaults to line
    try std.testing.expectEqual(@as(i32, 1), d.end_column); // defaults to column
    try std.testing.expect(d.rule_id == null);
    try std.testing.expect(!d.fixable);
}

test "parseOutput returns null on invalid JSON" {
    const Workspace_ = @import("Workspace.zig");
    var fake_workspace = Workspace_{
        .allocator = std.testing.allocator,
        .root_path = null,
        .is_pnpm_workspace = false,
    };
    var eslint = Eslint.init(std.testing.allocator, &fake_workspace);

    const result = try eslint.parseOutput("not json at all", "/test.ts");
    try std.testing.expect(result == null);
}

test "parseOutput skips non-JSON prefix" {
    const Workspace_ = @import("Workspace.zig");
    var fake_workspace = Workspace_{
        .allocator = std.testing.allocator,
        .root_path = null,
        .is_pnpm_workspace = false,
    };
    var eslint = Eslint.init(std.testing.allocator, &fake_workspace);

    const json = "some startup noise\n[{\"filePath\":\"/t.ts\",\"messages\":[]}]";

    var result = (try eslint.parseOutput(json, "/t.ts")).?;
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "severity mapping: ESLint 2=error, 1=warning" {
    const Workspace_ = @import("Workspace.zig");
    var fake_workspace = Workspace_{
        .allocator = std.testing.allocator,
        .root_path = null,
        .is_pnpm_workspace = false,
    };
    var eslint = Eslint.init(std.testing.allocator, &fake_workspace);

    const json =
        \\[{"filePath":"/t.ts","messages":[{"line":1,"column":1,"severity":2,"message":"err"},{"line":2,"column":1,"severity":1,"message":"warn"}]}]
    ;

    var result = (try eslint.parseOutput(json, "/t.ts")).?;
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 2), result.diagnostics[0].severity);
    try std.testing.expectEqual(@as(i32, 1), result.diagnostics[1].severity);
}
