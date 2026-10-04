//! Minimal TLS 1.3 client — pure std.crypto, no fork, no std.crypto.tls.
//! Zig 0.17.0. 从 docs/wss/tls13.zig PoC（已跑通真实 Cloudflare）集成而来；
//! I/O 与 socket 解耦：传输层由调用方通过 `Stream`（readFn/writeFn）注入，
//! 可接 socket fd、也可接测试桩。
//!
//! 对外 API：
//!   const c = try tls13.init(.{ .host, .port, .sni, .stream, .insecure });
//!   try c.write(app_data);   // 明文层写（内部按 TLS 记录层分帧）
//!   const n = try c.read(buf); // 明文层读（内部拆帧）；0 = 对端关闭
//!   c.closeNotify();         // 发送 close_notify（best-effort）
//!   tls13.deinit(c);
//!
//! Supports: TLS 1.3 only, X25519 key_share only, TLS_AES_128_GCM_SHA256 +
//! TLS_CHACHA20_POLY1305_SHA256, SNI, ALPN http/1.1, CertificateVerify
//! signature verification (ecdsa_secp256r1_sha256 / rsa_pss_rsae_* /
//! rsa_pkcs1_* / ed25519), X.509 hostname verification（含 IP SAN）。
//!
//! 调试输出默认关闭；`AIO_TLS_DEBUG=1` 打开。证书：默认做主机名校验 +
//! CertificateVerify 验签；完整链验证暂未实现（失败时给出明确错误）。
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const Sha256 = std.crypto.hash.sha2.Sha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const X25519 = std.crypto.dh.X25519;
const tlsmod = std.crypto.tls;
const Certificate = std.crypto.Certificate;

// Reused straight out of the Zig standard library (lib/std/crypto/tls.zig).
const hkdfExpandLabel = tlsmod.hkdfExpandLabel;
const emptyHash = tlsmod.emptyHash;

const REC_MAX = 16 * 1024 + 256;
const CERT_MAX = 96 * 1024;

const RecType = struct {
    const change_cipher_spec: u8 = 0x14;
    const alert: u8 = 0x15;
    const handshake: u8 = 0x16;
    const application_data: u8 = 0x17;
};
const Hs = struct {
    const client_hello: u8 = 1;
    const server_hello: u8 = 2;
    const new_session_ticket: u8 = 4;
    const encrypted_extensions: u8 = 8;
    const certificate: u8 = 11;
    const certificate_verify: u8 = 15;
    const finished: u8 = 20;
};

const Suite = enum { none, aes_128_gcm_sha256, chacha20_poly1305_sha256 };

fn suiteName(s: Suite) []const u8 {
    return switch (s) {
        .none => "none",
        .aes_128_gcm_sha256 => "TLS_AES_128_GCM_SHA256",
        .chacha20_poly1305_sha256 => "TLS_CHACHA20_POLY1305_SHA256",
    };
}

// ============================== 调试开关 ==============================

/// 调试输出总开关（默认关闭；AIO_TLS_DEBUG=1 / true / yes 打开）。
pub var debug: bool = false;

fn envDebug() bool {
    if (std.c.getenv("AIO_TLS_DEBUG")) |p| {
        const v = std.mem.span(p);
        if (std.mem.eql(u8, v, "1")) return true;
        if (std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes")) return true;
    }
    return false;
}

/// 仅在调试开关打开时打印。
fn dg(comptime fmt: []const u8, args: anytype) void {
    if (debug) std.debug.print(fmt, args);
}

// ============================== 传输抽象 ==============================

/// I/O 抽象：由调用方提供读写实现（socket fd / 测试桩 / 任意管道）。
/// 约定：read 返回 0 表示 EOF；write 返回实际写入字节数（允许部分写）。
pub const Stream = struct {
    ctx: ?*anyopaque = null,
    readFn: *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize,
    writeFn: *const fn (ctx: ?*anyopaque, buf: []const u8) anyerror!usize,

    pub fn read(self: Stream, buf: []u8) anyerror!usize {
        return self.readFn(self.ctx, buf);
    }

    pub fn write(self: Stream, buf: []const u8) anyerror!usize {
        return self.writeFn(self.ctx, buf);
    }

    /// 写全（自动重试部分写）。
    pub fn writeAll(self: Stream, buf: []const u8) anyerror!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.write(buf[off..]);
            if (n == 0) return error.WriteFailed;
            off += n;
        }
    }
};

// ============================== raw syscalls ==============================

