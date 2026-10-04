//! 参数解析（--k=v / --flag / 位置参数）+ 通用小工具。
const std = @import("std");
const envd = @import("envd.zig");

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 打印完立即以指定码退出（flush 先行；process.exit 不跑 defer）。
pub fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

/// POSIX 单引号转义（' → '\''）：把任意文本安全嵌入 shell 命令。
pub fn shellQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var cnt: usize = 2;
    for (s) |ch| {
        cnt += if (ch == '\'') 4 else 1;
    }
    const out = try arena.alloc(u8, cnt);
    var i: usize = 0;
    out[i] = '\'';
    i += 1;
    for (s) |ch| {
        if (ch == '\'') {
            @memcpy(out[i..][0..4], "'\\''");
            i += 4;
        } else {
            out[i] = ch;
            i += 1;
        }
    }
    out[i] = '\'';
    i += 1;
    return out[0..i];
}

/// 从 --env=K=V / --env=NAME 构建 envs JSON 片段（不含花括号）。
/// NAME 形式从**本机环境**取值 —— 敏感值不出现在命令行 / 进程列表里。
pub fn envsJson(arena: std.mem.Allocator, flags: []const [2][]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try arena.alloc(u8, 32 << 10));
    var first = true;
    for (flags) |kv| {
        if (!std.mem.eql(u8, kv[0], "env")) continue;
        var name: []const u8 = kv[1];
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, kv[1], '=')) |i| {
            name = kv[1][0..i];
            value = kv[1][i + 1 ..];
        } else {
            const z = try arena.allocSentinel(u8, kv[1].len, 0);
            @memcpy(z[0..kv[1].len], kv[1]);
            const p = std.c.getenv(z.ptr) orelse continue;
            value = std.mem.span(p);
        }
        if (!first) try w.print(",", .{});
        first = false;
        try w.print("\"{s}\":\"{s}\"", .{ name, try envd.jsonEscape(arena, value) });
    }
    return w.buffered();
}

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

    pub fn at(self: Args, i: usize) ?[]const u8 {
        return if (i < self.pos.len) self.pos[i] else null;
    }

    /// 位置参数拼成一条命令（保留原始顺序）。
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
