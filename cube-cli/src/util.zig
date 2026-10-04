//! 参数解析（--k=v / --flag / 位置参数）。
const std = @import("std");

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
