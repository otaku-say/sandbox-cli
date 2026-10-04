//! 命令上下文与通用 HTTP 辅助。
const std = @import("std");
const httpc = @import("httpc.zig");
const cfg = @import("cfg.zig");
const envd = @import("envd.zig");

/// 非 2xx 响应的现场（供重试判断与错误输出）。
pub const HttpError = struct {
    status: u16 = 0,
    body: []const u8 = "",
    headers: httpc.Headers = &.{},

    /// 生命周期互斥 / 瞬态错误：值得按 Retry-After 重试。
    pub fn retryable(self: HttpError) bool {
        return self.status == 503 or self.status == 409 or self.status == 408;
    }

    /// 等待秒数（Retry-After 缺省 fallback，夹在 0..30 之间）。
    pub fn retryAfter(self: HttpError, fallback: u64) u64 {
        for (self.headers) |hh| {
            if (std.ascii.eqlIgnoreCase(hh.name, "Retry-After")) {
                const v = std.fmt.parseInt(u64, std.mem.trim(u8, hh.value, " \t"), 10) catch return fallback;
                return @min(v, 30);
            }
        }
        return fallback;
    }
};

pub const Ctx = struct {
    arena: std.mem.Allocator,
    client: *std.http.Client,
    out: *std.Io.Writer,
    io: std.Io,
    /// 控制面地址
    api: []const u8,
    /// 控制面 API Key（可空）
    key: ?[]const u8,
    /// 最近一次非 2xx 响应的现场（status/headers 供重试判断，如 rm 的 503 + Retry-After）。
    last_error: HttpError = .{},

    /// 控制面请求（GET/DELETE 无 body；POST/PUT 自动带 JSON Content-Type）。
    /// 非 2xx 打印 "HTTP <status>: <body>" 并返回 error.HttpError（现场见 last_error）。
    pub fn control(self: *Ctx, method: httpc.Method, path: []const u8, payload: ?[]const u8, buf: []u8) !httpc.Response {
        const res = try self.controlRaw(method, path, payload, &.{}, buf);
        if (!res.ok()) {
            try self.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
            return error.HttpError;
        }
        return res;
    }

    /// 任意方法/路径的控制面请求（非 2xx 不报错，原样返回；raw 命令与需要判状态码的重试逻辑用）。
    ///
    /// 鉴权：优先 `Authorization: Bearer <key>`，同时带 `X-API-Key: <key>`；
    /// 若服务端回 401/403，再用仅 X-API-Key 的头重试一次（回退路径）。
    pub fn controlRaw(
        self: *Ctx,
        method: httpc.Method,
        path: []const u8,
        payload: ?[]const u8,
        extra: httpc.Headers,
        buf: []u8,
    ) !httpc.Response {
        if (self.api.len == 0) {
            try self.out.print("错误：缺少环境变量 CUBESANDBOX_API_URL\n", .{});
            return error.MissingConfig;
        }
        const url = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ trimSlash(self.api), path });

        var hs: [16]std.http.Header = undefined;
        var n: usize = 0;
        hs[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        if (payload != null) {
            hs[n] = httpc.json_ct;
            n += 1;
        }
        var has_bearer = false;
        if (self.key) |k| {
            hs[n] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.arena, "Bearer {s}", .{k}) };
            n += 1;
            has_bearer = true;
            hs[n] = .{ .name = "X-API-Key", .value = k };
            n += 1;
        }
        for (extra) |h| {
            if (n >= hs.len) break;
            hs[n] = h;
            n += 1;
        }

        var res = try httpc.request(self.client, method, url, hs[0..n], payload, buf);

        // 回退：Bearer 头被拒（401/403）→ 只带 X-API-Key 再试一次
        if (has_bearer and (res.status == 401 or res.status == 403)) {
            var hs2: [16]std.http.Header = undefined;
            var n2: usize = 0;
            hs2[n2] = hs[0];
            n2 += 1;
            if (payload != null) {
                hs2[n2] = httpc.json_ct;
                n2 += 1;
            }
            hs2[n2] = .{ .name = "X-API-Key", .value = self.key.? };
            n2 += 1;
            for (extra) |h| {
                if (n2 >= hs2.len) break;
                hs2[n2] = h;
                n2 += 1;
            }
            res = try httpc.request(self.client, method, url, hs2[0..n2], payload, buf);
        }

        if (res.ok()) {
            self.last_error = .{};
        } else {
            // body 指向可复用的读缓冲，必须复制
            self.last_error = .{
                .status = res.status,
                .body = self.arena.dupe(u8, res.body) catch "",
                .headers = res.headers,
            };
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
