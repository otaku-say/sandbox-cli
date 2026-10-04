//! 手写 WebSocket 客户端（RFC 6455 子集）：握手 + 帧编解码。
//!
//! 用途：aio-cli 的 pty-ws（附着终端）。
//! 当前版本支持 **ws://（明文）**；wss:// 需要 TLS，见文件末尾说明。
//!
//! 协议要点：
//!   - 握手：GET + Upgrade: websocket + Sec-WebSocket-Key(base64 16 随机字节)
//!     → 101 且 Sec-WebSocket-Accept == base64(sha1(key + GUID))
//!   - 帧：首字节 FIN(1)+opcode(4)；次字节 MASK(1)+len(7)，len>125 用 16/64 位扩展
//!   - **客户端发出的帧必须掩码**（4 字节随机 key，payload 逐字节异或）；服务端帧不掩码
const std = @import("std");

pub const OP_TEXT: u8 = 0x1;
pub const OP_BINARY: u8 = 0x2;
pub const OP_CLOSE: u8 = 0x8;
pub const OP_PING: u8 = 0x9;
pub const OP_PONG: u8 = 0xA;

pub const max_frame: usize = 32 << 20;
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Frame = struct {
    opcode: u8,
    payload: []const u8,
};

pub const Conn = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    rbuf: [64 * 1024]u8 = undefined,
    rlen: usize = 0,
    rpos: usize = 0,

    pub fn close(self: *Conn) void {
        self.stream.close(self.io);
    }

    /// 确保缓冲里至少再有 want 字节可读（不足则继续读 socket）。
    fn ensure(self: *Conn, want: usize) !void {
        while (self.rlen - self.rpos < want) {
            // 把剩余数据挪到头部
            if (self.rpos > 0) {
                const rem = self.rlen - self.rpos;
                std.mem.copyForwards(u8, self.rbuf[0..rem], self.rbuf[self.rpos..self.rlen]);
                self.rlen = rem;
                self.rpos = 0;
            }
            if (self.rlen >= self.rbuf.len) return error.FrameTooLarge;
            const fd = self.stream.socket.handle;
            const n = std.posix.read(fd, self.rbuf[self.rlen..]) catch |e| {
                std.debug.print("[diag] posix.read err: {t}\n", .{e});
                return e;
            };
            if (n == 0) return error.ConnectionClosed;
            self.rlen += n;
        }
    }

    fn take(self: *Conn, n: usize) []const u8 {
        const s = self.rbuf[self.rpos .. self.rpos + n];
        self.rpos += n;
        return s;
    }

    /// 读一帧；payload 指向内部缓冲（下次调用前有效）。
    pub fn readFrame(self: *Conn) !Frame {
        try self.ensure(2);
        const b0 = self.rbuf[self.rpos];
        const b1 = self.rbuf[self.rpos + 1];
        const opcode: u8 = b0 & 0x0F;
        const masked = (b1 & 0x80) != 0;
        var len: usize = b1 & 0x7F;
        var hdr: usize = 2;
        if (len == 126) {
            try self.ensure(4);
            len = std.mem.readInt(u16, self.rbuf[self.rpos + 2 ..][0..2], .big);
            hdr = 4;
        } else if (len == 127) {
            try self.ensure(10);
            len = @intCast(std.mem.readInt(u64, self.rbuf[self.rpos + 2 ..][0..8], .big));
            hdr = 10;
        }
        if (len > max_frame) return error.FrameTooLarge;
        const mask_len: usize = if (masked) 4 else 0;
        try self.ensure(hdr + mask_len + len);
        const mask_off = self.rpos + hdr;
        const payload = self.rbuf[self.rpos + hdr + mask_len .. self.rpos + hdr + mask_len + len];
        if (masked) {
            const mk = self.rbuf[mask_off .. mask_off + 4];
            for (payload, 0..) |*byte, i| byte.* ^= mk[i % 4];
        }
        self.rpos += hdr + mask_len + len;
        return .{ .opcode = opcode, .payload = payload };
    }

    /// 发一帧（客户端掩码）。
    pub fn sendFrame(self: *Conn, opcode: u8, payload: []const u8) !void {
        var hdr: [14]u8 = undefined;
        var n: usize = 0;
        hdr[n] = 0x80 | opcode; // FIN=1
        n += 1;
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        if (payload.len < 126) {
            hdr[n] = 0x80 | @as(u8, @intCast(payload.len));
            n += 1;
        } else if (payload.len <= 0xFFFF) {
            hdr[n] = 0x80 | 126;
            n += 1;
            std.mem.writeInt(u16, hdr[n..][0..2], @intCast(payload.len), .big);
            n += 2;
        } else {
            hdr[n] = 0x80 | 127;
            n += 1;
            std.mem.writeInt(u64, hdr[n..][0..8], @intCast(payload.len), .big);
            n += 8;
        }
        @memcpy(hdr[n..][0..4], &mask);
        n += 4;

        // payload 掩码后发送（头 + 掩码 body 两段写）
        const masked_body = try std.heap.smp_allocator.alloc(u8, payload.len);
        defer std.heap.smp_allocator.free(masked_body);
        for (payload, 0..) |byte, i| masked_body[i] = byte ^ mask[i % 4];

        try writeAll(self.io, self.stream, hdr[0..n]);
        try writeAll(self.io, self.stream, masked_body);
    }

    pub fn sendText(self: *Conn, text: []const u8) !void {
        try self.sendFrame(OP_TEXT, text);
    }
};

