//! 参数解析与通用辅助。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const httpc = @import("httpc.zig");

pub const Ctx = ctxmod.Ctx;

/// 解析结果：
///   `--k=v` / `--flag`   → flags
///   其它                 → pos（保持原顺序）
pub const Args = struct {
    pos: []const []const u8 = &.{},
    flags: []const [2][]const u8 = &.{},

    pub fn get(self: Args, name: []const u8) ?[]const u8 {
        for (self.flags) |kv| {
            if (std.mem.eql(u8, kv[0], name)) return kv[1];
        }
        return null;
    }

    pub fn has(self: Args, name: []const u8) bool {
        return self.get(name) != null;
    }

    pub fn getOr(self: Args, name: []const u8, dflt: []const u8) []const u8 {
        return self.get(name) orelse dflt;
    }

    pub fn at(self: Args, i: usize) ?[]const u8 {
        return if (i < self.pos.len) self.pos[i] else null;
    }
};

pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) !Args {
    var npos: usize = 0;
    var nflag: usize = 0;
    for (argv) |a| {
        if (std.mem.startsWith(u8, a, "--")) nflag += 1 else npos += 1;
    }
    const pos = try arena.alloc([]const u8, npos);
    const flags = try arena.alloc([2][]const u8, nflag);
    var pi: usize = 0;
    var fi: usize = 0;
    for (argv) |a| {
        if (std.mem.startsWith(u8, a, "--")) {
            const body = a[2..];
            if (std.mem.indexOfScalar(u8, body, '=')) |i| {
                flags[fi] = .{ body[0..i], body[i + 1 ..] };
            } else {
                flags[fi] = .{ body, "true" };
            }
            fi += 1;
        } else {
            pos[pi] = a;
            pi += 1;
        }
    }
    return .{ .pos = pos, .flags = flags };
}

/// 组装鉴权头（存储由调用方提供，生命周期需覆盖请求）。
pub fn authHeaders(c: *Ctx, storage: *[2]std.http.Header) httpc.Headers {
    var n: usize = 0;
    storage[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (c.key) |k| {
        storage[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return storage[0..n];
}

/// 带 JSON Content-Type 的鉴权头。
pub fn jsonHeaders(c: *Ctx, storage: *[3]std.http.Header) httpc.Headers {
    var n: usize = 0;
    storage[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    storage[n] = httpc.json_ct;
    n += 1;
    if (c.key) |k| {
        storage[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return storage[0..n];
}

/// 打印响应；非 2xx 时把状态码与正文一起报出，返回 error。
pub fn printOrFail(c: *Ctx, res: httpc.Response) !void {
    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    try c.out.print("{s}\n", .{res.body});
}

pub const BUF = 2 << 20; // 2 MiB
