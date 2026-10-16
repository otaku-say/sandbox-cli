//! Core SDK —— 杂项域（代码执行、文件监听、MCP Hub、沙箱画像）。
const std = @import("std");
const sdkmod = @import("sdk.zig");

const Sdk = sdkmod.Sdk;

pub const CodeRunSpec = struct {
    code: []const u8,
    language: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    timeout: ?i64 = null,
};

/// POST /v2/code/execute
pub fn codeRun(self: *Sdk, spec: CodeRunSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, spec.code.len * 2 + 1024));
    try w.writeAll("{\"code\":\"");
    try sdkmod.esc(&w, spec.code);
    try w.print("\",\"language\":\"{s}\"", .{spec.language orelse "python"});
    if (spec.session_id) |s| {
        try w.writeAll(",\"session_id\":\"");
        try sdkmod.esc(&w, s);
        try w.writeAll("\"");
    }
    if (spec.timeout) |t| try w.print(",\"timeout\":{d}", .{t});
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/code/execute", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/code/info
pub fn codeInfo(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/code/info", null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const WatchCreateSpec = struct {
    path: ?[]const u8 = null,
    recursive: bool = false,
    debounce: ?i64 = null,
    exclude: ?[]const []const u8 = null,
    include_patterns: ?[]const []const u8 = null,
};

/// POST /v2/watch
pub fn watchCreate(self: *Sdk, spec: WatchCreateSpec) ![]const u8 {
    const p = spec.path orelse "/";
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, p.len * 2 + 2048));
    try w.writeAll("{\"path\":\"");
    try sdkmod.esc(&w, p);
    try w.writeAll("\"");
    if (spec.recursive) try w.writeAll(",\"recursive\":true");
    if (spec.debounce) |d| try w.print(",\"debounce\":{d}", .{d});
    if (spec.exclude) |arr| {
        try w.writeAll(",\"exclude\":[");
        for (arr, 0..) |it, idx| {
            if (idx > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try sdkmod.esc(&w, it);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (spec.include_patterns) |arr| {
        try w.writeAll(",\"include_patterns\":[");
        for (arr, 0..) |it, idx| {
            if (idx > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try sdkmod.esc(&w, it);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/watch", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/watch/<id>/poll
pub fn watchPoll(self: *Sdk, id: []const u8, cursor: ?[]const u8, limit: ?i64, timeout: ?i64) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 512));
    try w.print("/v2/watch/{s}/poll", .{id});
    var first = true;
    if (cursor) |c| {
        try w.print("?cursor={s}", .{try sdkmod.qenc(self.arena, c)});
        first = false;
    }
    if (limit) |l| {
        try w.print("{s}limit={d}", .{ if (first) "?" else "&", l });
        first = false;
    }
    if (timeout) |t| {
        try w.print("{s}timeout={d}", .{ if (first) "?" else "&", t });
    }
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, w.buffered(), null, buf);
    return self.arena.dupe(u8, res.body);
}

/// DELETE /v2/watch/<id>
pub fn watchRm(self: *Sdk, id: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/v2/watch/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.DELETE, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/watch
pub fn watchLs(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/watch", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /mcp（沙箱内的 MCP Hub 反向代理）
pub fn mcpHub(self: *Sdk, method: []const u8, params_json: ?[]const u8) ![]const u8 {
    const plen: usize = if (params_json) |p| p.len else 0;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, plen + 512));
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"");
    try sdkmod.esc(&w, method);
    try w.writeAll("\"");
    if (params_json) |p| {
        try w.print(",\"params\":{s}", .{p});
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/mcp", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/sandbox
pub fn sandboxInfo(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/sandbox", null, buf);
    return self.arena.dupe(u8, res.body);
}
