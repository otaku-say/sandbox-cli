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

/// tpl-caps [<模板ID>] [--probe] [--prune] [--json]
/// 静态推断（亚秒级）或真机探测（--probe，建临时沙箱打真实端点）模板能力画像。
fn tplCaps(c: *Ctx, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, 2 << 20);
    const list = try fetchTemplates(c);

    // --prune：清理平台已不存在的模板条目
    if (a.has("prune")) {
        if (loadCache(c)) |cv0| {
            var stale = try c.arena.alloc([]const u8, 128);
            var ns: usize = 0;
            var it = cv0.object.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                var found = false;
                for (list) |t| {
                    if (std.mem.eql(u8, t.templateID, k)) {
                        found = true;
                        break;
                    }
                }
                if (!found and ns < stale.len) {
                    stale[ns] = k;
                    ns += 1;
                }
            }
            var cv_mut = cv0;
            for (stale[0..ns]) |k| {
                _ = cv_mut.object.swapRemove(k);
            }
            try saveCache(c, &cv_mut.object);
            std.debug.print("[caps] 已清理 {d} 个条目（当前模板 {d} 个）\n", .{ ns, list.len });
        } else {
            std.debug.print("[caps] 无缓存文件，无需清理\n", .{});
        }
    }

    // --probe：真机探测（无参=探所有无缓存的 READY；给 ID=只探它）
    if (a.has("probe")) {
        var cv_opt = loadCache(c);
        if (cv_opt == null) {
            const p = try std.json.parseFromSlice(std.json.Value, c.arena, "{}", .{});
            cv_opt = p.value;
        }
        var cv = cv_opt.?;
        const target = a.at(0);
        for (list) |t| {
            if (!std.mem.eql(u8, t.status, "READY")) continue;
            if (target) |tid| {
                if (!std.mem.eql(u8, t.templateID, tid) and std.mem.indexOf(u8, t.templateID, tid) == null) continue;
            } else if (cv.object.get(t.templateID) != null) {
                continue; // 已有缓存：跳过（要重探请显式给模板 ID）
            }
            std.debug.print("[caps] 探测 {s} …\n", .{t.templateID});
            const pr = probeTemplate(c, t.templateID) catch |e| {
                std.debug.print("[caps] {s} 探测失败: {t}\n", .{ t.templateID, e });
                continue;
            };
            var ent = std.Io.Writer.fixed(try c.arena.alloc(u8, 8 << 10));
            try ent.print("{{\"caps\":\"{s}\",\"gw\":{d},\"templateAt\":\"{s}\"}}", .{
                try envd.jsonEscape(c.arena, pr.caps), pr.gw, try envd.jsonEscape(c.arena, t.createdAt),
            });
            const ev = (try std.json.parseFromSlice(std.json.Value, c.arena, ent.buffered(), .{})).value;
            try cv.object.put(c.arena, t.templateID, ev);
            try saveCache(c, &cv.object);
            std.debug.print("[caps] {s} → {s}（网关 {d}）\n", .{ t.templateID, pr.caps, pr.gw });
        }
    }

    // 表格（静态推断 + 探测缓存合并）
    const cache_v = loadCache(c);
    try c.out.print("{s:<34} {s:<28} {s:<6} {s:<7} {s}\n", .{ "模板ID", "能力", "网关", "来源", "端口" });
    for (list) |t| {
        const ports = try detailPorts(c, t.templateID, buf);
        var caps = try capsFromStatic(c.arena, ports, t.imageInfo);
        var gw = guessGateway(ports, t.imageInfo);
        var source: []const u8 = "static";
        if (cache_v) |cv| {
            if (cv.object.get(t.templateID)) |ent| {
                if (ceStr(ent, "templateAt")) |ta| {
                    if (std.mem.eql(u8, ta, t.createdAt)) {
                        if (ceStr(ent, "caps")) |cc| caps = cc;
                        if (ceNum(ent, "gw")) |g2| gw = g2;
                        source = "probe";
                    }
                }
            }
        }
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
        try c.out.print("{s:<34} {s:<28} {s:<6} {s:<7} {s}\n", .{ t.templateID, caps, gws, source, pbuf[0..pn] });
    }
}


/// 选型结果：模板 ID + 能力 + 网关端口
pub const Picked = struct { id: []const u8, caps: []const u8, gw: u16 };

