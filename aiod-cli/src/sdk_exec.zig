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

/// GET /v2/commands/<id>（按 offset 增量读）
pub fn commandById(self: *Sdk, id: []const u8, offset: ?i64, stderr_offset: ?i64, wait: bool, wait_timeout_s: ?i64) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 1024));
    var n: usize = 0;
    if (offset) |o| {
        try w.print("offset={d}", .{o});
        n += 1;
    }
    if (stderr_offset) |o| {
        if (n > 0) try w.writeAll("&");
        try w.print("stderr_offset={d}", .{o});
        n += 1;
    }
    if (wait) {
        if (n > 0) try w.writeAll("&");
        try w.writeAll("wait=true");
        n += 1;
        if (wait_timeout_s) |t| try w.print("&wait_timeout={d}", .{t});
    }
    const path = if (n > 0)
        try std.fmt.allocPrint(self.arena, "/v2/commands/{s}?{s}", .{ id, w.buffered() })
    else
        try std.fmt.allocPrint(self.arena, "/v2/commands/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/commands/<id>/kill
pub fn kill(self: *Sdk, id: []const u8, signal: ?[]const u8) ![]const u8 {
    const body = if (signal) |s|
        try std.fmt.allocPrint(self.arena, "{{\"signal\":\"{s}\"}}", .{s})
    else
        "{\"signal\":\"SIGKILL\"}";
    const path = try std.fmt.allocPrint(self.arena, "/v2/commands/{s}/kill", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, body, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/commands/<id>/stdin
pub fn sendStdin(self: *Sdk, id: []const u8, text: []const u8, enter: bool) ![]const u8 {
    const cap = text.len * 2 + 128;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, cap));
    try w.writeAll("{\"input\":\"");
    try escaped(&w, text);
    try w.writeAll("\"");
    if (enter) try w.writeAll(",\"enter\":true");
    try w.writeAll("}");
    const path = try std.fmt.allocPrint(self.arena, "/v2/commands/{s}/stdin", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/commands/sessions
pub fn sessionCreate(self: *Sdk, id: []const u8, cwd: ?[]const u8, env_json: ?[]const u8, user: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 1 << 16));
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