/// 向 socket 写全部字节（0.17 的 Stream 没有 write，用嵌套 Writer）。
fn writeAll(io: std.Io, stream: std.Io.net.Stream, data: []const u8) !void {
    _ = io;
    // 直接走 posix：0.17.0 的 std.Io.net.Stream.read 实现有语法 bug
    // （对 struct 做 tuple 解构），凡是经过它的高层 API 都无法编译。
    const fd = stream.socket.handle;
    var off: usize = 0;
    while (off < data.len) {
        // 0.17.0 的 std.posix 没有 write（只有 read），直接走系统调用
        const rc = std.os.linux.write(fd, data.ptr + off, data.len - off);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) {
            std.debug.print("[diag] linux.write rc={d} (off={d} len={d})\n", .{ signed, off, data.len });
            return error.WriteFailed;
        }
        off += @intCast(signed);
    }
}

/// 建立连接并完成握手。host 必须是 IP 字面量（域名请用 /etc/hosts 解析后传入）。
pub fn dial(io: std.Io, host: []const u8, port: u16, path: []const u8, host_header: []const u8) !Conn {
    const addr = try std.Io.net.IpAddress.parse(host, port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);

    // 握手 key
    var key_raw: [16]u8 = undefined;
    io.random(&key_raw);
    var key_buf: [32]u8 = undefined;
    const key_b64 = std.base64.standard.Encoder.encode(&key_buf, &key_raw);

    var req_buf: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(
        &req_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{ path, host_header, key_b64 },
    );

    try writeAll(io, stream, req);

    // 读响应头到 \r\n\r\n
    var resp: [4096]u8 = undefined;
    var rlen: usize = 0;
    var extra_len: usize = 0;
    while (rlen < resp.len) {
        const fd = stream.socket.handle;
        const n = try std.posix.read(fd, resp[rlen..]);
        if (n == 0) return error.ConnectionClosed;
        rlen += n;
        if (std.mem.indexOf(u8, resp[0..rlen], "\r\n\r\n")) |hdr_end| {
            extra_len = rlen - (hdr_end + 4);
            break;
        }
    }
    const head = resp[0..rlen];
    if (std.mem.indexOf(u8, head, " 101 ") == null) return error.HandshakeFailed;

    // 校验 Sec-WebSocket-Accept
    var sha: [20]u8 = undefined;
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key_b64);
    h.update(ws_guid);
    h.final(&sha);
    var expect_buf: [32]u8 = undefined;
    const expect = std.base64.standard.Encoder.encode(&expect_buf, &sha);
    if (std.mem.indexOf(u8, head, expect) == null) return error.BadAccept;

    var conn: Conn = .{ .stream = stream, .io = io };
    // 响应头之后可能已带上帧数据，搬进读缓冲
    if (extra_len > 0) {
        const hdr_end = std.mem.indexOf(u8, head, "\r\n\r\n").? + 4;
        @memcpy(conn.rbuf[0..extra_len], resp[hdr_end..rlen]);
        conn.rlen = extra_len;
        conn.rpos = 0;
    }
    return conn;
}