/// 按能力挑模板（能力覆盖 + 更薄者优先）—— tpl-pick 与 new --need 共用。
/// 探测缓存（templateAt 匹配）优先于静态推断。
pub fn pickByNeed(c: *Ctx, need: []const u8) !Picked {
    const buf = try c.arena.alloc(u8, 2 << 20);
    const list = try fetchTemplates(c);
    const cache_v = loadCache(c);
    var best: ?Picked = null;
    for (list) |t| {
        if (!std.mem.eql(u8, t.status, "READY")) continue;
        var caps: []const u8 = undefined;
        var gw: u16 = 0;
        var from_cache = false;
        if (cache_v) |cv| {
            if (cv.object.get(t.templateID)) |ent| {
                if (ceStr(ent, "templateAt")) |ta| {
                    if (std.mem.eql(u8, ta, t.createdAt)) {
                        if (ceStr(ent, "caps")) |cc| {
                            caps = cc;
                            gw = ceNum(ent, "gw") orelse 0;
                            from_cache = true;
                        }
                    }
                }
            }
        }
        if (!from_cache) {
            const ports = try detailPorts(c, t.templateID, buf);
            caps = try capsFromStatic(c.arena, ports, t.imageInfo);
            gw = guessGateway(ports, t.imageInfo);
        }
        if (!covers(caps, need)) continue;
        if (best == null or caps.len < best.?.caps.len) {
            best = .{ .id = t.templateID, .caps = caps, .gw = gw };
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

// ---------------- caps 缓存（~/.cube-cli-caps.json） ----------------

fn cachePath(c: *Ctx) ![]const u8 {
    const home_z = std.c.getenv("HOME") orelse return "";
    return std.fmt.allocPrint(c.arena, "{s}/.cube-cli-caps.json", .{std.mem.span(home_z)});
}

/// 读取缓存；null = 无文件 / 解析失败（返回的 Value 借用 arena）。
fn loadCache(c: *Ctx) ?std.json.Value {
    const p = cachePath(c) catch return null;
    if (p.len == 0) return null;
    const data = std.Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .limited(4 << 20)) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, data, .{}) catch return null;
    if (parsed.value != .object) return null;
    return parsed.value;
}

fn saveCache(c: *Ctx, obj: *std.json.ObjectMap) !void {
    const p = try cachePath(c);
    if (p.len == 0) return;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 256 << 10));
    try w.writeAll("{");
    var first = true;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"{s}\":", .{try envd.jsonEscape(c.arena, e.key_ptr.*)});
        try std.json.Stringify.value(e.value_ptr.*, .{}, &w);
    }
    try w.writeAll("}");
    const f = try std.Io.Dir.cwd().createFile(c.io, p, .{});
    defer f.close(c.io);
    var fbuf: [4096]u8 = undefined;
    var fw = f.writer(c.io, &fbuf);
    try fw.interface.writeAll(w.buffered());
    try fw.interface.flush();
}

fn ceStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    return f.string;
}

fn ceNum(v: std.json.Value, key: []const u8) ?u16 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .integer) return null;
    return std.math.cast(u16, f.integer) orelse null;
}

// ---------------- 真机探测 ----------------

