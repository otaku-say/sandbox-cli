//! Connect 流式协议编解码（E2B 兼容 envd 使用）。
//!
//! 一条消息 = 5 字节头（1 个 flag 字节 + 4 字节大端长度）+ payload。
//! 请求与响应都用这个封包；响应流的最后一条常是 end-stream（flag=0x02）。
const std = @import("std");

pub const content_type = "application/connect+json";
pub const protocol_version = "1";

pub const end_stream_flag: u8 = 0x02;
pub const compressed_flag: u8 = 0x01;
pub const max_envelope: u32 = 64 * 1024 * 1024;

pub const Envelope = struct {
    flag: u8,
    payload: []const u8,
};

/// 编码一条消息到 out，返回实际占用的字节切片。
pub fn encode(payload: []const u8, out: []u8) ![]const u8 {
    if (out.len < 5 + payload.len) return error.BufferTooSmall;
    out[0] = 0;
    std.mem.writeInt(u32, out[1..5], @intCast(payload.len), .big);
    @memcpy(out[5..][0..payload.len], payload);
    return out[0 .. 5 + payload.len];
}

/// 从 buf 头部解出一条消息。返回消息与**已消费字节数**；数据不足时返回 error.Incomplete。
pub fn decode(buf: []const u8) !struct { env: Envelope, used: usize } {
    if (buf.len < 5) return error.Incomplete;
    const size = std.mem.readInt(u32, buf[1..5], .big);
    if (size > max_envelope) return error.TooLarge;
    if (buf.len < 5 + size) return error.Incomplete;
    return .{
        .env = .{ .flag = buf[0], .payload = buf[5..][0..size] },
        .used = 5 + size,
    };
}

/// 迭代一整段响应体中的所有消息。
pub const Stream = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *Stream) !?Envelope {
        if (self.pos >= self.buf.len) return null;
        const d = decode(self.buf[self.pos..]) catch |e| switch (e) {
            error.Incomplete => return null,
            else => return e,
        };
        self.pos += d.used;
        return d.env;
    }
};