fn isErr(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

// ============================== AEAD plumbing ==============================

const TrafficKeys = struct {
    suite: Suite = .none,
    key: [32]u8 = @splat(0),
    iv: [12]u8 = @splat(0),
    seq: u64 = 0,
    debug: bool = false,
};

fn keyLenFor(s: Suite) usize {
    return switch (s) {
        .aes_128_gcm_sha256 => 16,
        .chacha20_poly1305_sha256 => 32,
        .none => 0,
    };
}


/// 手动 AES-128-CTR（GCM 的数据通路），用于与 std 的 GCM 解密结果对拍
fn manualCtr(out: []u8, in: []const u8, key: [16]u8, nonce: [12]u8) void {
    const aes = std.crypto.core.aes.Aes128.initEnc(key);
    var ctr: [16]u8 = undefined;
    ctr[0..12].* = nonce;
    var blk: [16]u8 = undefined;
    var i: usize = 0;
    var c: u32 = 2;
    while (i < in.len) {
        std.mem.writeInt(u32, ctr[12..16], c, .big);
        aes.encrypt(&blk, &ctr);
        const n = @min(16, in.len - i);
        for (0..n) |k| out[i + k] = in[i + k] ^ blk[k];
        i += n;
        c += 1;
    }
}

fn sealWith(tk: *TrafficKeys, ct: []u8, tag: *[16]u8, m: []const u8, ad: []const u8) void {
    var nonce = tk.iv;
    var s = std.mem.readInt(u64, nonce[4..12], .big);
    s ^= tk.seq;
    std.mem.writeInt(u64, nonce[4..12], s, .big);
    switch (tk.suite) {
        .aes_128_gcm_sha256 => std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(ct, tag, m, ad, nonce, tk.key[0..16].*),
        .chacha20_poly1305_sha256 => std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(ct, tag, m, ad, nonce, tk.key[0..32].*),
        .none => unreachable,
    }
    tk.seq += 1;
}

fn openWith(tk: *TrafficKeys, m: []u8, c: []const u8, tag: [16]u8, ad: []const u8) !void {
    var nonce = tk.iv;
    var s = std.mem.readInt(u64, nonce[4..12], .big);
    s ^= tk.seq;
    std.mem.writeInt(u64, nonce[4..12], s, .big);
    if (tk.debug) {
        std.debug.print("[dbg] seq={d} suite={s} key=", .{ tk.seq, @tagName(tk.suite) });
        hex(tk.key[0..8]);
        std.debug.print(" iv=", .{});
        hex(tk.iv[0..]);
        std.debug.print(" nonce=", .{});
        hex(nonce[0..]);
        std.debug.print(" AAD=", .{});
        hex(ad);
        std.debug.print(" ct[0..8]=", .{});
        hex(c[0..@min(8, c.len)]);
        std.debug.print("\n", .{});
    }
    switch (tk.suite) {
        .aes_128_gcm_sha256 => try std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(m, c, tag, ad, nonce, tk.key[0..16].*),
        .chacha20_poly1305_sha256 => try std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(m, c, tag, ad, nonce, tk.key[0..32].*),
        .none => unreachable,
    }
    if (tk.debug and tk.seq == 0 and tk.suite == .aes_128_gcm_sha256) {
        var man: [REC_MAX]u8 = undefined;
        manualCtr(man[0..c.len], c, tk.key[0..16].*, nonce);
        std.debug.print("[dbg] std_inner=", .{});
        hex(m[0..@min(16, m.len)]);
        std.debug.print("\n[dbg] manual  =", .{});
        hex(man[0..@min(16, c.len)]);
        std.debug.print("\n", .{});
    }
    tk.seq += 1;
}

// ============================== connection ==============================

pub const Conn = struct {
    /// 传输层（socket / 测试桩由调用方注入）
    stream: Stream,
    rbuf: [REC_MAX]u8 = undefined,
    rpos: usize = 0,
    rend: usize = 0,
    // handshake message reassembly
    hs: [CERT_MAX]u8 = undefined,
    hsp: usize = 0,
    hsl: usize = 0,
    transcript: [CERT_MAX]u8 = undefined,
    tlen: usize = 0,
    rk: TrafficKeys = .{},
    wk: TrafficKeys = .{},
    // 明文层读缓冲（拆帧后的应用数据暂存）
    rd: [REC_MAX]u8 = undefined,
    rd_len: usize = 0,
    rd_pos: usize = 0,

    fn fill(c: *Conn, n: usize) !void {
        while (c.rend - c.rpos < n) {
            if (c.rpos > 0 and c.rend == c.rbuf.len) {
                mem.copyForwards(u8, c.rbuf[0 .. c.rend - c.rpos], c.rbuf[c.rpos..c.rend]);
                c.rend -= c.rpos;
                c.rpos = 0;
            }
            if (c.rend == c.rbuf.len) return error.RecordTooLarge;
            const nread = try c.stream.read(c.rbuf[c.rend..]);
            if (nread == 0) return error.UnexpectedEof;
            c.rend += nread;
        }
    }

    /// Reads one record. Returns content type; payload slice points into rbuf
    /// (plaintext record) or into `inner` (encrypted record, caller must copy).
    fn readRecordRaw(c: *Conn) !struct { t: u8, len: usize } {
        try c.fill(5);
        const t = c.rbuf[c.rpos];
        const len = std.mem.readInt(u16, c.rbuf[c.rpos + 3 ..][0..2], .big);
        if (len + 5 > c.rbuf.len) return error.RecordTooLarge;
        try c.fill(5 + len);
        c.rpos += 5;
        return .{ .t = t, .len = len };
    }

    /// TLSInnerPlaintext: [content_type][zeros...][content][zeros]
    /// Handshake records (NewSessionTicket etc.) are consumed and skipped.
    fn readAppRecord(c: *Conn, out: []u8) !usize {
        while (true) {
            const rec = try c.readRecordRaw();
            const ct = rec.t;
            if (ct == RecType.change_cipher_spec) {
                c.rpos += rec.len; // 兼容性 CCS：服务端在 ServerHello 之后明文发一条，丢弃
                dg("[tls] <- change_cipher_spec（兼容模式，忽略）\n", .{});
                continue;
            }
            if (ct != RecType.application_data and ct != RecType.handshake and ct != RecType.alert)
                return error.UnexpectedRecordType;
            if (rec.len < 16 + 1) return error.ShortRecord;
            const enc = c.rbuf[c.rpos .. c.rpos + rec.len];
            var inner: [REC_MAX]u8 = undefined;
            var tag: [16]u8 = undefined;
            @memcpy(tag[0..], enc[rec.len - 16 ..]);
            const body = enc[0 .. rec.len - 16];
            try openWith(&c.rk, inner[0..body.len], body, tag, c.rbuf[c.rpos - 5 ..][0..5]);
            c.rpos += rec.len;
            // 不剥尾部零：TLS1.3 内层明文末尾的 0x00 是合法内容（如 extensions 长度为 0），
            // 多余的 padding 由上层按握手消息自带的长度字段自然忽略。
            if (body.len < 2) return error.ShortRecord;
            // 内层明文 content_type：标准布局是 [type][content]；实测服务端会给 [content][type]，两种都兼容
            var real_type: u8 = undefined;
            var pay: usize = 1;
            if (inner[0] == RecType.handshake or inner[0] == RecType.application_data or inner[0] == RecType.alert) {
                real_type = inner[0];
            } else if (inner[body.len - 1] == RecType.handshake or inner[body.len - 1] == RecType.application_data or inner[body.len - 1] == RecType.alert) {
                real_type = inner[body.len - 1];
                pay = 0;
            } else return error.BadInnerType;
            const payload_len = body.len - 1;
            if (debug) {
                std.debug.print("[dbg] inner=", .{});
                hex(inner[0..@min(inner.len, body.len + 6)]);
                std.debug.print(" bodylen={d}\n", .{body.len});
            }
            if (payload_len > out.len) return error.RecordTooLarge;
            @memcpy(out[0..payload_len], inner[pay..][0..payload_len]);
            if (real_type == RecType.alert) {
                if (payload_len >= 2 and out[1] == 0) return error.PeerCloseNotify;
                std.debug.print("[tls] 服务端 alert：desc={d}（fatal）\n", .{ if (payload_len >= 2) out[1] else 0 });
                return error.RemoteAlert;
            }
            if (real_type == RecType.handshake and (out[0] == 4 or out[0] == 24)) {
                dg("[tls] （跳过 post-handshake 消息 type={d}, {d} B）\n", .{ out[0], payload_len });
                continue;
            }
            return payload_len;
        }
    }

    fn writeRecord(c: *Conn, content_type: u8, payload: []const u8) !void {
        if (c.wk.suite == .none) {
            var hdr: [5]u8 = undefined;
            hdr[0] = content_type;
            hdr[1] = 0x03;
            hdr[2] = 0x01; // 初始 ClientHello 的 legacy_record_version 必须是 0x0301
            std.mem.writeInt(u16, hdr[3..5], @intCast(payload.len), .big);
            try c.stream.writeAll(&hdr);
            try c.stream.writeAll(payload);
            return;
        }
        const inner_len = 1 + payload.len; // TLSInnerPlaintext = [content_type][content][padding]
        const total = inner_len + 16; // 记录载荷 = 内层明文 + AEAD tag
        if (total > 16384) return error.RecordTooLarge;
        var out: [REC_MAX]u8 = undefined;
        @memset(out[0..], 0);
        out[0] = 0x17;
        out[1] = 0x03;
        out[2] = 0x03;
        std.mem.writeInt(u16, out[3..5], @intCast(total), .big);
        @memcpy(out[5..][0..payload.len], payload); // 实测：服务端内层布局是 [内容][content_type]
        out[5 + payload.len] = content_type;
        var tag: [16]u8 = undefined;
        sealWith(&c.wk, out[5..][0..inner_len], &tag, out[5..][0..inner_len], out[0..5]);
        @memcpy(out[5 + inner_len ..][0..16], &tag);
        if (c.wk.debug and total < 200) {
            std.debug.print("[dbg] seq={d} ", .{c.wk.seq});
            hex(out[0 .. 5 + total]);
            std.debug.print("\n", .{});
        }
        try c.stream.writeAll(out[0 .. 5 + total]);
    }

    fn transcriptAppend(c: *Conn, b: []const u8) void {
        if (c.tlen + b.len > c.transcript.len) return;
        @memcpy(c.transcript[c.tlen..][0..b.len], b);
        c.tlen += b.len;
    }
    fn transcriptHash(c: *const Conn) [32]u8 {
        var h: [32]u8 = undefined;
        Sha256.hash(c.transcript[0..c.tlen], &h, .{});
        return h;
    }

    /// 写明文数据（自动按 TLS 记录层分帧；单记录明文上限 16367 B）。
    pub fn write(c: *Conn, data: []const u8) !void {
        const max_payload = 16384 - 1 - 16; // inner=type(1)+payload，记录载荷再加 AEAD tag(16)
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(data.len - off, max_payload);
            try c.writeRecord(RecType.application_data, data[off..][0..n]);
            off += n;
        }
    }

    /// 读明文数据（内部自动做记录层拆帧）。返回 0 = 对端关闭（close_notify / EOF）。
    pub fn read(c: *Conn, buf: []u8) !usize {
        if (c.rd_pos >= c.rd_len) {
            c.rd_pos = 0;
            c.rd_len = 0;
            const n = c.readAppRecord(c.rd[0..]) catch |e| switch (e) {
                error.PeerCloseNotify => return 0,
                else => return e,
            };
            if (n == 0) return 0;
            c.rd_len = n;
        }
        const n = @min(buf.len, c.rd_len - c.rd_pos);
        @memcpy(buf[0..n], c.rd[c.rd_pos..][0..n]);
        c.rd_pos += n;
        return n;
    }

    /// 发送 TLS close_notify（best-effort，失败忽略）。
    pub fn closeNotify(c: *Conn) void {
        if (c.wk.suite == .none) return;
        c.writeRecord(RecType.alert, &[_]u8{ 1, 0 }) catch {};
    }
};

