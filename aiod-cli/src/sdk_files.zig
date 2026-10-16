//! Core SDK —— 文件域（/v2/fs/*）。样例实现：read / write（其余命令照此扩展）。
const std = @import("std");
const sdkmod = @import("sdk.zig");

const Sdk = sdkmod.Sdk;

pub const ReadSpec = struct {
    path: []const u8,
    start: ?i64 = null,
    end: ?i64 = null,
    user: ?[]const u8 = null,
};

/// GET /v2/fs/read?path=...&start=&end=（用户缺省不带 user 参数）
pub fn readFile(self: *Sdk, spec: ReadSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("path=");
    try w.writeAll(try sdkmod.qenc(self.arena, spec.path));
    if (spec.start) |v| try w.print("&start={d}", .{v});
    if (spec.end) |v| try w.print("&end={d}", .{v});
    if (spec.user) |u| {
        try w.writeAll("&user=");
        try w.writeAll(try sdkmod.qenc(self.arena, u));
    }
    const path = try std.fmt.allocPrint(self.arena, "/v2/fs/read?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const WriteSpec = struct {
    path: []const u8,
    content: []const u8,
    append: bool = false,
    encoding: ?[]const u8 = null,
    leading_newline: bool = false,
    trailing_newline: bool = false,
};

/// POST /v2/fs/write（文本写入；二进制用 put/upload）
pub fn writeFile(self: *Sdk, spec: WriteSpec) ![]const u8 {
    const cap = (spec.path.len + spec.content.len) * 2 + 512;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, cap));
    try w.writeAll("{\"path\":\"");
    try sdkmod.esc(&w, spec.path);
    try w.writeAll("\",\"content\":\"");
    try sdkmod.esc(&w, spec.content);
    try w.writeAll("\"");
    if (spec.append) try w.writeAll(",\"append\":true");
    if (spec.encoding) |e| {
        try w.writeAll(",\"encoding\":\"");
        try sdkmod.esc(&w, e);
        try w.writeAll("\"");
    }
    if (spec.leading_newline) try w.writeAll(",\"leading_newline\":true");
    if (spec.trailing_newline) try w.writeAll(",\"trailing_newline\":true");
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/write", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

pub const ListSpec = struct {
    path: []const u8,
    user: ?[]const u8 = null,
};

/// GET /v2/fs/list?path=...
pub fn list(self: *Sdk, spec: ListSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("path=");
    try w.writeAll(try sdkmod.qenc(self.arena, spec.path));
    if (spec.user) |u| {
        try w.writeAll("&user=");
        try w.writeAll(try sdkmod.qenc(self.arena, u));
    }
    const path = try std.fmt.allocPrint(self.arena, "/v2/fs/list?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/sandbox（沙箱画像）
pub fn sandboxInfo(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/sandbox", null, buf);
    return self.arena.dupe(u8, res.body);
}
