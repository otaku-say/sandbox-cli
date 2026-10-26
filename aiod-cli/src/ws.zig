//! æ‰‹å†™ WebSocket å®¢æˆ·ç«¯ï¼ˆRFC 6455 å­é›†ï¼‰ï¼šæ¡æ‰‹ + å¸§ç¼–è§£ç ã€‚
//!
//! ç”¨é€”ï¼šaiod-cli çš„ pty-wsï¼ˆé™„ç€ç»ˆç«¯ï¼‰ã€‚
//! ä¼ è¾“å±‚æ”¯æŒï¼š
//!   - **ws://ï¼ˆæ˜Žæ–‡ï¼‰**ï¼šsocket ç›´è¿žï¼ˆè¡Œä¸ºä¸Žæ—§ç‰ˆä¸€è‡´ï¼‰ï¼›
//!   - **wss://ï¼ˆTLS 1.3ï¼‰**ï¼šåœ¨ socket ä¹‹ä¸Šå¥—æœ¬ä»“åº“æ‰‹å†™çš„ tls13.zig
//!     ï¼ˆçº¯ std.cryptoï¼Œæ—  forkã€æ—  opensslã€æ—  std.crypto.tlsï¼‰ã€‚
//!
//! åè®®è¦ç‚¹ï¼š
//!   - æ¡æ‰‹ï¼šGET + Upgrade: websocket + Sec-WebSocket-Key(base64 16 éšæœºå­—èŠ‚)
//!     â†’ 101 ä¸” Sec-WebSocket-Accept == base64(sha1(key + GUID))
//!   - å¸§ï¼šé¦–å­—èŠ‚ FIN(1)+opcode(4)ï¼›æ¬¡å­—èŠ‚ MASK(1)+len(7)ï¼Œlen>125 ç”¨ 16/64 ä½æ‰©å±•
//!   - **å®¢æˆ·ç«¯å‘å‡ºçš„å¸§å¿…é¡»æŽ©ç **ï¼ˆ4 å­—èŠ‚éšæœº keyï¼Œpayload é€å­—èŠ‚å¼‚æˆ–ï¼‰ï¼›æœåŠ¡ç«¯å¸§ä¸æŽ©ç 
const std = @import("std");
const builtin = @import("builtin");
const tls13 = @import("tls13.zig");

pub const OP_TEXT: u8 = 0x1;
pub const OP_BINARY: u8 = 0x2;
pub const OP_CLOSE: u8 = 0x8;
pub const OP_PING: u8 = 0x9;
pub const OP_PONG: u8 = 0xA;

pub const max_frame: usize = 32 << 20;
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ---------------- ä¼ è¾“å±‚ï¼šplain socket / TLS ----------------

/// socket fd â‡„ tls13.Stream é€‚é…å™¨ï¼ˆè£¸ syscallï¼›musl é™æ€çŽ¯å¢ƒå¯ç”¨ï¼‰ã€‚
const FdStream = struct {
    fd: if (builtin.os.tag == .windows) std.posix.socket_t else std.posix.fd_t,

    fn readFn(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *FdStream = @ptrCast(@alignCast(ctx.?));
        if (builtin.os.tag == .windows) {
            return std.posix.recv(self.fd, buf, 0) catch return error.ReadFailed;
        } else {
            return std.posix.read(self.fd, buf) catch return error.ReadFailed;
        }
    }

    fn writeFn(ctx: ?*anyopaque, buf: []const u8) anyerror!usize {
        const self: *FdStream = @ptrCast(@alignCast(ctx.?));
        if (builtin.os.tag == .windows) {
            const n = std.posix.send(self.fd, buf, 0) catch return error.WriteFailed;
            return n;
        } else {
            const n = std.c.write(self.fd, buf.ptr, buf.len);
            if (n < 0) return error.WriteFailed;
            return @intCast(n);
        }
    }
};