// ============================== key schedule ==============================

const Keys4 = struct { key: [32]u8, iv: [12]u8 };

fn finishedVerify(traffic_secret: [32]u8, th: [32]u8) [32]u8 {
    const fk = hkdfExpandLabel(HkdfSha256, traffic_secret, "finished", "", 32);
    var out: [32]u8 = undefined;
    HmacSha256.create(&out, &th, &fk);
    return out;
}

fn hex(b: []const u8) void {
    const digits = "0123456789abcdef";
    for (b) |x| {
        std.debug.print("{c}{c}", .{ digits[x >> 4], digits[x & 0xf] });
    }
}

// ============================== ClientHello ==============================

fn randBytes(b: []u8) !void {
    const rc = linux.getrandom(b.ptr, b.len, 0);
    if (isErr(rc) or rc != b.len) {
        std.debug.print("[crypto] getrandom failed errno={d}\n", .{@intFromEnum(linux.errno(rc))});
        return error.NoEntropy;
    }
}

const SIG_SCHEMES = [_]u16{
    0x0403, // ecdsa_secp256r1_sha256
    0x0503, // ecdsa_secp384r1_sha384
    0x0603, // ecdsa_secp521r1_sha512
    0x0804, // rsa_pss_rsae_sha256
    0x0805, // rsa_pss_rsae_sha384
    0x0806, // rsa_pss_rsae_sha512
    0x0401, // rsa_pkcs1_sha256
    0x0501, // rsa_pkcs1_sha384
    0x0601, // rsa_pkcs1_sha512
    0x0807, // ed25519
    0x0809, // rsa_pss_pss_sha256
};

