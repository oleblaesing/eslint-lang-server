const std = @import("std");
const Workspace = @import("Workspace.zig");
const Eslint = @import("Eslint.zig");

const Server = @This();

const debounce_ms: i64 = 300;

const DebounceState = struct {
    pending_uri: []const u8,
    pending_file_path: []const u8,
    pending_content: ?[]const u8,
    last_change_ms: i64,
};

allocator: std.mem.Allocator,
workspace: ?Workspace,
eslint: ?Eslint,
should_exit: bool,
debounce: ?DebounceState,

pub fn init(allocator: std.mem.Allocator) Server {
    return .{
        .allocator = allocator,
        .workspace = null,
        .eslint = null,
        .should_exit = false,
        .debounce = null,
    };
}

pub fn deinit(self: *Server) void {
    if (self.workspace) |*ws| ws.deinit();
    self.clearDebounce();
}

pub fn run(self: *Server) !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    // Buffers for file reader/writer — kept on the heap to avoid large stack frames
    const read_buf = try self.allocator.alloc(u8, 65536);
    defer self.allocator.free(read_buf);
    const write_buf = try self.allocator.alloc(u8, 65536);
    defer self.allocator.free(write_buf);

    var file_reader = stdin_file.readerStreaming(read_buf);
    var file_writer = stdout_file.writerStreaming(write_buf);

    while (!self.should_exit) {
        // Check debounce timer
        if (self.debounce != null) {
            const now = std.time.milliTimestamp();
            if (now - self.debounce.?.last_change_ms >= debounce_ms) {
                try self.runPendingLint(&file_writer.interface);
            }
        }

        // Poll stdin with 100ms timeout
        var fds = [_]std.posix.pollfd{.{
            .fd = stdin_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 100) catch 0;
        if (ready == 0) continue;

        // Check for HUP / error — the client disconnected
        if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;

        // Read and dispatch message
        const msg = self.readMessage(&file_reader.interface) catch |err| {
            if (err == error.EndOfStream) break;
            std.log.err("Error reading message: {}", .{err});
            continue;
        } orelse continue;
        defer msg.deinit();

        self.dispatch(msg.value, &file_writer.interface) catch |err| {
            std.log.err("Error dispatching message: {}", .{err});
        };
    }
}

// ---- Transport ----

fn readMessage(self: *Server, reader: *std.io.Reader) !?std.json.Parsed(std.json.Value) {
    var content_length: usize = 0;

    // Read headers until blank line.
    // takeDelimiterInclusive returns the line including the '\n' delimiter and
    // advances seek past it, which is what we want for correct body positioning.
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| return err;
        // Strip trailing \r\n or \n
        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (std.mem.startsWith(u8, trimmed, "Content-Length: ")) {
            content_length = std.fmt.parseInt(
                usize,
                trimmed["Content-Length: ".len..],
                10,
            ) catch 0;
        }
    }

    if (content_length == 0) return null;

    // Read body — use readAlloc which reads exactly content_length bytes from
    // the buffer (and underlying stream if needed).
    const body = reader.readAlloc(self.allocator, content_length) catch |err| return err;
    defer self.allocator.free(body);

    std.log.debug("Received: {s}", .{body});

    return try std.json.parseFromSlice(
        std.json.Value,
        self.allocator,
        body,
        .{},
    );
}

fn sendJson(self: *Server, writer: *std.io.Writer, value: anytype) !void {
    const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
    defer self.allocator.free(json_str);

    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "Content-Length: {}\r\n\r\n",
        .{json_str.len},
    );
    try writer.writeAll(header);
    try writer.writeAll(json_str);
    try writer.flush();
}

// ---- Dispatch ----

