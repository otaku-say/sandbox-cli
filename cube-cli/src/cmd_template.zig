//! 模板画像：能力 + 端口 + AIO 网关端口，尽量以静态信息（亚秒级）给出。
//!
//! 原则（来自实测）：模板注解里的暴露端口**不是**访问控制，但端口本身是强能力信号：
//!   - 暴露 9222（CDP）的多为完整 AIO 镜像，网关在 8080
//!   - 只暴露 18091/49983/49999 的轻量镜像，网关在 18091
const std = @import("std");
const httpc = @import("httpc.zig");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const envd = @import("envd.zig");

const Ctx = ctxmod.Ctx;

const CAP_BASE = "shell,file,code";
const MAX_PORTS = 64;

const PortInfo = struct { port: u16, name: []const u8 };
const port_catalog = [_]PortInfo{
    .{ .port = 49983, .name = "envd" },
    .{ .port = 18091, .name = "aiod" },
    .{ .port = 8080, .name = "aio" },
    .{ .port = 8091, .name = "aio-alt" },
    .{ .port = 9222, .name = "cdp" },
    .{ .port = 5900, .name = "vnc" },
    .{ .port = 6080, .name = "novnc" },
    .{ .port = 49999, .name = "code-interpreter" },
    .{ .port = 8888, .name = "jupyter" },
    .{ .port = 8200, .name = "code-server" },
    .{ .port = 18100, .name = "aio-internal" },
};

pub fn portName(p: u16) []const u8 {
    for (port_catalog) |pi| {
        if (pi.port == p) return pi.name;
    }
    return "unknown";
}

/// 解析 "8080:9222:49983" / "8080,9222" → 去重排序的端口数组。
pub fn parsePorts(arena: std.mem.Allocator, s: []const u8) ![]u16 {
    const buf = try arena.alloc(u16, MAX_PORTS);
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, ":, ");
    while (it.next()) |tok| {
        if (n >= buf.len) break;
        const v = std.fmt.parseInt(u16, tok, 10) catch continue;
        var dup = false;
        for (buf[0..n]) |x| {
            if (x == v) dup = true;
        }
        if (!dup) {
            buf[n] = v;
            n += 1;
        }
    }
    const out = buf[0..n];
    std.mem.sort(u16, out, {}, std.sort.asc(u16));
    return out;
}

fn hasPort(ports: []const u16, p: u16) bool {
    for (ports) |x| {
        if (x == p) return true;
    }
    return false;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// 网关端口推断（实测：完整镜像 8080，轻量镜像 18091）。
pub fn guessGateway(ports: []const u16, image: []const u8) u16 {
    if (hasPort(ports, 9222) and hasPort(ports, 8080)) return 8080;
    if (hasPort(ports, 8080) and !hasPort(ports, 18091)) return 8080;
    if (hasPort(ports, 18091)) return 18091;
    if (hasPort(ports, 8080)) return 8080;
    if (contains(image, "aio-code")) return 18091;
    return 0;
}

/// 能力推断（保守白名单）。
pub fn capsFromStatic(arena: std.mem.Allocator, ports: []const u16, image: []const u8) ![]const u8 {
    const browser = hasPort(ports, 9222) or contains(image, "aio-daemon") or
        contains(image, "aio-computer") or contains(image, "all-in-one") or contains(image, "aiod");
    const desktop = contains(image, "aio-computer") or hasPort(ports, 5900) or hasPort(ports, 6080);
    if (!browser and !desktop) return CAP_BASE;

    // 固定缓冲拼接（0.17 的 ArrayList 初始化方式不稳定，避免使用）
    const buf = try arena.alloc(u8, 128);
    var n: usize = 0;
    @memcpy(buf[0..CAP_BASE.len], CAP_BASE);
    n = CAP_BASE.len;
    if (browser) {
        const s = ",browser";
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
    }
    if (desktop) {
        const s = ",desktop";
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
    }
    return buf[0..n];
}

fn covers(have: []const u8, need: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, need, ',');
    while (it.next()) |n| {
        if (!contains(have, n)) return false;
    }
    return true;
}

const Tpl = struct {
    templateID: []const u8 = "",
    status: []const u8 = "",
    createdAt: []const u8 = "",
    imageInfo: []const u8 = "",
    aliases: []const []const u8 = &.{},
};