fn buildClientHello(out: []u8, sni: ?[]const u8, kp: *const X25519.KeyPair) ![]const u8 {
    var i: usize = 0;
    out[i] = Hs.client_hello;
    i += 1;
    const len_pos = i;
    i += 3;
    const body = i;
    std.mem.writeInt(u16, out[i..][0..2], 0x0303, .big);
    i += 2; // legacy_version
    var rnd: [32]u8 = undefined;
    try randBytes(&rnd);
    @memcpy(out[i..][0..32], &rnd);
    i += 32;
    out[i] = 0;
    i += 1; // legacy_session_id
    std.mem.writeInt(u16, out[i..][0..2], 4, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 0x1301, .big); // TLS_AES_128_GCM_SHA256
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 0x1303, .big); // TLS_CHACHA20_POLY1305_SHA256
    i += 2;
    out[i] = 1;
    i += 1; // compression_methods
    out[i] = 0;
    i += 1;
    const ext_len_pos = i;
    i += 2;

    // server_name (0) —— 仅当提供了 DNS 名（IP 字面量不发 SNI，RFC 6066）
    if (sni) |name| {
        std.mem.writeInt(u16, out[i..][0..2], 0, .big);
        i += 2;
        std.mem.writeInt(u16, out[i..][0..2], @intCast(name.len + 5), .big);
        i += 2;
        std.mem.writeInt(u16, out[i..][0..2], @intCast(name.len + 3), .big);
        i += 2;
        out[i] = 0;
        i += 1;
        std.mem.writeInt(u16, out[i..][0..2], @intCast(name.len), .big);
        i += 2;
        @memcpy(out[i..][0..name.len], name);
        i += name.len;
    }

    // supported_groups (10)
    std.mem.writeInt(u16, out[i..][0..2], 10, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 4, .big); // ext_data len = 2 + 2
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 2, .big); // NamedGroup vector 长度
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 0x001d, .big); // x25519
    i += 2;

    // signature_algorithms (13)
    std.mem.writeInt(u16, out[i..][0..2], 13, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(SIG_SCHEMES.len * 2 + 2), .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(SIG_SCHEMES.len * 2), .big); // 向量长度
    i += 2;
    for (SIG_SCHEMES) |s| {
        std.mem.writeInt(u16, out[i..][0..2], s, .big);
        i += 2;
    }

    // supported_versions (43)
    std.mem.writeInt(u16, out[i..][0..2], 43, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 3, .big);
    i += 2;
    out[i] = 2;
    i += 1;
    std.mem.writeInt(u16, out[i..][0..2], 0x0304, .big);
    i += 2;

    // ALPN (16) — http/1.1 only
    std.mem.writeInt(u16, out[i..][0..2], 16, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 11, .big); // ext_data len = 2 + 1 + 8
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 9, .big); // ProtocolNameList len = 1 + 8
    i += 2;
    out[i] = 8;
    i += 1;
    out[i] = 'h';
    i += 1;
    out[i] = 't';
    i += 1;
    out[i] = 't';
    i += 1;
    out[i] = 'p';
    i += 1;
    out[i] = '/';
    i += 1;
    out[i] = '1';
    i += 1;
    out[i] = '.';
    i += 1;
    out[i] = '1';
    i += 1;

    // key_share (51) — x25519 only
    std.mem.writeInt(u16, out[i..][0..2], 51, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 2 + 2 + 2 + 32, .big); // ext_data = 列表长度 + 组 + 长度 + key
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 2 + 2 + 32, .big); // KeyShareEntry 列表长度
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 0x001d, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], 32, .big);
    i += 2;
    @memcpy(out[i..][0..32], &kp.public_key);
    i += 32;

    std.mem.writeInt(u16, out[ext_len_pos..][0..2], @intCast(i - ext_len_pos - 2), .big);
    const total = i - body;
    out[len_pos + 0] = @intCast((total >> 16) & 0xff);
    out[len_pos + 1] = @intCast((total >> 8) & 0xff);
    out[len_pos + 2] = @intCast(total & 0xff);
    return out[0..i];
}

