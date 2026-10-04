//! 手写 WebSocket 客户端（RFC 6455 子集）：握手 + 帧编解码。
//!
//! 用途：aiod-cli 的 pty-ws（附着终端）。
//! 传输层支持：
//!   - **ws://（明文）**：socket 直连（行为与旧版一致）；
//!   - **wss://（TLS 1.3）**：在 socket 之上套本仓库手写的 tls13.zig
//!     （纯 std.crypto，无 fork、无 openssl、无 std.crypto.tls）。
//!
//! 协议要点：
//!   - 握手：GET + Upgrade: websocket + Sec-WebSocket-Key(base64 16 随机字节)
//!     → 101 且 Sec-WebSocket-Accept == base64(sha1(key + GUID))
//!   - 帧：首字节 FIN(1)+opcode(4)；次字节 MASK(1)+len(7)，len>125 用 16/64 位扩展
//!   - **客户端发出的帧必须掩码**（4 字节随机 key，payload 逐字节异或）；服务端帧不掩码
const std = @import("std");
const tls13 = @import("tls13.zig");

pub const OP_TEXT: u8 = 0x1;
pub const OP_BINARY: u8 = 0x2;
pub const OP_CLOSE: u8 = 0x8;
pub const OP_PING: u8 = 0x9;
pub const OP_PONG: u8 = 0xA;

pub const max_frame: usize = 32 << 20;
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ---------------- 传输层：plain socket / TLS ----------------

/// socket fd ⇄ tls13.Stream 适配器（裸 syscall；musl 静态环境可用）。
const FdStream = struct {
    fd: std.os.linux.fd_t,

    fn readFn(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *FdStream = @ptrCast(@alignCast(ctx.?));
        while (true) {
            const rc = std.os.linux.read(self.fd, buf.ptr, buf.len);
            if (std.os.linux.errno(rc) != .SUCCESS) {
                if (std.os.linux.errno(rc) == .INTR) continue;
                return error.ReadFailed;
            }
            return rc; // 0 = EOF
        }
    }

    fn writeFn(ctx: ?*anyopaque, buf: []const u8) anyerror!usize {
        const self: *FdStream = @ptrCast(@alignCast(ctx.?));
        while (true) {
            const rc = std.os.linux.write(self.fd, buf.ptr, buf.len);
            if (std.os.linux.errno(rc) != .SUCCESS) {
                if (std.os.linux.errno(rc) == .INTR) continue;
                return error.WriteFailed;
            }
            return rc;
        }
    }
};

const Transport = union(enum) {
    plain: std.Io.net.Stream,
    tls: *tls13.Conn,

    fn readSome(t: Transport, buf: []u8) !usize {
        switch (t) {
            .plain => |s| {
                const fd = s.socket.handle;
                return std.posix.read(fd, buf);
            },
            .tls => |c| return c.read(buf),
        }
    }

    fn writeAll(t: Transport, data: []const u8) !void {
        switch (t) {
            .plain => |s| return writeAllFd(s.socket.handle, data),
            .tls => |c| return c.write(data),
        }
    }
};

// ---------------- WebSocket ----------------

pub const Frame = struct {
    opcode: u8,
    payload: []const u8,
};

/// dial() 的可选项。
pub const DialOptions = struct {
    /// true: 在 socket 之上套 TLS（wss://）
    tls: bool = false,
    /// 跳过证书主机名校验（仅 tls 生效；对应 -k / --insecure）
    insecure: bool = false,
    /// 显式 SNI / 证书校验名（默认 = host）
    sni: ?[]const u8 = null,
};

pub const Conn = struct {
    io: std.Io,
    socket: std.Io.net.Stream,
    transport: Transport,
    /// tls 模式的 fd 适配器（生命周期与 Conn 相同）
    fds: ?*FdStream = null,
    rbuf: [64 * 1024]u8 = undefined,
    rlen: usize = 0,
    rpos: usize = 0,

    pub fn close(self: *Conn) void {
        switch (self.transport) {
            .tls => |c| {
                c.closeNotify(); // best-effort
                tls13.deinit(c);
            },
            .plain => {},
        }
        self.socket.close(self.io);
        if (self.fds) |f| std.heap.smp_allocator.destroy(f);
    }

    /// 确保缓冲里至少再有 want 字节可读（不足则继续读传输层）。
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
            const n = self.transport.readSome(self.rbuf[self.rlen..]) catch |e| {
                std.debug.print("[diag] read err: {t}\n", .{e});
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

        try self.transport.writeAll(hdr[0..n]);
        try self.transport.writeAll(masked_body);
    }

    pub fn sendText(self: *Conn, text: []const u8) !void {
        try self.sendFrame(OP_TEXT, text);
    }
};

