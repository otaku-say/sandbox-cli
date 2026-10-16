//! Core SDK —— PTY 域（/v2/pty/sessions/*）。
//!
//! 提供虚拟终端会话的创建、列表、抓屏、执行、输入、信号、调整大小和删除。
const std = @import("std");
const sdkmod = @import("sdk.zig");

const Sdk = sdkmod.Sdk;

pub const NewSpec = struct {
    id: []const u8,
    cwd: ?[]const u8 = null,
    cols: ?i64 = null,
    rows: ?i64 = null,
    retention: ?[]const u8 = null,
    user: ?[]const u8 = null,
    no_change_timeout: ?i64 = null,
};

/// POST /v2/pty/sessions
pub fn create(self: *Sdk, spec: NewSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 16 << 10));
    try w.writeAll("{\"id\":\"");
    try sdkmod.esc(&w, spec.id);
    try w.writeAll("\"");
    if (spec.cwd) |v| {
        try w.writeAll(",\"cwd\":\"");
        try sdkmod.esc(&w, v);
        try w.writeAll("\"");
    }
    if (spec.cols) |v| try w.print(",\"cols\":{d}", .{v});
    if (spec.rows) |v| try w.print(",\"rows\":{d}", .{v});
    if (spec.retention) |v| {
        try w.writeAll(",\"retention\":\"");
        try sdkmod.esc(&w, v);
        try w.writeAll("\"");
    }
    if (spec.user) |v| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, v);
        try w.writeAll("\"");
    }
    if (spec.no_change_timeout) |v| try w.print(",\"no_change_timeout\":{d}", .{v});
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/pty/sessions", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/pty/sessions
pub fn list(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/pty/sessions", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/pty/sessions/<id>
pub fn info(self: *Sdk, id: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/v2/pty/sessions/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/pty/sessions/<id>/screen
pub fn screen(self: *Sdk, id: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/v2/pty/sessions/{s}/screen", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const ExecSpec = struct {
    id: []const u8,
    command: []const u8,
    timeout: ?i64 = null,
    is_async: bool = false,
    hard_timeout: ?i64 = null,
    no_change_timeout: ?i64 = null,
};

/// POST /v2/pty/sessions/<id>/exec
pub fn exec(self: *Sdk, spec: ExecSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, (spec.command.len * 2) + 1024));
    try w.writeAll("{\"command\":\"");
    try sdkmod.esc(&w, spec.command);
    try w.writeAll("\"");
    if (spec.timeout) |v| try w.print(",\"timeout\":{d}", .{v});
    if (spec.is_async) try w.writeAll(",\"async\":true");
    if (spec.hard_timeout) |v| try w.print(",\"hard_timeout\":{d}", .{v});
    if (spec.no_change_timeout) |v| try w.print(",\"no_change_timeout\":{d}", .{v});
    try w.writeAll("}");

    const path = try std.fmt.allocPrint(self.arena, "/v2/pty/sessions/{s}/exec", .{spec.id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/pty/sessions/<id>/input
pub fn input(self: *Sdk, id: []const u8, text: []const u8, enter: bool) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, text.len * 2 + 256));
    try w.writeAll("{\"input\":\"");
    try sdkmod.esc(&w, text);
    try w.writeAll("\"");
    if (enter) try w.writeAll(",\"press_enter\":true") else try w.writeAll(",\"press_enter\":false");
    try w.writeAll("}");

    const path = try std.fmt.allocPrint(self.arena, "/v2/pty/sessions/{s}/input", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// DELETE /v2/pty/sessions/<id>
pub fn delete(self: *Sdk, id: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/v2/pty/sessions/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.DELETE, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/pty/sessions/<id>/signal
pub fn signal(self: *Sdk, id: []const u8, sig: []const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, sig.len * 2 + 128));
    try w.writeAll("{\"signal\":\"");
    try sdkmod.esc(&w, sig);
    try w.writeAll("\"}");

    const path = try std.fmt.allocPrint(self.arena, "/v2/pty/sessions/{s}/signal", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// PATCH /v2/pty/sessions/<id>
pub fn resize(self: *Sdk, id: []const u8, cols: ?i64, rows: ?i64, no_change_timeout: ?i64) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 256));
    try w.writeAll("{");
    var first = true;
    if (cols) |v| {
        try w.print("\"cols\":{d}", .{v});
        first = false;
    }
    if (rows) |v| {
        if (!first) try w.writeAll(",");
        try w.print("\"rows\":{d}", .{v});
        first = false;
    }
    if (no_change_timeout) |v| {
        if (!first) try w.writeAll(",");
        try w.print("\"no_change_timeout\":{d}", .{v});
    }
    try w.writeAll("}");

    const path = try std.fmt.allocPrint(self.arena, "/v2/pty/sessions/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.PATCH, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}