// ============================== parsers ==============================

const HRR_RANDOM = [_]u8{ 0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91, 0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C };

const ServerHelloInfo = struct {
    suite: Suite,
    peer_pub: [32]u8,
};

fn parseServerHello(msg: []const u8) !ServerHelloInfo {
    var i: usize = 4; // skip handshake header
    const version = std.mem.readInt(u16, msg[i..][0..2], .big);
    i += 2;
    const random = msg[i..][0..32];
    i += 32;
    if (mem.eql(u8, random, &HRR_RANDOM)) return error.HelloRetryRequestUnsupported;
    const sid_len = msg[i];
    i += 1 + sid_len;
    const cs = std.mem.readInt(u16, msg[i..][0..2], .big);
    i += 2;
    i += 1; // compression
    const suite: Suite = switch (cs) {
        0x1301 => .aes_128_gcm_sha256,
        0x1303 => .chacha20_poly1305_sha256,
        else => return error.UnsupportedCipherSuite,
    };
    if (msg.len < i + 2) return error.MissingExtensions;
    const ext_len = std.mem.readInt(u16, msg[i..][0..2], .big);
    i += 2;
    const ext_end = i + ext_len;
    var peer_pub: [32]u8 = undefined;
    var got_version = false;
    var got_key = false;
    while (i + 4 <= ext_end) {
        const et = std.mem.readInt(u16, msg[i..][0..2], .big);
        const el = std.mem.readInt(u16, msg[i + 2 ..][0..2], .big);
        const ev = msg[i + 4 ..][0..el];
        i += 4 + el;
        switch (et) {
            43 => { // supported_versions
                const sv = std.mem.readInt(u16, ev[0..2], .big);
                if (sv != 0x0304) return error.TlsVersionNot13;
                got_version = true;
            },
            51 => { // key_share
                const grp = std.mem.readInt(u16, ev[0..2], .big);
                const kl = std.mem.readInt(u16, ev[2..4], .big);
                if (grp != 0x001d or kl != 32) return error.UnsupportedKeyShare;
                @memcpy(&peer_pub, ev[4..36]);
                got_key = true;
            },
            else => {},
        }
    }
    if (!got_version) return error.MissingSupportedVersion;
    if (!got_key) return error.MissingKeyShare;
    _ = version;
    return .{ .suite = suite, .peer_pub = peer_pub };
}

const CertEntry = struct { der: []const u8 };

fn parseCertificate(msg: []const u8, out: []CertEntry) ![]CertEntry {
    var i: usize = 4;
    const ctx_len = msg[i];
    i += 1 + ctx_len;
    const list_len = (@as(usize, msg[i]) << 16) | (@as(usize, msg[i + 1]) << 8) | msg[i + 2];
    i += 3;
    const end = i + list_len;
    var n: usize = 0;
    while (i < end and n < out.len) {
        const cl = (@as(usize, msg[i]) << 16) | (@as(usize, msg[i + 1]) << 8) | msg[i + 2];
        i += 3;
        out[n] = .{ .der = msg[i .. i + cl] };
        i += cl;
        const el = std.mem.readInt(u16, msg[i..][0..2], .big);
        i += 2 + el;
        n += 1;
    }
    return out[0..n];
}

/// TLS 1.3 CertificateVerify signature verification (server side).
fn verifyCertVerify(scheme: u16, pub_key_ctx: Certificate.Parsed, sig: []const u8, msg: []const []const u8) !void {
    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const EcdsaP384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
    switch (scheme) {
        0x0403 => {
            const s = try EcdsaP256.Signature.fromDer(sig);
            const k = try EcdsaP256.PublicKey.fromSec1(pub_key_ctx.pubKey());
            var v = try s.verifier(k);
            for (msg) |p| v.update(p);
            try v.verify();
        },
        0x0503 => {
            const s = try EcdsaP384.Signature.fromDer(sig);
            const k = try EcdsaP384.PublicKey.fromSec1(pub_key_ctx.pubKey());
            var v = try s.verifier(k);
            for (msg) |p| v.update(p);
            try v.verify();
        },
        0x0807 => {
            const Ed = std.crypto.sign.Ed25519;
            if (sig.len != Ed.Signature.encoded_length) return error.BadSignatureLength;
            const k = try Ed.PublicKey.fromBytes(pub_key_ctx.pubKey()[0..Ed.PublicKey.encoded_length].*);
            const s = Ed.Signature.fromBytes(sig[0..Ed.Signature.encoded_length].*);
            var v = try s.verifier(k);
            for (msg) |p| v.update(p);
            try v.verify();
        },
        0x0804, 0x0809 => try rsaVerify(std.crypto.hash.sha2.Sha256, true, pub_key_ctx, sig, msg),
        0x0805 => try rsaVerify(std.crypto.hash.sha2.Sha384, true, pub_key_ctx, sig, msg),
        0x0806 => try rsaVerify(std.crypto.hash.sha2.Sha512, true, pub_key_ctx, sig, msg),
        0x0401 => try rsaVerify(std.crypto.hash.sha2.Sha256, false, pub_key_ctx, sig, msg),
        0x0501 => try rsaVerify(std.crypto.hash.sha2.Sha384, false, pub_key_ctx, sig, msg),
        0x0601 => try rsaVerify(std.crypto.hash.sha2.Sha512, false, pub_key_ctx, sig, msg),
        else => return error.UnsupportedSignatureScheme,
    }
}