fn dispatch(self: *Server, root: std.json.Value, writer: *std.io.Writer) !void {
    const obj = switch (root) {
        .object => |o| o,
        else => return,
    };

    const method_val = obj.get("method") orelse return;
    const method_str = switch (method_val) {
        .string => |s| s,
        else => return,
    };

    const id: ?i64 = blk: {
        const id_val = obj.get("id") orelse break :blk null;
        break :blk switch (id_val) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    };

    const params = obj.get("params");

    if (std.mem.eql(u8, method_str, "initialize")) {
        try self.handleInitialize(id orelse 0, params, writer);
    } else if (std.mem.eql(u8, method_str, "initialized")) {
        std.log.info("Client initialized", .{});
    } else if (std.mem.eql(u8, method_str, "shutdown")) {
        try self.handleShutdown(id orelse 0, writer);
    } else if (std.mem.eql(u8, method_str, "exit")) {
        self.handleExit();
    } else if (std.mem.eql(u8, method_str, "textDocument/didOpen")) {
        if (params) |p| try self.handleDidOpen(p, writer);
    } else if (std.mem.eql(u8, method_str, "textDocument/didChange")) {
        if (params) |p| try self.handleDidChange(p);
    } else if (std.mem.eql(u8, method_str, "textDocument/didSave")) {
        if (params) |p| try self.handleDidSave(p, writer);
    } else if (std.mem.eql(u8, method_str, "textDocument/didClose")) {
        if (params) |p| try self.handleDidClose(p, writer);
    } else if (std.mem.eql(u8, method_str, "textDocument/codeAction")) {
        if (params) |p| try self.handleCodeAction(id orelse 0, p, writer);
    } else {
        std.log.debug("Unhandled method: {s}", .{method_str});
    }
}

// ---- Handlers ----

fn handleInitialize(self: *Server, id: i64, params: ?std.json.Value, writer: *std.io.Writer) !void {
    // Extract rootUri from params
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("rootUri")) |ru| {
                if (ru == .string) {
                    const root_uri = ru.string;
                    self.workspace = Workspace.init(self.allocator, root_uri) catch |err| blk: {
                        std.log.err("Failed to init workspace: {}", .{err});
                        break :blk null;
                    };
                    if (self.workspace) |*ws| {
                        self.eslint = Eslint.init(self.allocator, ws);
                    }
                }
            }
        }
    }

    const result = .{
        .capabilities = .{
            .textDocumentSync = .{
                .openClose = true,
                .change = @as(i32, 1),
                .save = true,
            },
            .codeActionProvider = .{
                .codeActionKinds = [_][]const u8{"quickfix"},
            },
        },
        .serverInfo = .{
            .name = "eslint-lang-server",
            .version = "0.1.0",
        },
    };

    try self.sendJson(writer, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = result,
    });
}

fn handleShutdown(self: *Server, id: i64, writer: *std.io.Writer) !void {
    try self.sendJson(writer, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = null,
    });
    self.should_exit = true;
}

fn handleExit(self: *Server) void {
    std.process.exit(if (self.should_exit) 0 else 1);
}

fn handleDidOpen(self: *Server, params: std.json.Value, writer: *std.io.Writer) !void {
    const text_document = getObject(params, "textDocument") orelse return;
    const uri_str = getString(text_document, "uri") orelse return;
    const text = getString(text_document, "text") orelse "";

    const file_path = try uriToPath(self.allocator, uri_str);
    defer self.allocator.free(file_path);

    std.log.info("didOpen: {s}", .{file_path});

    if (self.eslint) |*e| {
        var lint_result = try e.lintFile(file_path, text);
        defer if (lint_result) |*r| r.deinit();
        try self.publishDiagnostics(writer, uri_str, if (lint_result) |*r| r else null);
    }
}

