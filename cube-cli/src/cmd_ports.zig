//! ports —— 实测沙箱内**实际监听**的端口（模板声明的未必等于实际监听）。
//!
//! 为什么不能信模板声明（均实测）：
//!   - 创建沙箱时传 exposedPorts 会被平台静默忽略（返回 201 但不生效）
//!   - 未声明的端口照样能经 /sandbox/<id>/<port>/ 访问（只要有服务在听）
//!   - 真正决定可达性的是**绑定地址**：0.0.0.0/:: 可连；127.0.0.1/::1 只有沙箱内部能连
//!   - 模板声明了 18091/18100 却根本没监听的情况很常见
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const envd = @import("envd.zig");
const cfg = @import("cfg.zig");
const tmpl = @import("cmd_template.zig");

const Ctx = ctxmod.Ctx;
const MAX_LISTEN = 128;

const Listen = struct {
    port: u16,
    proto: []const u8,
    bind: []const u8,
    external: bool,
};

fn allZero(hex: []const u8) bool {
    for (hex) |ch| {
        if (ch != '0') return false;
    }
    return true;
}

/// 把 /proc/net/tcp* 的十六进制绑定地址转成可读形式，并判断能否外部访问。
fn bindFromHex(arena: std.mem.Allocator, proto: []const u8, hex: []const u8) !struct { bind: []const u8, external: bool } {
    if (allZero(hex)) {
        if (std.mem.eql(u8, proto, "tcp6")) return .{ .bind = "::", .external = true };
        return .{ .bind = "0.0.0.0", .external = true };
    }
    // IPv4：小端 8 位十六进制，如 0100007F = 127.0.0.1
    if (std.mem.eql(u8, proto, "tcp") and hex.len == 8) {
        const b0 = std.fmt.parseInt(u8, hex[6..8], 16) catch 0;
        const b1 = std.fmt.parseInt(u8, hex[4..6], 16) catch 0;
        const b2 = std.fmt.parseInt(u8, hex[2..4], 16) catch 0;
        const b3 = std.fmt.parseInt(u8, hex[0..2], 16) catch 0;
        const s = try std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{ b0, b1, b2, b3 });
        return .{ .bind = s, .external = !std.mem.startsWith(u8, s, "127.") };
    }
    // IPv6 ::1
    if (hex.len == 32 and std.mem.eql(u8, hex[24..], "01000000") and allZero(hex[0..24])) {
        return .{ .bind = "::1", .external = false };
    }
    return .{ .bind = hex, .external = true };
}

fn lessThan(_: void, x: Listen, y: Listen) bool {
    return x.port < y.port;
}

fn cmdPorts(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;

    // 在沙箱内读监听表（st == 0A 即 LISTEN）
    const script =
        "for f in /proc/net/tcp /proc/net/tcp6; do [ -r \"$f\" ] || continue; n=$(basename \"$f\"); " ++
        "awk -v n=\"$n\" 'NR>1 && $4==\"0A\" {print n\" \"$2}' \"$f\"; done";

    const buf = try c.arena.alloc(u8, 1 << 20);
    const token = try c.connectToken(sid, buf);
    const envd_base = try c.envdBase(sid);
    const res = try envd.exec(c.arena, c.client, envd_base, token, null, script, null, null, 30_000, buf);

    const items = try c.arena.alloc(Listen, MAX_LISTEN);
    var n: usize = 0;

    var lines = std.mem.tokenizeAny(u8, res.stdout, "\r\n");
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const proto = parts.next() orelse continue;
        const addr = parts.next() orelse continue;
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse continue;
        const hexaddr = addr[0..colon];
        const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 16) catch continue;
        const b = try bindFromHex(c.arena, proto, hexaddr);

        // 同一端口保留“更可达”的记录
        var replaced = false;
        for (items[0..n]) |*it| {
            if (it.port == port) {
                if (!it.external and b.external) {
                    it.* = .{ .port = port, .proto = proto, .bind = b.bind, .external = true };
                }
                replaced = true;
                break;
            }
        }
        if (!replaced and n < MAX_LISTEN) {
            items[n] = .{ .port = port, .proto = proto, .bind = b.bind, .external = b.external };
            n += 1;
        }
    }
    std.mem.sort(Listen, items[0..n], {}, lessThan);

    const proxy = cfg.proxyURL();
    try c.out.print("{s:<6} {s:<16} {s:<6} {s:<18} {s}\n", .{ "端口", "绑定", "外部", "服务", "访问地址" });
    for (items[0..n]) |p| {
        const name = tmpl.portName(p.port);
        const ext: []const u8 = if (p.external) "可连" else "-";
        if (p.external) {
            if (proxy) |px| {
                const url = try std.fmt.allocPrint(c.arena, "{s}/sandbox/{s}/{d}/", .{ ctxmod.trimSlash(px), sid, p.port });
                try c.out.print("{d:<6} {s:<16} {s:<6} {s:<18} {s}\n", .{ p.port, p.bind, ext, name, url });
                continue;
            }
        }
        try c.out.print("{d:<6} {s:<16} {s:<6} {s:<18} {s}\n", .{ p.port, p.bind, ext, name, "（仅沙箱内部）" });
    }
    if (n == 0) {
        try c.out.print("（未读到监听端口：刚创建的沙箱里服务可能还在启动，稍等再测）\n", .{});
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (eq(cmd, "ports")) {
        const a = try util.parse(c.arena, argv);
        try cmdPorts(c, a);
        return true;
    }
    return false;
}
