//! Minimal TLS 1.3 client — pure std.crypto, no fork, no std.crypto.tls.
//! Zig 0.17.0. Verified against api.cloudflare.com.
//!
//! Supports: TLS 1.3 only, X25519 key_share only, TLS_AES_128_GCM_SHA256 +
//! TLS_CHACHA20_POLY1305_SHA256, SNI, ALPN http/1.1, CertificateVerify
//! signature verification (ecdsa_secp256r1_sha256 / rsa_pss_rsae_* /
//! rsa_pkcs1_* / ed25519), X.509 hostname verification.
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

// ============================== raw syscalls ==============================

const SysError = error{ SyscallFailed, Eof, UnexpectedEof, BadAddress };

fn rcErrno(rc: usize) u32 {
    const signed: isize = @bitCast(rc);
    return @intCast(-signed);
}

fn isErr(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

fn check(rc: usize) SysError!usize {
    if (isErr(rc)) return error.SyscallFailed;
    return rc;
}

fn sysRead(fd: linux.fd_t, buf: []u8) SysError!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        if (isErr(rc)) { // error range
            if (linux.errno(rc) == .INTR) continue;
            std.debug.print("[sys] read errno={d}\n", .{@intFromEnum(linux.errno(rc))});
            return error.SyscallFailed;
        }
        return rc;
    }
}

fn sysWrite(fd: linux.fd_t, buf: []const u8) SysError!usize {
    while (true) {
        const rc = linux.write(fd, buf.ptr, buf.len);
        if (rc > 1 << 40) {
            if (linux.errno(rc) == .INTR) continue;
            std.debug.print("[sys] write errno={d}\n", .{@intFromEnum(linux.errno(rc))});
            return error.SyscallFailed;
        }
        return rc;
    }
}

fn sysWriteAll(fd: linux.fd_t, buf: []const u8) SysError!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try sysWrite(fd, buf[off..]);
        if (n == 0) return error.SyscallFailed;
        off += n;
    }
}

fn tcpConnect(ipv4: [4]u8, port: u16) SysError!linux.fd_t {
    const rc0 = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    if (isErr(rc0)) {
        std.debug.print("[sys] socket errno={d}\n", .{@intFromEnum(linux.errno(rc0))});
        return error.SyscallFailed;
    }
    const fd: linux.fd_t = @intCast(rc0);
    errdefer _ = linux.close(fd);
    const addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = mem.nativeToBig(u16, port),
        .addr = @bitCast(ipv4),
        .zero = @splat(0),
    };
    const rc = linux.connect(fd, @ptrCast(&addr), @as(linux.socklen_t, @intCast(@sizeOf(linux.sockaddr.in))));
    if (isErr(rc)) {
        std.debug.print("[sys] connect errno={d}\n", .{@intFromEnum(linux.errno(rc))});
        return error.SyscallFailed;
    }
    return fd;
}

// ============================== AEAD plumbing ==============================