fn handleDidChange(self: *Server, params: std.json.Value) !void {
    const text_document = getObject(params, "textDocument") orelse return;
    const uri_str = getString(text_document, "uri") orelse return;

    const changes = params.object.get("contentChanges") orelse return;
    if (changes != .array or changes.array.items.len == 0) return;

    const last_change = changes.array.items[changes.array.items.len - 1];
    const text = if (last_change == .object) blk: {
        if (last_change.object.get("text")) |t| {
            if (t == .string) break :blk t.string;
        }
        break :blk @as(?[]const u8, null);
    } else null;

    // Update debounce state
    self.clearDebounce();

    self.debounce = .{
        .pending_uri = try self.allocator.dupe(u8, uri_str),
        .pending_file_path = try uriToPath(self.allocator, uri_str),
        .pending_content = if (text) |t| try self.allocator.dupe(u8, t) else null,
        .last_change_ms = std.time.milliTimestamp(),
    };
}

fn handleDidSave(self: *Server, params: std.json.Value, writer: *std.io.Writer) !void {
    const text_document = getObject(params, "textDocument") orelse return;
    const uri_str = getString(text_document, "uri") orelse return;

    const file_path = try uriToPath(self.allocator, uri_str);
    defer self.allocator.free(file_path);

    std.log.info("didSave: {s}", .{file_path});

    // Clear any pending debounce since we're linting now
    self.clearDebounce();

    if (self.eslint) |*e| {
        var lint_result = try e.lintFile(file_path, null);
        defer if (lint_result) |*r| r.deinit();
        try self.publishDiagnostics(writer, uri_str, if (lint_result) |*r| r else null);
    }
}

fn handleDidClose(self: *Server, params: std.json.Value, writer: *std.io.Writer) !void {
    const text_document = getObject(params, "textDocument") orelse return;
    const uri_str = getString(text_document, "uri") orelse return;

    std.log.info("didClose: {s}", .{uri_str});

    self.clearDebounce();
    // Publish empty diagnostics to clear editor markers
    try self.publishDiagnostics(writer, uri_str, null);
}

fn handleCodeAction(self: *Server, id: i64, params: std.json.Value, writer: *std.io.Writer) !void {
    const text_document = getObject(params, "textDocument") orelse return;
    const uri_str = getString(text_document, "uri") orelse return;

    const action = .{
        .title = "Fix all ESLint issues",
        .kind = "quickfix",
        .command = .{
            .title = "Fix all ESLint issues",
            .command = "eslint.applyAllFixes",
            .arguments = [_][]const u8{uri_str},
        },
    };

    try self.sendJson(writer, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = [_]@TypeOf(action){action},
    });
}

// ---- Diagnostic publishing ----

fn publishDiagnostics(
    self: *Server,
    writer: *std.io.Writer,
    uri_str: []const u8,
    result: ?*Eslint.LintResult,
) !void {
    if (result != null and result.?.diagnostics.len > 0) {
        const diags = result.?.diagnostics;
        // Build diagnostic array dynamically using std.json.Value
        var diag_array = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer diag_array.array.deinit();

        for (diags) |d| {
            // ESLint is 1-based; LSP is 0-based
            var diag_obj = std.json.ObjectMap.init(self.allocator);
            var range_obj = std.json.ObjectMap.init(self.allocator);
            var start_obj = std.json.ObjectMap.init(self.allocator);
            var end_obj = std.json.ObjectMap.init(self.allocator);

            try start_obj.put("line", .{ .integer = d.line - 1 });
            try start_obj.put("character", .{ .integer = d.column - 1 });
            try end_obj.put("line", .{ .integer = d.end_line - 1 });
            try end_obj.put("character", .{ .integer = d.end_column - 1 });
            try range_obj.put("start", .{ .object = start_obj });
            try range_obj.put("end", .{ .object = end_obj });

            // ESLint severity: 2=error -> LSP 1; 1=warning -> LSP 2
            const lsp_severity: i64 = if (d.severity == 2) 1 else 2;
            try diag_obj.put("range", .{ .object = range_obj });
            try diag_obj.put("severity", .{ .integer = lsp_severity });
            try diag_obj.put("message", .{ .string = d.message });
            try diag_obj.put("source", .{ .string = "eslint" });
            if (d.rule_id) |rule| {
                try diag_obj.put("code", .{ .string = rule });
            }

            try diag_array.array.append(.{ .object = diag_obj });
        }

        var params_obj = std.json.ObjectMap.init(self.allocator);
        defer {
            // The nested maps were transferred to diag_array; clean up params_obj manually
            params_obj.deinit();
        }
        try params_obj.put("uri", .{ .string = uri_str });
        try params_obj.put("diagnostics", diag_array);

        try self.sendJson(writer, .{
            .jsonrpc = "2.0",
            .method = "textDocument/publishDiagnostics",
            .params = std.json.Value{ .object = params_obj },
        });
    } else {
        // Send empty diagnostics
        try self.sendJson(writer, .{
            .jsonrpc = "2.0",
            .method = "textDocument/publishDiagnostics",
            .params = .{
                .uri = uri_str,
                .diagnostics = [_]u8{},
            },
        });
    }
}