// ============================== handshake driver ==============================

fn deriveKeyIv(secret: [32]u8, suite: Suite) Keys4 {
    // 注意：HKDF-Expand-Label 的「输出长度」是 info 的一部分，必须按 cipher 真实 key 长度展开，
    // 不能先展开 32 再截断（那会得到完全不同的密钥）。
    var key: [32]u8 = @splat(0);
    switch (keyLenFor(suite)) {
        16 => {
            const k = hkdfExpandLabel(HkdfSha256, secret, "key", "", 16);
            @memcpy(key[0..16], &k);
        },
        32 => {
            const k = hkdfExpandLabel(HkdfSha256, secret, "key", "", 32);
            @memcpy(key[0..32], &k);
        },
        else => unreachable,
    }
    const iv = hkdfExpandLabel(HkdfSha256, secret, "iv", "", 12);
    return .{ .key = key, .iv = iv };
}

fn hsAppend(c: *Conn, b: []const u8) !void {
    if (c.hsl + b.len > c.hs.len) return error.HandshakeTooBig;
    @memcpy(c.hs[c.hsl..][0..b.len], b);
    c.hsl += b.len;
}

fn hsNext(c: *Conn) ?[]const u8 {
    if (c.hsl - c.hsp < 4) return null;
    const len = (@as(usize, c.hs[c.hsp + 1]) << 16) | (@as(usize, c.hs[c.hsp + 2]) << 8) | @as(usize, c.hs[c.hsp + 3]);
    if (c.hsl - c.hsp < 4 + len) return null;
    const msg = c.hs[c.hsp .. c.hsp + 4 + len];
    c.hsp += 4 + len;
    return msg;
}

fn rsaVerify(comptime Hash: type, comptime pss: bool, pk: Certificate.Parsed, sig: []const u8, msg: []const []const u8) !void {
    const components = try Certificate.rsa.PublicKey.parseDer(pk.pubKey());
    const modulus_len = components.modulus.len;
    switch (modulus_len) {
        inline 128, 256, 384, 512 => |ml| {
            const key = try Certificate.rsa.PublicKey.fromBytes(components.exponent, components.modulus);
            if (pss) {
                const sg = Certificate.rsa.PSSSignature.fromBytes(ml, sig);
                try Certificate.rsa.PSSSignature.concatVerify(ml, &sg, msg, key, Hash);
            } else {
                const sg = Certificate.rsa.PKCS1v1_5Signature.fromBytes(ml, sig);
                try Certificate.rsa.PKCS1v1_5Signature.concatVerify(ml, &sg, msg, key, Hash);
            }
        },
        else => return error.BadRsaBitCount,
    }
}

// ============================== 对外 API ==============================

/// 建立连接所需的参数。
pub const Options = struct {
    /// 目标主机（SNI 与证书主机名校验的默认取值；IP 字面量不发送 SNI）。
    host: []const u8,
    /// 目标端口（仅日志/信息用途；TCP 连接由调用方先行完成）。
    port: u16 = 443,
    /// 显式覆盖 SNI / 证书校验名（默认 = host）。
    sni: ?[]const u8 = null,
    /// 传输层读写实现（socket fd、测试桩皆可）。
    stream: Stream,
    /// true = 跳过证书主机名校验（对应 aio-cli 的 -k/--insecure）。
    insecure: bool = false,
    /// 覆盖调试开关；默认读环境变量 AIO_TLS_DEBUG。
    debug: ?bool = null,
};

fn isIpLiteral(s: []const u8) bool {
    if (std.Io.net.IpAddress.parse(s, 0)) |_| {
        return true;
    } else |_| {
        return false;
    }
}

/// 建立 TLS 1.3 连接：完成整个握手（证书主机名校验 + CertificateVerify 验签 +
/// 双方 Finished）后返回。用后需 `closeNotify()` 再 `deinit()`。
pub fn init(opts: Options) !*Conn {
    if (opts.debug) |d| {
        debug = d;
    } else if (envDebug()) {
        debug = true;
    }
    const gpa = std.heap.smp_allocator;
    const c = try gpa.create(Conn);
    errdefer gpa.destroy(c);
    c.stream = opts.stream;
    c.rpos = 0;
    c.rend = 0;
    c.hsp = 0;
    c.hsl = 0;
    c.tlen = 0;
    c.rd_len = 0;
    c.rd_pos = 0;
    c.rk = .{ .debug = debug };
    c.wk = .{ .debug = debug };
    try handshake(c, opts);
    dg("[tls] 握手完成 suite={s}\n", .{suiteName(c.wk.suite)});
    return c;
}

/// 释放连接（不关闭底层传输；socket 由调用方自行关闭）。
pub fn deinit(c: *Conn) void {
    std.heap.smp_allocator.destroy(c);
}