fn baseName(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

/// 取模板详情里的暴露端口注解（字符串扫描，避免复杂 JSON 类型）。
fn detailPorts(c: *Ctx, id: []const u8, buf: []u8) ![]u16 {
    const path = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{id});
    const res = c.control(.GET, path, null, buf) catch return &.{};
    const raw = envd.extractString(c.arena, res.body, "com.exposed_ports") orelse return &.{};
    return parsePorts(c.arena, raw);
}

fn fetchTemplates(c: *Ctx) ![]Tpl {
    const buf = try c.arena.alloc(u8, 2 << 20);
    const res = try c.control(.GET, "/templates", null, buf);
    const parsed = std.json.parseFromSlice([]Tpl, c.arena, res.body, .{ .ignore_unknown_fields = true }) catch |e| {
        try c.out.print("JSON 解析失败: {t}\n", .{e});
        return e;
    };
    return parsed.value;
}

fn tplLs(c: *Ctx, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, 2 << 20);
    if (a.has("json")) {
        const res = try c.control(.GET, "/templates", null, buf);
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    const list = try fetchTemplates(c);
    try c.out.print("{s:<34} {s:<7} {s:<6} {s}\n", .{ "模板ID", "状态", "网关", "镜像" });
    for (list) |t| {
        const ports = try detailPorts(c, t.templateID, buf);
        const gw = guessGateway(ports, t.imageInfo);
        var gwbuf: [8]u8 = undefined;
        const gws: []const u8 = if (gw > 0) try std.fmt.bufPrint(&gwbuf, "{d}", .{gw}) else "-";
        try c.out.print("{s:<34} {s:<7} {s:<6} {s}\n", .{ t.templateID, t.status, gws, baseName(t.imageInfo) });
    }
}

fn tplCaps(c: *Ctx, a: util.Args) !void {
    _ = a;
    const buf = try c.arena.alloc(u8, 2 << 20);
    const list = try fetchTemplates(c);
    try c.out.print("{s:<34} {s:<28} {s:<6} {s}\n", .{ "模板ID", "能力", "网关", "端口" });
    for (list) |t| {
        const ports = try detailPorts(c, t.templateID, buf);
        const caps = try capsFromStatic(c.arena, ports, t.imageInfo);
        const gw = guessGateway(ports, t.imageInfo);
        var gwbuf: [8]u8 = undefined;
        const gws: []const u8 = if (gw > 0) try std.fmt.bufPrint(&gwbuf, "{d}", .{gw}) else "-";

        var pbuf: [256]u8 = undefined;
        var pn: usize = 0;
        for (ports, 0..) |p, i| {
            if (i > 0) {
                pbuf[pn] = ',';
                pn += 1;
            }
            const s = try std.fmt.bufPrint(pbuf[pn..], "{d}", .{p});
            pn += s.len;
        }
        try c.out.print("{s:<34} {s:<28} {s:<6} {s}\n", .{ t.templateID, caps, gws, pbuf[0..pn] });
    }
}

/// 选型结果：模板 ID + 能力 + 网关端口
pub const Picked = struct { id: []const u8, caps: []const u8, gw: u16 };

/// 按能力挑模板（能力覆盖 + 更薄者优先）—— tpl-pick 与 new --need 共用。
pub fn pickByNeed(c: *Ctx, need: []const u8) !Picked {
    const buf = try c.arena.alloc(u8, 2 << 20);
    const list = try fetchTemplates(c);
    var best: ?Picked = null;
    for (list) |t| {
        if (!std.mem.eql(u8, t.status, "READY")) continue;
        const ports = try detailPorts(c, t.templateID, buf);
        const caps = try capsFromStatic(c.arena, ports, t.imageInfo);
        if (!covers(caps, need)) continue;
        if (best == null or caps.len < best.?.caps.len) {
            best = .{ .id = t.templateID, .caps = caps, .gw = guessGateway(ports, t.imageInfo) };
        }
    }
    return best orelse error.NotFound;
}

fn tplPick(c: *Ctx, a: util.Args) !void {
    const need = a.get("need") orelse CAP_BASE;
    const p = pickByNeed(c, need) catch {
        try c.out.print("没有满足 --need={s} 的 READY 模板\n", .{need});
        return error.NotFound;
    };
    try c.out.print("{s}\n", .{p.id});
    try c.out.print("need={s}  能力={s}  网关={d}\n", .{ need, p.caps, p.gw });
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "tpl-ls")) {
        try tplLs(c, a);
        return true;
    }
    if (eq(cmd, "tpl-caps")) {
        try tplCaps(c, a);
        return true;
    }
    if (eq(cmd, "tpl-pick")) {
        try tplPick(c, a);
        return true;
    }
    return false;
}