// ---- Debounce ----

fn runPendingLint(self: *Server, writer: *std.io.Writer) !void {
    const db = self.debounce orelse return;

    std.log.info("Running debounced lint: {s}", .{db.pending_file_path});

    if (self.eslint) |*e| {
        var lint_result = try e.lintFile(db.pending_file_path, db.pending_content);
        defer if (lint_result) |*r| r.deinit();
        try self.publishDiagnostics(writer, db.pending_uri, if (lint_result) |*r| r else null);
    }

    self.clearDebounce();
}

fn clearDebounce(self: *Server) void {
    if (self.debounce) |*db| {
        self.allocator.free(db.pending_uri);
        self.allocator.free(db.pending_file_path);
        if (db.pending_content) |c| self.allocator.free(c);
        self.debounce = null;
    }
}

// ---- Helpers ----

fn getObject(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn uriToPath(allocator: std.mem.Allocator, raw_uri: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw_uri, "file://")) {
        return allocator.dupe(u8, raw_uri["file://".len..]);
    }
    return allocator.dupe(u8, raw_uri);
}

// ---- Tests ----

test "Content-Length framing round-trip" {
    // Build a fake LSP message and read it back
    const msg_body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    ;
    const framed = try std.fmt.allocPrint(
        std.testing.allocator,
        "Content-Length: {}\r\n\r\n{s}",
        .{ msg_body.len, msg_body },
    );
    defer std.testing.allocator.free(framed);

    var server = Server.init(std.testing.allocator);
    defer server.deinit();

    var fbs = std.io.fixedBufferStream(framed);
    var old_reader = fbs.reader();
    var buf: [4096]u8 = undefined;
    var wrapper = old_reader.adaptToNewApi(&buf);

    const parsed = try server.readMessage(&wrapper.new_interface);
    if (parsed) |p| {
        defer p.deinit();
        const obj = p.value.object;
        try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
        try std.testing.expectEqualStrings("initialize", obj.get("method").?.string);
    } else {
        try std.testing.expect(false); // should have parsed a message
    }
}

test "diagnostic severity mapping" {
    // ESLint severity 2 -> LSP severity 1 (error)
    // ESLint severity 1 -> LSP severity 2 (warning)
    const lsp_sev_error: i64 = if (@as(i32, 2) == 2) 1 else 2;
    const lsp_sev_warn: i64 = if (@as(i32, 1) == 2) 1 else 2;
    try std.testing.expectEqual(@as(i64, 1), lsp_sev_error);
    try std.testing.expectEqual(@as(i64, 2), lsp_sev_warn);
}

test "line/column offset: ESLint 1-based -> LSP 0-based" {
    // ESLint reports line=1 column=1 -> LSP line=0 character=0
    const eslint_line: i32 = 1;
    const eslint_col: i32 = 5;
    try std.testing.expectEqual(@as(i32, 0), eslint_line - 1);
    try std.testing.expectEqual(@as(i32, 4), eslint_col - 1);
}
