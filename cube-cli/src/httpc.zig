//! HTTP 客户端封装：TLS + JSON，基于 std.http.Client（Zig 0.17 的新 Io 模型）
const std = @import("std");

pub const Headers = []const std.http.Header;

pub const Response = struct {
    status: u16,
    body: []const u8,
};

/// GET：响应体写入调用方提供的 buf（写满会返回 WriteFailed，缓冲区给足即可）。
pub fn get(client: *std.http.Client, url: []const u8, headers: Headers, buf: []u8) !Response {
    var w = std.Io.Writer.fixed(buf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = headers,
        .response_writer = &w,
    });
    return .{ .status = @intFromEnum(res.status), .body = w.buffered() };
}

/// POST（JSON body）。
pub fn post(client: *std.http.Client, url: []const u8, headers: Headers, payload: []const u8, buf: []u8) !Response {
    var w = std.Io.Writer.fixed(buf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = headers,
        .response_writer = &w,
    });
    return .{ .status = @intFromEnum(res.status), .body = w.buffered() };
}
