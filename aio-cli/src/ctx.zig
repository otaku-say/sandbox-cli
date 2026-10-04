//! 命令上下文：运行期句柄 + 沙箱地址。
const std = @import("std");

pub const Ctx = struct {
    io: std.Io,
    client: *std.http.Client,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    /// aiod 网关基址（末尾无斜杠），如 https://<host>/sandbox/<id>/8080
    base: []const u8,
    /// 可空鉴权 Key
    key: ?[]const u8,

    /// 拼完整 URL：`try c.url("/v2/commands")`
    pub fn url(self: *Ctx, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.base, path });
    }

    /// 带格式化路径：`try c.urlFmt("/v2/commands/{s}", .{id})`
    pub fn urlFmt(self: *Ctx, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const p = try std.fmt.allocPrint(self.arena, fmt, args);
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.base, p });
    }
};