fn handshake(c: *Conn, opts: Options) !void {
    const verify_name: []const u8 = opts.sni orelse opts.host;
    const sni_send: ?[]const u8 = opts.sni orelse (if (isIpLiteral(opts.host)) null else opts.host);
    dg("[tls] 连接 {s}:{d}  sni={s}  insecure={}\n", .{ opts.host, opts.port, sni_send orelse "-", opts.insecure });

    // --- X25519 keypair（getrandom 播种）---
    var seed: [32]u8 = undefined;
    try randBytes(&seed);
    const kp = X25519.KeyPair.generateDeterministic(seed);

    var ch_buf: [1024]u8 = undefined;
    const ch = try buildClientHello(&ch_buf, sni_send, &kp);
    c.transcriptAppend(ch);
    try c.writeRecord(RecType.handshake, ch);
    dg("[tls] -> ClientHello ({d} bytes, x25519 key_share)\n", .{ch.len});

    // --- 明文 flight：读到 ServerHello ---
    var suite: Suite = .none;
    var peer_pub: [32]u8 = undefined;
    while (true) {
        const rec = try c.readRecordRaw();
        const payload = c.rbuf[c.rpos .. c.rpos + rec.len];
        c.rpos += rec.len;
        if (rec.t == RecType.change_cipher_spec) {
            dg("[tls] <- change_cipher_spec（兼容模式，忽略）\n", .{});
            continue;
        }
        if (rec.t == RecType.alert) {
            const desc: u8 = if (payload.len >= 2) payload[1] else 0;
            std.debug.print("[tls] 握手失败：服务端明文 alert desc={d}\n", .{desc});
            return error.ServerAlert;
        }
        if (rec.t != RecType.handshake) return error.UnexpectedRecordType;
        try hsAppend(c, payload);
        while (hsNext(c)) |msg| {
            if (msg[0] != Hs.server_hello) return error.ExpectedServerHello;
            const info = try parseServerHello(msg);
            suite = info.suite;
            peer_pub = info.peer_pub;
            c.transcriptAppend(msg);
            dg("[tls] <- ServerHello suite={s} version=0x0304\n", .{suiteName(suite)});
            break;
        }
        break;
    }

    // --- key schedule（TLS 1.3, SHA-256）---
    const ecdhe = try X25519.scalarmult(kp.secret_key, peer_pub);
    const zero32 = @as([32]u8, @splat(0));
    const eh = emptyHash(Sha256);
    const early_secret = HkdfSha256.extract(&zero32, &zero32);
    const d1 = hkdfExpandLabel(HkdfSha256, early_secret, "derived", &eh, 32);
    const handshake_secret = HkdfSha256.extract(&d1, &ecdhe);
    const sh_th = c.transcriptHash();
    const c_hs = hkdfExpandLabel(HkdfSha256, handshake_secret, "c hs traffic", &sh_th, 32);
    const s_hs = hkdfExpandLabel(HkdfSha256, handshake_secret, "s hs traffic", &sh_th, 32);
    const ck = deriveKeyIv(c_hs, suite);
    const sk = deriveKeyIv(s_hs, suite);
    c.rk = .{ .suite = suite, .key = sk.key, .iv = sk.iv, .debug = debug };
    c.wk = .{ .suite = suite, .key = ck.key, .iv = ck.iv, .debug = debug };
    dg("[tls] ECDHE 完成，handshake traffic keys 就绪\n", .{});

    // --- 加密 flight：EE / Certificate / CertificateVerify / Finished ---
    var certs: [16]CertEntry = undefined;
    var n_certs: usize = 0;
    var leaf: Certificate.Parsed = undefined;
    var got_ee = false;
    var got_cert = false;
    var got_cv = false;
    var got_fin = false;
    var flight: [16384]u8 = undefined;
    const cv_ctx = "TLS 1.3, server CertificateVerify";

    while (!got_fin) {
        const n = try c.readAppRecord(&flight);
        if (n == 0) continue;
        try hsAppend(c, flight[0..n]);
        while (hsNext(c)) |msg| {
            switch (msg[0]) {
                Hs.encrypted_extensions => {
                    c.transcriptAppend(msg);
                    got_ee = true;
                    dg("[tls] <- EncryptedExtensions ({d} B)\n", .{msg.len - 4});
                },
                Hs.certificate => {
                    n_certs = (parseCertificate(msg, &certs) catch return error.CertParseFailed).len;
                    if (n_certs == 0) return error.EmptyCertificateChain;
                    leaf = try Certificate.parse(.{ .buffer = certs[0].der, .index = 0 });
                    c.transcriptAppend(msg);
                    got_cert = true;
                    dg("[tls] <- Certificate: {d} 张, 叶子 {d} B, pubkey={s}\n", .{ n_certs, certs[0].der.len, @tagName(leaf.pub_key_algo) });
                    if (!opts.insecure) {
                        leaf.verifyHostName(verify_name) catch |e| {
                            std.debug.print("[tls] 证书主机名校验失败：{s} 不匹配（{t}）\n", .{ verify_name, e });
                            return error.CertificateHostMismatch;
                        };
                        dg("[cert] OK：证书匹配 {s}\n", .{verify_name});
                    } else {
                        dg("[cert] 跳过主机名校验（insecure）\n", .{});
                    }
                },
                Hs.certificate_verify => {
                    const th = c.transcriptHash();
                    const scheme = std.mem.readInt(u16, msg[4..6], .big);
                    const sig_len: usize = std.mem.readInt(u16, msg[6..8], .big);
                    if (8 + sig_len > msg.len) return error.BadCertVerify;
                    const sig = msg[8 .. 8 + sig_len];
                    const spaces = @as([64]u8, @splat(0x20));
                    const zero = [_]u8{0};
                    const parts = [_][]const u8{ &spaces, cv_ctx, &zero, &th };
                    verifyCertVerify(scheme, leaf, sig, &parts) catch |e| {
                        std.debug.print("[tls] CertificateVerify 验签失败 scheme=0x{x:0>4}: {t}\n", .{ scheme, e });
                        return e;
                    };
                    c.transcriptAppend(msg);
                    got_cv = true;
                    dg("[cert] OK：CertificateVerify 验签通过（scheme=0x{x:0>4}）\n", .{scheme});
                },
                Hs.finished => {
                    const th = c.transcriptHash();
                    const expect = finishedVerify(s_hs, th);
                    if (!std.crypto.timing_safe.eql([32]u8, expect, msg[4..36].*)) {
                        std.debug.print("[tls] 服务端 Finished verify_data 校验失败\n", .{});
                        return error.BadFinished;
                    }
                    c.transcriptAppend(msg);
                    got_fin = true;
                    dg("[tls] <- Finished OK（服务端 verify_data 匹配）\n", .{});
                },
                else => dg("[tls] （忽略握手消息 type={d}, {d} B）\n", .{ msg[0], msg.len }),
            }
        }
    }
    if (!got_ee or !got_cert or !got_cv) {
        std.debug.print("[tls] 服务端 flight 不完整：ee={} cert={} cv={}\n", .{ got_ee, got_cert, got_cv });
        return error.IncompleteFlight;
    }

    // --- 应用密钥 + 客户端 Finished ---
    const d2 = hkdfExpandLabel(HkdfSha256, handshake_secret, "derived", &eh, 32);
    const master_secret = HkdfSha256.extract(&d2, &zero32);
    const fin_th = c.transcriptHash();
    const c_ap = hkdfExpandLabel(HkdfSha256, master_secret, "c ap traffic", &fin_th, 32);
    const s_ap = hkdfExpandLabel(HkdfSha256, master_secret, "s ap traffic", &fin_th, 32);
    try c.stream.writeAll(&[_]u8{ 0x14, 0x03, 0x03, 0x00, 0x01, 0x01 }); // 兼容模式 CCS
    const client_finished = finishedVerify(c_hs, fin_th);
    var fin_msg: [36]u8 = undefined; // Finished 握手消息必须带 4 字节头
    fin_msg[0] = Hs.finished;
    fin_msg[1] = 0;
    fin_msg[2] = 0;
    fin_msg[3] = 32;
    @memcpy(fin_msg[4..36], &client_finished);
    try c.writeRecord(RecType.handshake, &fin_msg);
    const cka = deriveKeyIv(c_ap, suite);
    const ska = deriveKeyIv(s_ap, suite);
    c.wk = .{ .suite = suite, .key = cka.key, .iv = cka.iv, .debug = debug };
    c.rk = .{ .suite = suite, .key = ska.key, .iv = ska.iv, .debug = debug };
    dg("[tls] -> Finished OK（客户端）\n", .{});
}

