//! Core SDK —— 控制面原生 API 调用（raw api_call）。
//!
//! 允许透传任意 HTTP 方法和路径，支持请求体与查询参数。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const envd = @import("envd.zig");

const Sdk = sdkmod.Sdk;

pub fn apiCall(self: *Sdk, method_str: []const u8, path_str: []const u8, body: ?[]const u8, query: ?std.json.ObjectMap) ![]const u8 {
    var buf_m: [16]u8 = undefined;
    if (method_str.len == 0 or method_str.len > buf_m.len) return error.BadMethod;
    for (method_str, 0..) |ch, i| buf_m[i] = std.ascii.toUpper(ch);
    const method = std.meta.stringToEnum(std.http.Method, buf_m[0..method_str.len]) orelse return error.BadMethod;

    var path = path_str;
    if (path.len == 0 or path[0] != '/') {
        path = try std.fmt.allocPrint(self.arena, "/{s}", .{path});
    }

    if (query) |q| {
        var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 16 << 10));
        var count: usize = 0;
        var it = q.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            const v_str = switch (v) {
                .string => |s| s,
                .integer => |i| try std.fmt.allocPrint(self.arena, "{d}", .{i}),
                .bool => |b| if (b) "true" else "false",
                else => continue,
            };
            if (count > 0) try w.writeAll("&");
            count += 1;
            try w.print("{s}={s}", .{ try envd.urlEncode(self.arena, k), try envd.urlEncode(self.arena, v_str) });
        }
        if (count > 0) {
            const sep: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?";
            path = try std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ path, sep, w.buffered() });
        }
    }

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const req_body: ?[]const u8 = if (body) |b| b else if (method.requestHasBody()) "{}" else null;
    const res = try self.controlRaw(method, path, req_body, &.{}, buf);
    if (!res.ok()) return error.HttpError;
    return self.arena.dupe(u8, res.body);
}