const TrafficKeys = struct {
    suite: Suite = .none,
    key: [32]u8 = @splat(0),
    iv: [12]u8 = @splat(0),
    seq: u64 = 0,
    debug: bool = true,
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

const Conn = struct {
    fd: linux.fd_t,
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
    verbose: bool,

    fn fill(c: *Conn, n: usize) !void {
        while (c.rend - c.rpos < n) {
            if (c.rpos > 0 and c.rend == c.rbuf.len) {
                mem.copyForwards(u8, c.rbuf[0 .. c.rend - c.rpos], c.rbuf[c.rpos..c.rend]);
                c.rend -= c.rpos;
                c.rpos = 0;
            }
            const nread = try sysRead(c.fd, c.rbuf[c.rend..]);
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
        try c.fill(5 + len);
        c.rpos += 5;
        const r = c.rbuf.len - c.rpos;
        if (len > r) return error.RecordTooLarge;
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
                std.debug.print("[tls] <- change_cipher_spec (compat, skipped)\n", .{});
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
            std.debug.print("[dbg] inner=", .{});
            hex(inner[0..@min(inner.len, body.len + 6)]);
            std.debug.print(" bodylen={d}\n", .{body.len});
            if (payload_len > out.len) return error.RecordTooLarge;
            @memcpy(out[0..payload_len], inner[pay..][0..payload_len]);
            if (real_type == RecType.alert) {
                if (payload_len >= 2 and out[1] == 0) return error.PeerCloseNotify;
                std.debug.print("[tls] ALERT from server: desc={d}\n", .{ if (payload_len >= 2) out[1] else 0 });
                return error.RemoteAlert;
            }
            if (real_type == RecType.handshake and (out[0] == 4 or out[0] == 24)) {
                std.debug.print("[tls] (skipping post-handshake message type={d}, {d} B)\n", .{ out[0], payload_len });
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
            try sysWriteAll(c.fd, &hdr);
            try sysWriteAll(c.fd, payload);
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
        try sysWriteAll(c.fd, out[0 .. 5 + total]);
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

fn buildClientHello(out: []u8, sni: []const u8, kp: *const X25519.KeyPair) ![]const u8 {
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

    // server_name (0)
    std.mem.writeInt(u16, out[i..][0..2], 0, .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(sni.len + 5), .big);
    i += 2;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(sni.len + 3), .big);
    i += 2;
    out[i] = 0;
    i += 1;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(sni.len), .big);
    i += 2;
    @memcpy(out[i..][0..sni.len], sni);
    i += sni.len;

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

fn parseIp(s: []const u8) ![4]u8 {
    var out: [4]u8 = undefined;
    var it = mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= 4) return error.BadIp;
        out[n] = std.fmt.parseInt(u8, part, 10) catch return error.BadIp;
    }
    if (n != 4) return error.BadIp;
    return out;
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

pub fn main(init: std.process.Init.Minimal) !void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip(); // argv[0]

    var sni: []const u8 = "api.cloudflare.com";
    var ip: [4]u8 = .{ 104, 16, 0, 0 };
    var path: []const u8 = "/cdn-cgi/trace";
    var port: u16 = 443;
    var insecure = false;
    var pending: u8 = 0; // 1=sni 2=ip 3=path 4=port
    while (it.next()) |a| {
        switch (pending) {
            1 => {
                sni = a;
                pending = 0;
                continue;
            },
            2 => {
                ip = try parseIp(a);
                pending = 0;
                continue;
            },
            3 => {
                path = a;
                pending = 0;
                continue;
            },
            4 => {
                port = try std.fmt.parseInt(u16, a, 10);
                pending = 0;
                continue;
            },
            else => {},
        }
        if (mem.eql(u8, a, "--sni")) {
            pending = 1;
        } else if (mem.eql(u8, a, "--ip")) {
            pending = 2;
        } else if (mem.eql(u8, a, "--path")) {
            pending = 3;
        } else if (mem.eql(u8, a, "--port")) {
            pending = 4;
        } else if (mem.eql(u8, a, "-k")) {
            insecure = true;
        } else {
            std.debug.print("usage: tls13_poc [--sni HOST] [--ip A.B.C.D] [--port N] [--path /p] [-k]\n", .{});
            return;
        }
    }

    std.debug.print("== zig tls13 poc (pure std.crypto, no std.crypto.tls) ==\n", .{});
    std.debug.print("target {s}:{d}  SNI={s}  insecure={}\n", .{ sni, port, sni, insecure });

    const fd = try tcpConnect(ip, port);
    defer _ = linux.close(fd);
    std.debug.print("[net] TCP connected\n", .{});

    var c: Conn = .{ .fd = fd, .verbose = true };

    // --- X25519 keypair (deterministic from getrandom, no std.Io needed) ---
    var seed: [32]u8 = undefined;
    try randBytes(&seed);
    const kp = X25519.KeyPair.generateDeterministic(seed);

    var ch_buf: [1024]u8 = undefined;
    const ch = try buildClientHello(&ch_buf, sni, &kp);
    c.transcriptAppend(ch);
    try c.writeRecord(RecType.handshake, ch);
    std.debug.print("[tls] -> ClientHello ({d} bytes, x25519 key_share)\n", .{ch.len});
    if (c.verbose) {
        std.debug.print("[tls] CH hex:", .{});
        hex(ch);
        std.debug.print("\n", .{});
    }

    // --- plaintext flight until ServerHello ---
    var suite: Suite = .none;
    var peer_pub: [32]u8 = undefined;
    while (true) {
        const rec = try c.readRecordRaw();
        const payload = c.rbuf[c.rpos .. c.rpos + rec.len];
        c.rpos += rec.len;
        if (rec.t == RecType.change_cipher_spec) {
            std.debug.print("[tls] <- change_cipher_spec (compat mode, ignored)\n", .{});
            continue;
        }
        if (rec.t == RecType.alert) {
            std.debug.print("[tls] <- plaintext alert {d}\n", .{payload[1]});
            return error.AlertBeforeServerHello;
        }
        if (rec.t != RecType.handshake) return error.UnexpectedRecordType;
        try hsAppend(&c, payload);
        while (hsNext(&c)) |msg| {
            if (msg[0] != Hs.server_hello) return error.ExpectedServerHello;
            const info = try parseServerHello(msg);
            suite = info.suite;
            peer_pub = info.peer_pub;
            c.transcriptAppend(msg);
            std.debug.print("[tls] <- ServerHello  suite={s}  version=0x0304\n", .{suiteName(suite)});
            break;
        }
        break;
    }

    // --- key schedule (TLS 1.3, SHA-256) ---
    const ecdhe = try X25519.scalarmult(kp.secret_key, peer_pub);
    const zero32 = @as([32]u8, @splat(0));
    std.debug.print("[dbg] my_secret=", .{});
    hex(&kp.secret_key);
    std.debug.print(" peer_pub=", .{});
    hex(&peer_pub);
    std.debug.print(" ecdhe=", .{});
    hex(&ecdhe);
    std.debug.print("\n[tls] [dbg] SH=", .{});
    hex(c.hs[0..c.hsl]);
    std.debug.print("\n", .{});
    const eh = emptyHash(Sha256);
    const early_secret = HkdfSha256.extract(&zero32, &zero32);
    const d1 = hkdfExpandLabel(HkdfSha256, early_secret, "derived", &eh, 32);
    const handshake_secret = HkdfSha256.extract(&d1, &ecdhe);
    const sh_th = c.transcriptHash();
    const c_hs = hkdfExpandLabel(HkdfSha256, handshake_secret, "c hs traffic", &sh_th, 32);
    const s_hs = hkdfExpandLabel(HkdfSha256, handshake_secret, "s hs traffic", &sh_th, 32);
    const ck = deriveKeyIv(c_hs, suite);
    const sk = deriveKeyIv(s_hs, suite);
    c.rk = .{ .suite = suite, .key = sk.key, .iv = sk.iv, .seq = 0 };
    c.wk = .{ .suite = suite, .key = ck.key, .iv = ck.iv, .seq = 0 };
    std.debug.print("[crypto] ECDHE done, handshake traffic keys installed\n", .{});
    std.debug.print("[dbg] ck=", .{}); hex(ck.key[0..8]);
    std.debug.print(" sk=", .{}); hex(sk.key[0..8]);
    std.debug.print(" ck_iv=", .{}); hex(ck.iv[0..]);
    std.debug.print(" sk_iv=", .{}); hex(sk.iv[0..]);
    std.debug.print("\n", .{});

    // --- encrypted server flight ---
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
        try hsAppend(&c, flight[0..n]);
        while (hsNext(&c)) |msg| {
            switch (msg[0]) {
                Hs.encrypted_extensions => {
                    c.transcriptAppend(msg);
                    got_ee = true;
                    std.debug.print("[tls] <- EncryptedExtensions ({d} B)\n", .{msg.len - 4});
                },
                Hs.certificate => {
                    n_certs = (parseCertificate(msg, &certs) catch return error.CertParseFailed).len;
                    if (n_certs == 0) return error.EmptyCertificateChain;
                    leaf = try Certificate.parse(.{ .buffer = certs[0].der, .index = 0 });
                    c.transcriptAppend(msg);
                    got_cert = true;
                    std.debug.print("[tls] <- Certificate: {d} certs, leaf {d} B, pubkey={s}\n", .{
                        n_certs,
                        certs[0].der.len,
                        @tagName(leaf.pub_key_algo),
                    });
                    if (!insecure) {
                        leaf.verifyHostName(sni) catch |e| {
                            std.debug.print("[cert] FAIL hostname verify ({s}): {any}\n", .{ sni, e });
                            return error.HostnameMismatch;
                        };
                        std.debug.print("[cert] OK hostname matches SAN of {s}\n", .{sni});
                    }
                },
                Hs.certificate_verify => {
                    const th = c.transcriptHash();
                    const scheme = std.mem.readInt(u16, msg[4..6], .big);
                    const sig_len = std.mem.readInt(u16, msg[6..8], .big);
                    const sig = msg[8 .. 8 + sig_len];
                    const spaces = @as([64]u8, @splat(0x20));
                    const zero = [_]u8{0};
                    const parts = [_][]const u8{ &spaces, cv_ctx, &zero, &th };
                    verifyCertVerify(scheme, leaf, sig, &parts) catch |e| {
                        std.debug.print("[cert] FAIL CertificateVerify scheme=0x{x:0>4}: {any}\n", .{ scheme, e });
                        return e;
                    };
                    c.transcriptAppend(msg);
                    got_cv = true;
                    std.debug.print("[cert] OK CertificateVerify verified (scheme=0x{x:0>4})\n", .{scheme});
                },
                Hs.finished => {
                    const th = c.transcriptHash();
                    const expect = finishedVerify(s_hs, th);
                    if (!std.crypto.timing_safe.eql([32]u8, expect, msg[4..36].*)) {
                        std.debug.print("[tls] FAIL server Finished verify_data mismatch\n", .{});
                        return error.BadFinished;
                    }
                    c.transcriptAppend(msg);
                    got_fin = true;
                    std.debug.print("[tls] <- Finished OK (server verify_data matched)\n", .{});
                },
                else => std.debug.print("[tls] (ignoring handshake type {d}, {d} B)\n", .{ msg[0], msg.len }),
            }
        }
    }
    if (!got_ee or !got_cert or !got_cv) {
        std.debug.print("[tls] incomplete server flight ee={} cert={} cv={}\n", .{ got_ee, got_cert, got_cv });
        return error.IncompleteFlight;
    }

    // --- application keys + client Finished ---
    const d2 = hkdfExpandLabel(HkdfSha256, handshake_secret, "derived", &eh, 32);
    const master_secret = HkdfSha256.extract(&d2, &zero32);
    const fin_th = c.transcriptHash();
    const c_ap = hkdfExpandLabel(HkdfSha256, master_secret, "c ap traffic", &fin_th, 32);
    const s_ap = hkdfExpandLabel(HkdfSha256, master_secret, "s ap traffic", &fin_th, 32);
    try sysWriteAll(c.fd, &[_]u8{ 0x14, 0x03, 0x03, 0x00, 0x01, 0x01 }); // 兼容模式 CCS
    const client_finished = finishedVerify(c_hs, fin_th);
    var fin_msg: [36]u8 = undefined; // Finished 握手消息必须带 4 字节头
    fin_msg[0] = Hs.finished;
    fin_msg[1] = 0;
    fin_msg[2] = 0;
    fin_msg[3] = 32;
    @memcpy(fin_msg[4..36], &client_finished);
    try c.writeRecord(RecType.handshake, &fin_msg);
    std.debug.print("[tls] -> Finished OK (client)\n", .{});
    const cka = deriveKeyIv(c_ap, suite);
    const ska = deriveKeyIv(s_ap, suite);
    c.wk = .{ .suite = suite, .key = cka.key, .iv = cka.iv, .seq = 0 };
    c.rk = .{ .suite = suite, .key = ska.key, .iv = ska.iv, .seq = 0 };
    std.debug.print("*** HANDSHAKE COMPLETE *** TLS1.3 {s}\n", .{suiteName(suite)});

    // --- HTTP request over the encrypted stream ---
    var req: [1024]u8 = undefined;
    const reqtext = try std.fmt.bufPrint(&req, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: tls13-poc-zig017\r\nAccept: */*\r\nConnection: close\r\n\r\n", .{ path, sni });
    try c.writeRecord(RecType.application_data, reqtext);
    std.debug.print("[http] -> GET {s}\n", .{path});

    var resp: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < resp.len - 1) {
        const n = c.readAppRecord(resp[total..]) catch |e| switch (e) {
            error.PeerCloseNotify => break,
            else => return e,
        };
        total += n;
    }
    resp[total] = 0;
    std.debug.print("[http] <- {d} bytes\n---8<---\n{s}\n---8<---\n", .{ total, resp[0..total] });
    _ = linux.E;
}