/// 向 socket fd 写全部字节（0.17 的 Stream 没有 write，用裸 syscall）。
fn writeAllFd(fd: std.os.linux.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data.ptr + off, data.len - off);
        if (std.os.linux.errno(rc) != .SUCCESS) {
            if (std.os.linux.errno(rc) == .INTR) continue;
            std.debug.print("[diag] linux.write errno={d} (off={d} len={d})\n", .{ @intFromEnum(std.os.linux.errno(rc)), off, data.len });
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        off += rc;
    }
}

/// IP 字面量优先（与旧版行为一致）；域名走 std.Io 解析（含 netfix 的 hook）。
fn connectTcp(io: std.Io, host: []const u8, port: u16) !std.Io.net.Stream {
    if (std.Io.net.IpAddress.parse(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream }) catch |e| {
            std.debug.print("[ws] TCP 连接 {s}:{d} 失败: {t}\n", .{ host, port, e });
            return e;
        };
    } else |_| {}
    const hn = std.Io.net.HostName.init(host) catch |e| {
        std.debug.print("[ws] 非法主机名 {s}: {t}\n", .{ host, e });
        return e;
    };
    return hn.connect(io, port, .{ .mode = .stream }) catch |e| {
        std.debug.print("[ws] TCP 连接 {s}:{d} 失败: {t}\n", .{ host, port, e });
        return e;
    };
}

/// 建立连接并完成握手。
/// host：IP 字面量或域名；opts.tls=true 时先经 tls13 完成 TLS 握手再发
/// WebSocket 升级请求（即 wss://）。
pub fn dial(
    io: std.Io,
    host: []const u8,
    port: u16,
    path: []const u8,
    host_header: []const u8,
    opts: DialOptions,
) !Conn {
    var stream = try connectTcp(io, host, port);
    errdefer stream.close(io);

    var fds_box: ?*FdStream = null;
    var tls_conn: ?*tls13.Conn = null;
    errdefer {
        if (tls_conn) |t| tls13.deinit(t);
        if (fds_box) |f| std.heap.smp_allocator.destroy(f);
    }

    if (opts.tls) {
        const f = try std.heap.smp_allocator.create(FdStream);
        f.* = .{ .fd = stream.socket.handle };
        fds_box = f;
        tls_conn = tls13.init(.{
            .host = host,
            .port = port,
            .sni = opts.sni,
            .stream = .{ .ctx = f, .readFn = FdStream.readFn, .writeFn = FdStream.writeFn },
            .insecure = opts.insecure,
        }) catch |e| {
            std.debug.print("[ws] TLS 握手失败: {t}\n", .{e});
            return e;
        };
        std.debug.print("[ws] TLS 握手完成（{s}:{d}, insecure={}）\n", .{ host, port, opts.insecure });
    }

    const tport: Transport = if (tls_conn) |t| .{ .tls = t } else .{ .plain = stream };

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

    try tport.writeAll(req);

    // 读响应头到 \r\n\r\n
    var resp: [4096]u8 = undefined;
    var rlen: usize = 0;
    var hdr_end: usize = 0;
    while (rlen < resp.len) {
        const n = try tport.readSome(resp[rlen..]);
        if (n == 0) return error.ConnectionClosed;
        rlen += n;
        if (std.mem.indexOf(u8, resp[0..rlen], "\r\n\r\n")) |he| {
            hdr_end = he + 4;
            break;
        }
    }
    if (hdr_end == 0) return error.HandshakeFailed;
    const head = resp[0..hdr_end];
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

    var conn: Conn = .{
        .io = io,
        .socket = stream,
        .transport = tport,
        .fds = fds_box,
    };
    // 响应头之后可能已带上帧数据，搬进读缓冲
    const extra_len = rlen - hdr_end;
    if (extra_len > 0) {
        @memcpy(conn.rbuf[0..extra_len], resp[hdr_end..rlen]);
        conn.rlen = extra_len;
        conn.rpos = 0;
    }
    return conn;
}
