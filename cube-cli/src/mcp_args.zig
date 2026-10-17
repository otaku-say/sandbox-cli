//! MCP 工具参数读取：统一的必填/类型校验与错误文案。
//! 纯函数层——不打印、不 exit、不依赖终端上下文。
//!
//! 用法（handler 内）：
//!   const path = a.str(arena, "path") catch return srv.argError(a);
//!   const off  = a.intOr("offset", 0) catch return srv.argError(a);
const std = @import("std");

pub const ArgError = error{Arg};
/// 分配 + 校验合并的错误集（会分配内存的读取函数用）。
pub const ArgErr = error{Arg} || std.mem.Allocator.Error;

pub const Args = struct {
    v: std.json.Value = .null,
    /// 最近一次校验失败的原因（供上层拼 "参数错误：..."）
    msg: []const u8 = "",

    pub fn init(v: std.json.Value) Args {
        return .{ .v = v };
    }

    pub fn none() Args {
        return .{ .v = .null };
    }

    fn object(self: Args) ?std.json.ObjectMap {
        return switch (self.v) {
            .object => |o| o,
            else => null,
        };
    }

    fn get(self: Args, name: []const u8) ?std.json.Value {
        const o = self.object() orelse return null;
        return o.get(name);
    }

    pub fn has(self: Args, name: []const u8) bool {
        return self.get(name) != null;
    }

    fn typeName(v: std.json.Value) []const u8 {
        return switch (v) {
            .null => "null",
            .bool => "bool",
            .integer, .float => "number",
            .string => "string",
            .array => "array",
            .object => "object",
            else => "value",
        };
    }

    fn setf(self: *Args, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        self.msg = std.fmt.allocPrint(arena, fmt, args) catch "（错误信息分配失败）";
    }

    // ---------------- 字符串 ----------------

    pub fn str(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgError![]const u8 {
        const v = self.get(name) orelse {
            self.setf(arena, "{s} 为必填参数", .{name});
            return ArgError.Arg;
        };
        if (v != .string) {
            self.setf(arena, "{s} 需要是字符串（收到 {s}）", .{ name, typeName(v) });
            return ArgError.Arg;
        }
        return v.string;
    }

    /// 可选字符串：**给了就必须是字符串**。
    /// 类型不对时返回参数错误，而不是静默忽略——静默忽略会让模型以为参数生效了，
    /// 实际却走了默认值（例如把 user/cwd 传成数字）。
    pub fn strOpt(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgError!?[]const u8 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .string => |s| s,
            .null => null,
            else => {
                self.setf(arena, "{s} 需要是字符串（收到 {s}）", .{ name, typeName(v) });
                return ArgError.Arg;
            },
        };
    }

    // ---------------- 数字 ----------------

    pub fn intOpt(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgError!?i64 {
        const v = self.get(name) orelse return null;
        switch (v) {
            .integer => |i| return i,
            .float => |f| {
                // 防 NaN/越界把 @intFromFloat 变成 panic（panic = 服务进程直接死）
                if (std.math.isNan(f) or f < -9.007199254740992e15 or f > 9.007199254740992e15) {
                    self.setf(arena, "{s} 超出可表示的整数范围", .{name});
                    return ArgError.Arg;
                }
                return @intFromFloat(f);
            },
            .string => |s| {
                const t = std.mem.trim(u8, s, " \t");
                return std.fmt.parseInt(i64, t, 10) catch {
                    self.setf(arena, "{s} 需要是整数（收到字符串 \"{s}\"）", .{ name, s });
                    return ArgError.Arg;
                };
            },
            else => {
                self.setf(arena, "{s} 需要是整数（收到 {s}）", .{ name, typeName(v) });
                return ArgError.Arg;
            },
        }
    }

    pub fn intReq(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgError!i64 {
        if (self.get(name) == null) {
            self.setf(arena, "{s} 为必填参数", .{name});
            return ArgError.Arg;
        }
        return (try self.intOpt(arena, name)).?;
    }

    pub fn intOr(self: *Args, arena: std.mem.Allocator, name: []const u8, dflt: i64) ArgError!i64 {
        return (try self.intOpt(arena, name)) orelse dflt;
    }

    // ---------------- 布尔 ----------------

    pub fn boolOpt(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgError!?bool {
        const v = self.get(name) orelse return null;
        switch (v) {
            .bool => |b| return b,
            .string => |s| {
                if (std.mem.eql(u8, s, "true")) return true;
                if (std.mem.eql(u8, s, "false")) return false;
                self.setf(arena, "{s} 需要是布尔（收到字符串 \"{s}\"）", .{ name, s });
                return ArgError.Arg;
            },
            else => {
                self.setf(arena, "{s} 需要是布尔（收到 {s}）", .{ name, typeName(v) });
                return ArgError.Arg;
            },
        }
    }

    pub fn boolOr(self: *Args, arena: std.mem.Allocator, name: []const u8, dflt: bool) ArgError!bool {
        return (try self.boolOpt(arena, name)) orelse dflt;
    }

    // ---------------- 数组 / 对象 ----------------

    /// 字符串数组；单个字符串也接受（视作单元素数组）。
    pub fn strArrayOpt(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgErr!?[]const []const u8 {
        const v = self.get(name) orelse return null;
        switch (v) {
            .string => |s| {
                const out = try arena.alloc([]const u8, 1);
                out[0] = s;
                return out;
            },
            .array => |arr| {
                const out = try arena.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |it, i| {
                    if (it != .string) {
                        self.setf(arena, "{s} 的第 {d} 个元素需要是字符串", .{ name, i });
                        return ArgError.Arg;
                    }
                    out[i] = it.string;
                }
                return out;
            },
            else => {
                self.setf(arena, "{s} 需要是字符串数组（收到 {s}）", .{ name, typeName(v) });
                return ArgError.Arg;
            },
        }
    }

    /// 取原始 JSON 值（透传给上游 API 的复杂参数）。
    pub fn jsonOpt(self: Args, name: []const u8) ?std.json.Value {
        return self.get(name);
    }

    /// 取对象（env / headers / 复杂 JSON），非对象返回失败。
    pub fn objOpt(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgError!?std.json.ObjectMap {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .object => |o| o,
            else => {
                self.setf(arena, "{s} 需要是对象（收到 {s}）", .{ name, typeName(v) });
                return ArgError.Arg;
            },
        };
    }

    // ---------------- 序列化辅助 ----------------

    /// 任意 JSON 值 → 紧凑 JSON 文本（用于拼上游请求体）。上限 4 MiB。
    pub fn jsonText(arena: std.mem.Allocator, v: std.json.Value) ArgErr![]const u8 {
        var w = std.Io.Writer.fixed(try arena.alloc(u8, 4 << 20));
        std.json.Stringify.value(v, .{}, &w) catch return ArgError.Arg;
        return w.buffered();
    }

    /// 对象 → `{"k":"v",...}` JSON 文本（env 专用；值必须是字符串，否则报错）。
    pub fn objJsonText(self: *Args, arena: std.mem.Allocator, name: []const u8) ArgErr!?[]const u8 {
        const o = (try self.objOpt(arena, name)) orelse return null;
        var w = std.Io.Writer.fixed(try arena.alloc(u8, 1 << 20));
        w.writeAll("{") catch return ArgError.Arg;
        var it = o.iterator();
        var first = true;
        while (it.next()) |e| {
            const val = e.value_ptr.*;
            if (val != .string) {
                self.setf(arena, "{s}.{s} 的值需要是字符串", .{ name, e.key_ptr.* });
                return ArgError.Arg;
            }
            if (!first) w.writeAll(",") catch return ArgError.Arg;
            first = false;
            w.writeAll("\"") catch return ArgError.Arg;
            writeEscaped(&w, e.key_ptr.*) catch return ArgError.Arg;
            w.writeAll("\":\"") catch return ArgError.Arg;
            writeEscaped(&w, val.string) catch return ArgError.Arg;
            w.writeAll("\"") catch return ArgError.Arg;
        }
        w.writeAll("}") catch return ArgError.Arg;
        return w.buffered();
    }
};

/// JSON 字符串转义（不含外层引号）——控制字符一律 \\uXXXX，UTF-8 原样通过。
pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    var b: [6]u8 = undefined;
                    const t = try std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c});
                    try w.writeAll(t);
                } else {
                    try w.writeAll(&[_]u8{c});
                }
            },
        }
    }
}

/// 整体转义并加引号；写入独立 writer。
pub fn quoteInto(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    try writeEscaped(w, s);
    try w.writeAll("\"");
}