// ============================== 单元测试（测试桩 Stream） ==============================

const MemStream = struct {
    data: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn readFn(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        _ = ctx;
        _ = buf;
        return 0; // 本桩只用于写路径对拍：读方向直接 EOF。
    }

    fn writeFn(ctx: ?*anyopaque, buf: []const u8) anyerror!usize {
        const self: *MemStream = @ptrCast(@alignCast(ctx.?));
        if (self.len + buf.len > self.data.len) return error.NoSpaceLeft;
        @memcpy(self.data[self.len..][0..buf.len], buf);
        self.len += buf.len;
        return buf.len;
    }
};

test "isIpLiteral" {
    try std.testing.expect(isIpLiteral("127.0.0.1"));
    try std.testing.expect(isIpLiteral("::1"));
    try std.testing.expect(!isIpLiteral("example.com"));
}

test "长写入按记录层分帧，可用同一套密钥回解" {
    const gpa = std.testing.allocator;
    const c = try gpa.create(Conn);
    defer gpa.destroy(c);

    var stub: MemStream = .{};
    const key: [32]u8 = @splat(0xAB);
    const iv: [12]u8 = @splat(0x11);
    c.* = Conn{
        .stream = .{ .ctx = &stub, .readFn = MemStream.readFn, .writeFn = MemStream.writeFn },
        .rk = .{ .suite = .aes_128_gcm_sha256, .key = key, .iv = iv },
        .wk = .{ .suite = .aes_128_gcm_sha256, .key = key, .iv = iv },
    };

    var payload: [40000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    try c.write(&payload);

    var check: TrafficKeys = .{ .suite = .aes_128_gcm_sha256, .key = key, .iv = iv };
    var off: usize = 0;
    var plain: [REC_MAX]u8 = undefined;
    var total: usize = 0;
    var records: usize = 0;
    while (off < stub.len) {
        try std.testing.expect(stub.len - off >= 5);
        try std.testing.expectEqual(RecType.application_data, stub.data[off]);
        const len = std.mem.readInt(u16, stub.data[off + 3 ..][0..2], .big);
        const enc = stub.data[off + 5 .. off + 5 + len];
        var tag: [16]u8 = undefined;
        @memcpy(&tag, enc[enc.len - 16 ..]);
        const body = enc[0 .. enc.len - 16];
        try openWith(&check, plain[0..body.len], body, tag, stub.data[off .. off + 5]);
        // 本实现对「发出」记录的内层布局 = [内容][content_type]
        try std.testing.expectEqual(RecType.application_data, plain[body.len - 1]);
        for (0..body.len - 1) |i| {
            try std.testing.expectEqual(payload[total + i], plain[i]);
        }
        total += body.len - 1;
        off += 5 + len;
        records += 1;
    }
    try std.testing.expectEqual(@as(usize, 40000), total);
    try std.testing.expectEqual(@as(usize, 3), records); // 16367 + 16367 + 7266
}