fn sleepMs(c: *Ctx, ms: i96) void {
    std.Io.sleep(c.io, .{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
}

/// 在探测沙箱里跑命令，返回 stdout（失败给空串）。
fn execProbe(c: *Ctx, sid: []const u8, cmd: []const u8) []const u8 {
    const buf = c.arena.alloc(u8, 1 << 20) catch return "";
    const token = c.connectToken(sid, buf) catch return "";
    const envd_base = c.envdBase(sid) catch return "";
    const res = envd.exec(c.arena, c.client, envd_base, token, null, cmd, null, null, 30_000, buf) catch return "";
    return res.stdout;
}

const ProbeOut = struct { caps: []const u8, gw: u16 };

/// 真机探测一个模板：建临时沙箱 → 打真实端点 → 销毁。
fn probeTemplate(c: *Ctx, tpl_id: []const u8) !ProbeOut {
    const body = try std.fmt.allocPrint(c.arena, "{{\"templateID\":\"{s}\",\"timeout\":300}}", .{tpl_id});
    const buf = try c.arena.alloc(u8, 2 << 20);
    const res = try c.control(.POST, "/sandboxes", body, buf);
    const sid = envd.extractString(c.arena, res.body, "sandboxID") orelse {
        try c.out.print("探测沙箱创建失败: {s}\n", .{res.body});
        return error.NoSandbox;
    };
    const kill_path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}", .{sid});
    defer {
        _ = c.control(.DELETE, kill_path, null, buf) catch {};
    }
    std.debug.print("[caps] 探测沙箱 {s} 已创建（envd 预热中…）\n", .{sid});

    // 等 envd 204（最多 60s）
    var envd_ok = false;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const out = execProbe(c, sid, "curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:49983/health");
        if (std.mem.indexOf(u8, out, "204") != null) {
            envd_ok = true;
            break;
        }
        sleepMs(c, 2000);
    }
    if (!envd_ok) {
        std.debug.print("[caps] envd 60s 未就绪，放弃\n", .{});
        return error.Timeout;
    }

    // 画像：aiod / chrome / X11
    const prof_cmd =
        "if command -v aiod >/dev/null 2>&1 || ls /usr/local/bin/aiod /opt/*/aiod >/dev/null 2>&1; then echo AIOD=1; else echo AIOD=0; fi\n" ++
        "if command -v google-chrome >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then echo CHROME=1; else echo CHROME=0; fi\n" ++
        "if command -v Xvfb >/dev/null 2>&1 || command -v Xvnc >/dev/null 2>&1 || command -v x11vnc >/dev/null 2>&1 || command -v xfce4-session >/dev/null 2>&1 || command -v startxfce4 >/dev/null 2>&1; then echo X11=1; else echo X11=0; fi";
    const pout = execProbe(c, sid, prof_cmd);
    const has_aiod = std.mem.indexOf(u8, pout, "AIOD=1") != null;
    const has_chrome = std.mem.indexOf(u8, pout, "CHROME=1") != null;
    const has_x11 = std.mem.indexOf(u8, pout, "X11=1") != null;

    var caps: []const u8 = CAP_BASE;
    if (!has_aiod) return .{ .caps = caps, .gw = 0 };

    // 网关端口（8080 / 18091）
    var gw: u16 = 0;
    var j: usize = 0;
    while (j < 20) : (j += 1) {
        const out = execProbe(c, sid, "for p in 8080 18091; do c=$(curl -s -o /dev/null -w \"%{http_code}\" --max-time 2 http://127.0.0.1:$p/health); [ \"$c\" = \"200\" ] && { echo \"GW=$p\"; break; }; done");
        if (std.mem.indexOf(u8, out, "GW=")) |gi| {
            const s2 = out[gi + 3 ..];
            var e: usize = 0;
            while (e < s2.len and s2[e] >= '0' and s2[e] <= '9') : (e += 1) {}
            gw = std.fmt.parseInt(u16, s2[0..e], 10) catch 0;
        }
        if (gw > 0) break;
        sleepMs(c, 3000);
    }
    if (gw == 0) {
        std.debug.print("[caps] 有 aiod 但网关未就绪，按基线记\n", .{});
        return .{ .caps = caps, .gw = 0 };
    }

    // browser（/v2/browser/screenshot == 200）
    if (has_chrome) {
        var launched = false;
        var k: usize = 0;
        while (k < 18) : (k += 1) {
            const code = execProbe(c, sid, try std.fmt.allocPrint(c.arena, "curl -s -o /dev/null -w \"%{{http_code}}\" --max-time 5 http://127.0.0.1:{d}/v2/browser/screenshot", .{gw}));
            if (std.mem.indexOf(u8, code, "200") != null) {
                caps = try std.fmt.allocPrint(c.arena, "{s},browser", .{caps});
                break;
            }
            if (!launched and k >= 4) {
                launched = true;
                _ = execProbe(c, sid, "test -x /opt/gem/browser-launch.sh && /opt/gem/browser-launch.sh >/dev/null 2>&1; echo done");
            }
            sleepMs(c, 5000);
        }
    }
    // desktop（/v2/computer/info == 200）
    if (has_x11) {
        var k: usize = 0;
        while (k < 9) : (k += 1) {
            const code = execProbe(c, sid, try std.fmt.allocPrint(c.arena, "curl -s -o /dev/null -w \"%{{http_code}}\" --max-time 5 http://127.0.0.1:{d}/v2/computer/info", .{gw}));
            if (std.mem.indexOf(u8, code, "200") != null) {
                caps = try std.fmt.allocPrint(c.arena, "{s},desktop", .{caps});
                break;
            }
            sleepMs(c, 5000);
        }
    }
    return .{ .caps = caps, .gw = gw };
}

/// tpl-info <模板ID> [--json]：模板详情摘要（--json 原样输出）。
fn tplInfo(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, 2 << 20);
    const path = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{id});
    const res = try c.control(.GET, path, null, buf);
    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    const st = envd.extractString(c.arena, res.body, "status") orelse "?";
    const img = envd.extractString(c.arena, res.body, "imageInfo") orelse "?";
    const created = envd.extractString(c.arena, res.body, "createdAt") orelse "?";
    const ports = envd.extractString(c.arena, res.body, "com.exposed_ports") orelse "-";
    try c.out.print("模板ID   : {s}\n", .{id});
    try c.out.print("状态     : {s}\n", .{st});
    try c.out.print("镜像     : {s}\n", .{img});
    try c.out.print("创建时间 : {s}\n", .{created});
    try c.out.print("暴露端口 : {s}\n", .{ports});
    const ps = parsePorts(c.arena, ports) catch &.{};
    try c.out.print("网关推断 : {d}\n", .{guessGateway(ps, img)});
}

/// tpl-logs <模板ID> <buildID>：模板构建日志。
fn tplLogs(c: *Ctx, a: util.Args) !void {
    const tid = a.at(0) orelse return error.MissingArg;
    const bid = a.at(1) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, 8 << 20);
    const path = try std.fmt.allocPrint(c.arena, "/templates/{s}/builds/{s}/logs", .{ tid, bid });
    const res = try c.control(.GET, path, null, buf);
    try c.out.print("{s}\n", .{res.body});
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
    if (eq(cmd, "tpl-info")) {
        try tplInfo(c, a);
        return true;
    }
    if (eq(cmd, "tpl-logs")) {
        try tplLogs(c, a);
        return true;
    }
    return false;
}
