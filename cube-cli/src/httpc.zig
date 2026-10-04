//! HTTP 核心：所有请求走 std.http.Client。
//!
//! 约定：响应体写入调用方提供的 buf（建议 ≥ 2 MiB）；需要更大响应时显式传入更大缓冲。
const std = @import("std");

pub const Headers = []const std.http.Header;
pub const Method = std.http.Method;

pub const Response = struct {
    status: u16,
    body: []const u8,

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub fn request(
    client: *std.http.Client,
    method: Method,
    url: []const u8,
    headers: Headers,
    payload: ?[]const u8,
    buf: []u8,
) !Response {
    var w = std.Io.Writer.fixed(buf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = headers,
        .response_writer = &w,
    });
    return .{ .status = @intFromEnum(res.status), .body = w.buffered() };
}

pub fn get(client: *std.http.Client, url: []const u8, headers: Headers, buf: []u8) !Response {
    return request(client, .GET, url, headers, null, buf);
}

pub fn del(client: *std.http.Client, url: []const u8, headers: Headers, buf: []u8) !Response {
    return request(client, .DELETE, url, headers, null, buf);
}

/// POST JSON：headers 需含 Content-Type: application/json
pub fn postJson(client: *std.http.Client, url: []const u8, headers: Headers, json: []const u8, buf: []u8) !Response {
    return request(client, .POST, url, headers, json, buf);
}

pub const json_ct = std.http.Header{ .name = "Content-Type", .value = "application/json" };