const Transport = union(enum) {
    plain: std.Io.net.Stream,
    tls: *tls13.Conn,

    fn readSome(t: Transport, buf: []u8) !usize {
        switch (t) {
            .plain => |s| {
                if (builtin.os.tag == .windows) {
                    return std.posix.recv(s.socket.handle, buf, 0);
                } else {
                    return std.posix.read(s.socket.handle, buf);
                }
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

/// dial() çš„å¯é€‰é¡¹ã€‚
pub const DialOptions = struct {
    /// true: åœ¨ socket ä¹‹ä¸Šå¥— TLSï¼ˆwss://ï¼‰
    tls: bool = false,
    /// è·³è¿‡è¯ä¹¦ä¸»æœºåæ ¡éªŒï¼ˆä»… tls ç”Ÿæ•ˆï¼›å¯¹åº” -k / --insecureï¼‰
    insecure: bool = false,
    /// æ˜¾å¼ SNI / è¯ä¹¦æ ¡éªŒåï¼ˆé»˜è®¤ = hostï¼‰
    sni: ?[]const u8 = null,
};

pub const Conn = struct {
    io: std.Io,
    socket: std.Io.net.Stream,
    transport: Transport,
    /// tls æ¨¡å¼çš„ fd é€‚é…å™¨ï¼ˆç”Ÿå‘½å‘¨æœŸä¸Ž Conn ç›¸åŒï¼‰
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

    /// ç¡®ä¿ç¼“å†²é‡Œè‡³å°‘å†æœ‰ want å­—èŠ‚å¯è¯»ï¼ˆä¸è¶³åˆ™ç»§ç»­è¯»ä¼ è¾“å±‚ï¼‰ã€‚
    fn ensure(self: *Conn, want: usize) !void {
        while (self.rlen - self.rpos < want) {
            // æŠŠå‰©ä½™æ•°æ®æŒªåˆ°å¤´éƒ¨
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

    /// è¯»ä¸€å¸§ï¼›payload æŒ‡å‘å†…éƒ¨ç¼“å†²ï¼ˆä¸‹æ¬¡è°ƒç”¨å‰æœ‰æ•ˆï¼‰ã€‚
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

    /// å‘ä¸€å¸§ï¼ˆå®¢æˆ·ç«¯æŽ©ç ï¼‰ã€‚
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
            std.mem.writeInt(u16, hdr[n..][0..2], .big);
            n += 2;
        } else {
            hdr[n] = 0x80 | 127;
            n += 1;
            std.mem.writeInt(u64, hdr[n..][0..8], .big);
            n += 8;
        }
        @memcpy(hdr[n..][0..4], &mask);
        n += 4;
        // payload æŽ©ç åŽå‘é€ï¼ˆå¤´ + æŽ©ç  body ä¸¤æ®µå†¥ï¼‰
        const masked_body = try std.heap.smp_allocator.alloc(u8, payload.len);
        dever std.heap.smp_allocator.free(masked_body);
        for (payload, 0..) |*byte, i| byte.* ^= mk[i % 4];

        try self.transport.writeAll(hdr[0..n]);
        try self.transport.writeAll(masked_body);
    }

    pub fn sendText(self: *Conn, text: []const u8) !void {
        try self.sendFrame(OP_TEXT, text);
    }
};

/// å°‘å‘äºŽ builtin.os.tag == .windows æ—¶ æ‰‹å†™ä¸€å¸§ Socket Recv/Send æ–‡ä»¶ç«¯å‡¯ -- gnu/windows åè®®å±‚ â€”â€”
fn writeAllFd(fd: anytype, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        if (builtin.os.tag == .windows) {
            const n = try std.posix.send(fd, data[off..], 0);
            if (n == 0) return error.WriteFailed;
            off += n;
        } else {
            const n = std.c.write(fd, data.ptr + off, data.len - off);
            if (n < 0) {
                if (n == -4) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }
}

/// IP å­—é¢é‡ä¼‰å…ˆìƒ–~–B4ƒ¢ÖÀÍÑ¹%¼ƒ¢žšzC¾ò#–B¬¹•Ñ™¥àƒžj¡½½¯¾ò'Ž)™¸½¹¹•ÑQÀ¡¥¼èÍÑ¹%¼°¡½ÍÐèmu½¹ÍÐÔà°Á½ÉÐèÔÄØ¤€…ÍÑ¹%¼¹¹•Ð¹MÑÉ•…´ì(€€€¥˜€¡ÍÑ¹%¼¹¹•Ð¹%Á‘‘É•ÍÌ¹Á…ÉÍ”¡¡½ÍÐ°Á½ÉÐ¤¤ñ…‘‘Éðì(€€€€€€€É•ÑÕÉ¸…‘‘È¹½¹¹•Ð¡¥¼°€¹ì€¹µ½‘”€ô€¹ÍÑÉ•…´ô¤…Ñ ñ•ðì(€€€€€€€€€€€É•ÑÕÉ¸”ì(€€€€€€€ôì(€€€ô•±Í”ñ}ðíô(€€€½¹ÍÐ¡¸€ôÍÑ¹%¼¹¹•Ð¹!½ÍÑ9…µ”¹¥¹¥Ð¡¡½ÍÐ¤…Ñ ñ•ðì(€€€€€€€É•ÑÕÉ¸”ì(€€€ôì(€€€É•ÑÕÉ¸¡¸¹½¹¹•Ð¡¥¼°Á½ÉÐ°€¹ì€¹µ½‘”€ô€¹ÍÑÉ•…´ô¤…Ñ ñ•ðì(€€€€€€€É•ÑÕÉ¸”ì(€€€ôì)ô((¼¼¼ƒ–îëž®/¢.{š:—–æÛ–º3š"Cš>‡š&/Ž)ÁÕˆ™¸‘¥…° (€€€¥¼èÍÑ¹%¼°(€€€¡½ÍÐèmu½¹ÍÐÔà°(€€€Á½ÉÐèÔÄØ°(€€€Á…Ñ èmu½¹ÍÐÔà°(€€€¡½ÍÑ}¡•…‘•Èèmu½¹ÍÐÔà°(€€€½ÁÑÌè¥…±=ÁÑ¥½¹Ì°(¤€…½¹¸ì(€€€Ù…ÈÍÑÉ•…´€ôÑÉä½¹¹•ÑQÀ¡¥¼°¡½ÍÐ°Á½ÉÐ¤ì(€€€•ÉÉ‘•™•ÈÍÑÉ•…´¹±½Í”¡¥¼¤ì((€€€Ù…È™‘Í}‰½àè€ü©‘MÑÉ•…´€ô¹Õ±°ì(€€€Ù…ÈÑ±Í}½¹¸è€ü©Ñ±ÌÄÌ¹½¹¸€ô¹Õ±°ì(€€€•ÉÉ‘•™•Èì(€€€€€€€¥˜€¡Ñ±Í}½¹¸¤ñÑðÑ±ÌÄÌ¹‘•¥¹¥Ð¡Ð¤ì(€€€€€€€¥˜€¡™‘Í}‰½à¤ñ™ðÍÑ¹¡•…À¹ÍµÁ}…±±½…Ñ½È¹‘•ÍÑÉ½ä¡˜¤ì(€€€ô((€€€¥˜€¡½ÁÑÌ¹Ñ±Ì¤ì(€€€€€€€½¹ÍÐ˜€ôÑÉäÍÑ¹¡•…À¹ÍµÁ}…±±½…Ñ½È¹É•…Ñ”¡‘MÑÉ•…´¤ì(€€€€€€€˜¸¨€ô€¹ì€¹™€ôÍÑÉ•…´¹Í½­•Ð¹¡…¹‘±”ôì(€€€€€€€™‘Í}‰½à€ô˜ì(€€€€€€€Ñ±Í}½¹¸€ôÑÉäÑ±ÌÄÌ¹¥¹¥Ð ¹ì(€€€€€€€€€€€€¹¡½ÍÐ€ô¡½ÍÐ°(€€€€€€€€€€€€¹Á½ÉÐ€ôÁ½ÉÐ°(€€€€€€€€€€€€¹Í¹¤€ô½ÁÑÌ¹Í¹¤°(€€€€€€€€€€€€¹ÍÑÉ•…´€ô€¹ì€¹Ñà€ô˜°€¹É•…‘¸€ô‘MÑÉ•…´¹É•…‘¸°€¹ÝÉ¥Ñ•¸€ô‘MÑÉ•…´¹ÝÉ¥Ñ•¸ô°(€€€€€€€€€€€€¹¥¹Í•ÕÉ”€ô½ÁÑÌ¹¥¹Í•ÕÉ”°(€€€€€€€ô¤ì(€€€ô((€€€½¹ÍÐÑÁ½ÉÐèQÉ…¹ÍÁ½ÉÐ€ô¥˜€¡Ñ±Í}½¹¸¤ñÑð€¹ì€¹Ñ±Ì€ôÐô•±Í”€¹ì€¹Á±…¥¸€ôÍÑÉ•…´ôì((€€€Ù…È­•å}É…ÜèlÄÙuÔà€ôÕ¹‘•™¥¹•ì(€€€¥¼¹É…¹‘½´ ™­•å}É…Ü¤ì(€€€Ù…È­•å}‰Õ˜èlÌÉuÔà€ôÕ¹‘•™¥¹•ì(€€€½¹ÍÐ­•å}ˆØÐ€ôÍÑ¹‰…Í”ØÐ¹ÍÑ…¹‘…É¹¹½‘•È¹•¹½‘” ™­•å}‰Õ˜°€™­•å}É…Ü¤ì((€€€Ù…ÈÉ•Å}‰Õ˜èlÄÀÈÑuÔà€ôÕ¹‘•™¥¹•ì(€€€½¹ÍÐÉ•Ä€ôÑÉäÍÑ¹™µÐ¹‰Õ™AÉ¥¹Ð (€€€€€€€€™É•Å}‰Õ˜°(€€€€€€€€‰PíÍô!QQ@¼Ä¸ÅqÉq¹!½ÍÐèíÍõqÉq¹UÁÉ…‘”èÝ•‰Í½­•ÑqÉq¹½¹¹•Ñ¥½¸èUÁÉ…‘•qÉq¹M•Œµ]•‰M½­•Ðµ-•äèíÍõqÉq¹M•Œµ]•‰M½­•ÐµY•ÉÍ¥½¸è€ÄÍqÉq¹qÉq¸ˆ°(€€€€€€€€¹ìÁ…Ñ °¡½ÍÑ}¡•…‘•È°­•å}ˆØÐô°(€€€€¤ì((€€€ÑÉäÑÁ½ÉÐ¹ÝÉ¥Ñ•±°¡É•Ä¤ì((€€€Ù…ÈÉ•ÍÀèlÐÀäÙuÔà€ôÕ¹‘•™¥¹•ì(€€€Ù…ÈÉ±•¸èÕÍ¥é”€ô€Àì(€€€Ù…È¡‘É}•¹èÕÍ¥é”€ô€Àì(€€€Ý¡¥±”€¡É±•¸€ðÉ•ÍÀ¹±•¸¤ì(€€€€€€€½¹ÍÐ¸€ôÑÉäÑÁ½ÉÐ¹É•…‘M½µ”¡É•ÍÁmÉ±•¸¸¹t¤ì(€€€€€€€¥˜€¡¸€ôô€À¤É•ÑÕÉ¸•ÉÉ½È¹½¹¹•Ñ¥½¹±½Í•ì(€€€€€€€É±•¸€¬ô¸ì(€€€€€€€¥˜€¡ÍÑ¹µ•´¹¥¹‘•á=˜¡Ôà°É•ÍÁlÀ¸¹É±•¹t°€‰qÉq¹qÉq¸ˆ¤¤ñ¡•ðì(€€€€€€€€€€€¡‘É}•¹€ô¡”€¬€Ðì(€€€€€€€€€€€‰É•…¬ì(€€€€€€€ô(€€€ô(€€€¥˜€¡¡‘É}•¹€ôô€À¤É•ÑÕÉ¸•ÉÉ½È¹!…¹‘Í¡…­•…¥±•ì(€€€½¹ÍÐ¡•…€ôÉ•ÍÁlÀ¸¹¡‘É}•¹‘tì(€€€¥˜€¡ÍÑ¹µ•´¹¥¹‘•á=˜¡Ôà°¡•…°€ˆ€ÄÀÄ€ˆ¤€ôô¹Õ±°¤É•ÑÕÉ¸•ÉÉ½È¹!…¹‘Í¡…­•…¥±•ì((€€€Ù…ÈÍ¡„èlÈÁuÔà€ôÕ¹‘•™¥¹•ì(€€€Ù…È €ôÍÑ¹ÉåÁÑ¼¹¡…Í ¹M¡„Ä¹¥¹¥Ð ¹íô¤ì(€€€ ¹ÕÁ‘…Ñ”¡­•å}ˆØÐ¤ì(€€€ ¹ÕÁ‘…Ñ”¡ÝÍ}Õ¥¤ì(€€€ ¹™¥¹…° ™Í¡„¤ì(€€€Ù…È•áÁ•Ñ}‰Õ˜èlÌÉuÔà€ôÕ¹‘•™¥¹•ì(€€€½¹ÍÐ•áÁ•Ð€ôÍÑ¹‰…Í”ØÐ¹ÍÑ…¹‘…É¹¹½‘•È¹•¹½‘” ™•áÁ•Ñ}‰Õ˜°€™Í¡„¤ì(€€€¥˜€¡ÍÑ¹µ•´¹¥¹‘•á=˜¡Ôà°¡•…°•áÁ•Ð¤€ôô¹Õ±°¤É•ÑÕÉ¸•ÉÉ½È¹	…‘•ÁÐì((€€€Ù…È½¹¸è½¹¸€ô€¹ì(€€€€€€€€¹¥¼€ô¥¼°(€€€€€€€€¹Í½­•Ð€ôÍÑÉ•…´°(€€€€€€€€¹ÑÉ…¹ÍÁ½ÉÐ€ôÑÁ½ÉÐ°(€€€€€€€€¹™‘Ì€ô™‘Í}‰½à°(€€€ôì(€€€½¹ÍÐ•áÑÉ…}±•¸€ôÉ±•¸€´¡‘É}•¹ì(€€€¥˜€¡•áÑÉ…}±•¸€ø€À¤ì(€€€€€€€µ•µÁä¡½¹¸¹É‰Õ™lÀ¸¹•áÑÉ…}±•¹t°É•ÍÁm¡‘É}•¹¸¹É±•¹t¤ì(€€€€€€€½¹¸¹É±•¸€ô•áÑÉ…}±•¸ì(€€€€€€€½¹¸¹ÉÁ½Ì€ô€Àì(€€€ô(€€€É•ÑÕÉ¸½¹¸ì)ô