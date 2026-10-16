//! Core SDK —— 持久卷域操作（控制面 REST）。
//!
//! 包含卷列表、创建卷、查询卷详情与删除卷。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const envd = @import("envd.zig");

const Sdk = sdkmod.Sdk;

/// 查询卷列表（GET /volumes）。返回响应体 JSON。
pub fn volumeList(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, "/volumes", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// 创建持久卷（POST /volumes）。返回响应体 JSON。
pub fn volumeCreate(self: *Sdk, name: ?[]const u8, driver: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("{");
    var comma = false;
    if (name) |n| {
        if (n.len > 0) {
            try w.print("\"name\":\"{s}\"", .{try envd.jsonEscape(self.arena, n)});
            comma = true;
        }
    }
    if (driver) |d| {
        if (comma) try w.writeAll(",");
        try w.print("\"driver\":\"{s}\"", .{try envd.jsonEscape(self.arena, d)});
        comma = true;
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.POST, "/volumes", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// 查询持久卷详情（GET /volumes/<id>）。返回响应体 JSON。
pub fn volumeInfo(self: *Sdk, vid: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/volumes/{s}", .{vid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// 删除持久卷（DELETE /volumes/<id>）。
pub fn volumeDelete(self: *Sdk, vid: []const u8) !void {
    const path = try std.fmt.allocPrint(self.arena, "/volumes/{s}", .{vid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    _ = try self.control(.DELETE, path, null, buf);
}
