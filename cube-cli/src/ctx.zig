//! 命令上下文与通用 HTTP 辅助。
const std = @import("std");
const httpc = @import("httpc.zig");
const cfg = @import("cfg.zig");
const envd = @import("envd.zig");

pub const Ctx = struct {
    arena: std.mem.Allocator,
    client: *std.http.Client,
    out: *std.Io.Writer,
    io: std.Io,
    /// 控制面地址
    api: []const u8,
    /// 控制面 API Key（可空）
    key: ?[]const u8,

    /// 控制面请求（GET/DELETE 无 body；POST/PUT 自动带 JSON Content-Type）。
    pub fn control(self: *Ctx, method: httpc.Method, path: []const u8, payload: ?[]const u8, buf: []u8) !httpc.Response {
        const url = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ trimSlash(self.api), path });
        var hs: [3]std.http.Header = undefined;
        var n: usize = 0;
        hs[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        if (payload != null) {
            hs[n] = httpc.json_ct;
            n += 1;
        }
        if (self.key) |k| {
            hs[n] = .{ .name = "X-API-KEY", .value = k };
            n += 1;
        }
        const res = try httpc.request(self.client, method, url, hs[0..n], payload, buf);
        if (!res.ok()) {
            try self.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
            return error.HttpError;
        }
        return res;
    }

    /// 沙箱内 envd（执行代理）基址：走数据面路径风格路由。
    pub fn envdBase(self: *Ctx, sid: []const u8) ![]const u8 {
        const proxy = cfg.proxyURL() orelse {
            try self.out.print("错误：缺少环境变量 CUBESANDBOX_PROXY_URL\n", .{});
            return error.MissingConfig;
        };
        return std.fmt.allocPrint(self.arena, "{s}/sandbox/{s}/49983", .{ trimSlash(proxy), sid });
    }

    /// connect 沙箱，拿 envdAccessToken（可空）。
    pub fn connectToken(self: *Ctx, sid: []const u8, buf: []u8) !?[]const u8 {
        const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/connect", .{sid});
        const res = try self.control(.POST, path, "{}", buf);
        return envd.extractString(self.arena, res.body, "envdAccessToken");
    }
};

pub fn trimSlash(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and s[e - 1] == '/') e -= 1;
    return s[0..e];
}
