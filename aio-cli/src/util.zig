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

    /// 位置参数从 from 开始拼成一条串。
    pub fn joinFrom(self: Args, from: usize, sep: []const u8) []const u8 {
        if (self.pos.len <= from) return "";
        return std.mem.join(std.heap.smp_allocator, sep, self.pos[from..]) catch "";
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

/// JSON 字符串转义（不依赖 std.json 的 Stringify，行为可控）。
pub fn jsonEscape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var n: usize = 0;
    for (s) |c| {
        n += switch (c) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => if (c < 0x20) 6 else 1,
        };
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |c| {
        switch (c) {
            '"' => {
                out[i] = '\\';
                out[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                out[i] = '\\';
                out[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                out[i] = '\\';
                out[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                out[i] = '\\';
                out[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                out[i] = '\\';
                out[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    _ = std.fmt.bufPrint(out[i .. i + 6], "\\u{x:0>4}", .{c}) catch {};
                    i += 6;
                } else {
                    out[i] = c;
                    i += 1;
                }
            },
        }
    }
    return out[0..i];
}

pub const BUF = 2 << 20; // 2 MiB

/// 百分号编码（保留 /，与 cmd_files 行为一致）。
pub fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        n += if (safe) 1 else 3;
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        if (safe) {
            out[i] = ch;
            i += 1;
        } else {
            out[i] = '%';
            out[i + 1] = hex[ch >> 4];
            out[i + 2] = hex[ch & 0x0F];
            i += 3;
        }
    }
    return out[0..i];
}

/// 与 jsonEscape 输出等长的上界（用于精确分配写缓冲）。
pub fn jsonEscapedLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        n += switch (c) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => if (c < 0x20) 6 else 1,
        };
    }
    return n;
}
