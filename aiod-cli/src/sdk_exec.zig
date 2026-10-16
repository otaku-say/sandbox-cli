//! Core SDK —— 执行域（/v2/commands）。
//!
//! 约定：返回**数据**（响应体），不打印、不 exit。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const httpc = @import("httpc.zig");

const Sdk = sdkmod.Sdk;

pub const RunSpec = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    user: ?[]const u8 = null,
    session: ?[]const u8 = null,
    /// 已序列化的 env 对象文本，如 {"A":"B"}
    env_json: ?[]const u8 = null,
    timeout_ms: ?i64 = null,
    hard_timeout_s: ?i64 = null,
    max_output: ?i64 = null,
    /// null = 同步；"async" = 异步
    mode: ?[]const u8 = null,
};

/// POST /v2/commands
pub fn run(self: *Sdk, spec: RunSpec) ![]const u8 {
    const env_len: usize = if (spec.env_json) |e| e.len else 0;
    const cap = spec.command.len + env_len + 1024;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, cap * 2 + 4096));
    try w.writeAll("{\"command\":\"");
    try escaped(&w, spec.command);
    try w.writeAll("\"");
    if (spec.mode) |m| {
        try w.writeAll(",\"mode\":\"");
        try escaped(&w, m);
        try w.writeAll("\"");
    }
    const strs = [_]struct { k: []const u8, v: ?[]const u8 }{
        .{ .k = "cwd", .v = spec.cwd },
        .{ .k = "shell", .v = spec.shell },
        .{ .k = "user", .v = spec.user },
        .{ .k = "session", .v = spec.session },
    };
    for (strs) |s| {
        if (s.v) |v| {
            try w.print(",\"{s}\":\"", .{s.k});
            try escaped(&w, v);
            try w.writeAll("\"");
        }
    }
    if (spec.env_json) |e| try w.print(",\"env\":{s}", .{e});
    if (spec.timeout_ms) |t| try w.print(",\"timeout\":{d}", .{t});
    if (spec.hard_timeout_s) |t| try w.print(",\"hard_timeout\":{d}", .{t});
    if (spec.max_output) |m| try w.print(",\"max_output\":{d}", .{m});
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/commands", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

pub const LogSpec = struct {
    command_id: []const u8,
    offset: ?i64 = null,
    stderr_offset: ?i64 = null,
    wait: bool = false,
    wait_timeout: ?i64 = null,
};

/// GET /v2/commands/<id>?offset=...&stderr_offset=...&wait=true&wait_timeout=...
pub fn logs(self: *Sdk, spec: LogSpec) ![]const u8 {
    var qbuf: [512]u8 = undefined;
    var qn: usize = 0;
    if (spec.offset) |v| {
        const s = try std.fmt.bufPrint(qbuf[qn..], "offset={d}", .{v});
        qn += s.len;
    }
    if (spec.stderr_offset) |v| {
        const s = try std.fmt.bufPrint(qbuf[qn..], "{s}stderr_offset={d}", .{ if (qn > 0) "&" else "", v });
        qn += s.len;
    }
    if (spec.wait) {
        const s = try std.fmt.bufPrint(qbuf[qn..], "{s}wait=true", .{if (qn > 0) "&" else ""});
        qn += s.len;
    }
    if (spec.wait_timeout) |v| {
        const s = try std.fmt.bufPrint(qbuf[qn..], "{s}wait_timeout={d}", .{ if (qn > 0) "&" else "", v });
        qn += s.len;
    }
    const q: []const u8 = if (qn > 0) qbuf[0..qn] else "";
    const path = if (q.len > 0)
        try std.fmt.allocPrint(self.arena, "/v2/commands/{s}?{s}", .{ spec.command_id, q })
    else
        try std.fmt.allocPrint(self.arena, "/v2/commands/{s}", .{spec.command_id});

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/commands/<id>/kill
pub fn kill(self: *Sdk, command_id: []const u8, signal: ?[]const u8) ![]const u8 {
    const sig = signal orelse "SIGKILL";
    const body = try std.fmt.allocPrint(self.arena, "{{\"signal\":\"{s}\"}}", .{sig});
    const path = try std.fmt.allocPrint(self.arena, "/v2/commands/{s}/kill", .{command_id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, body, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/commands/<id>/stdin
pub fn stdin(self: *Sdk, command_id: []const u8, text: []const u8, enter: bool) ![]const u8 {
    const input_text = if (enter and (text.len == 0 or text[text.len - 1] != '\n'))
        try std.fmt.allocPrint(self.arena, "{s}\n", .{text})
    else
        text;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, input_text.len * 2 + 128));
    try w.writeAll("{\"input\":\"");
    try escaped(&w, input_text);
    try w.writeAll("\"}");
    const path = try std.fmt.allocPrint(self.arena, "/v2/commands/{s}/stdin", .{command_id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/commands/sessions
pub fn sessionCreate(self: *Sdk, id: []const u8, cwd: ?[]const u8, user: ?[]const u8, env_json: ?[]const u8) ![]const u8 {
    const cwd_len: usize = if (cwd) |c| c.len else 0;
    const user_len: usize = if (user) |u| u.len else 0;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, (id.len + cwd_len + user_len) * 2 + 1024));
    try w.writeAll("{\"id\":\"");
    try escaped(&w, id);
    try w.writeAll("\"");
    if (cwd) |v| {
        try w.writeAll(",\"cwd\":\"");
        try escaped(&w, v);
        try w.writeAll("\"");
    }
    if (user) |v| {
        try w.writeAll(",\"user\":\"");
        try escaped(&w, v);
        try w.writeAll("\"");
    }
    if (env_json) |e| try w.print(",\"env\":{s}", .{e});
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/commands/sessions", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/commands/sessions
pub fn sessionList(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/commands/sessions", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// DELETE /v2/commands/sessions/<id>
pub fn sessionDelete(self: *Sdk, id: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/v2/commands/sessions/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.DELETE, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

fn escaped(w: *std.Io.Writer, s: []const u8) !void {
    try sdkmod.esc(w, s);
}
