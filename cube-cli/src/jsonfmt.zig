//! 表格输出小工具：把 std.json.Value 变成人类可读的短文本（tolerant：字段缺失/类型变化都不炸）。
const std = @import("std");

/// Value → 短文本（字符串原样；数字/布尔就地格式化；对象/数组压成紧凑 JSON）。
pub fn valueStr(arena: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .null => "-",
        .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        else => blk: {
            var w = std.Io.Writer.fixed(try arena.alloc(u8, 64 << 10));
            w.print("{f}", .{std.json.fmt(v, .{})}) catch {};
            break :blk w.buffered();
        },
    };
}

/// 取对象里的某个键（不存在返回 null）。
pub fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// 打印一行 `标签  值`（值已转成字符串）。
pub fn field(out: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try out.print("{s:<10}{s}\n", .{ label, value });
}

/// 查询串百分号编码。keep_eq=true 时保留 `=` `:` `/`
/// （上游的 `metadata=k=v` 过滤依赖字面量 `=`，raw/logs 共用）。
pub fn qenc(arena: std.mem.Allocator, s: []const u8, keep_eq: bool) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        n += if (safeChar(ch, keep_eq)) 1 else 3;
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |ch| {
        if (safeChar(ch, keep_eq)) {
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

fn safeChar(ch: u8, keep_eq: bool) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or
        (keep_eq and (ch == '=' or ch == ':' or ch == '/'));
}