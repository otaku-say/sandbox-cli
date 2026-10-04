//! cube-cli —— CubeSandbox 控制面 CLI（Zig）
//!
//! 约定：所有部署取值从环境变量读取，源码内不含任何真实主机名 / IP / 凭据。
//!   CUBESANDBOX_API_URL    控制面地址
//!   CUBESANDBOX_API_KEY    控制面 API Key
//!   CUBESANDBOX_PROXY_URL  数据面网关（exec 等沙箱内操作需要）
const std = @import("std");
const netfix = @import("netfix.zig");
const cfg = @import("cfg.zig");
const httpc = @import("httpc.zig");
const ctxmod = @import("ctx.zig");
const envd = @import("envd.zig");
const util = @import("util.zig");
const cmd_template = @import("cmd_template.zig");
const cmd_ports = @import("cmd_ports.zig");
const cmd_files = @import("cmd_files.zig");
const cmd_lifecycle = @import("cmd_lifecycle.zig");
const cmd_image = @import("cmd_image.zig");
const help = @import("help.zig");
const cmd_health = @import("cmd_health.zig");
const cmd_ls = @import("cmd_ls.zig");
const cmd_rm = @import("cmd_rm.zig");
const cmd_info = @import("cmd_info.zig");
const cmd_logs = @import("cmd_logs.zig");
const cmd_raw = @import("cmd_raw.zig");
const cmd_connect = @import("cmd_connect.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = netfix.install(gpa, threaded.io());

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var out_buf: [16 * 1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    const argv_raw = init.args.vector;
    if (argv_raw.len < 2) {
        try help.printTop(out);
        return;
    }
    const argv = try arena.alloc([]const u8, argv_raw.len);
    for (argv_raw, 0..) |a, i| argv[i] = std.mem.span(a);
    const cmd = argv[1];
    const args = argv[2..];

    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try help.printVersion(out);
        return;
    }

    // ---- 帮助体系（必须在任何 dispatch 之前拦截：--help 绝不触发真实操作）----
    if (help.isHelpCmd(cmd)) {
        if (args.len == 0) {
            try help.printTop(out);
            return;
        }
        const topic = args[0];
        if (eq(topic, "all")) {
            try help.printAll(out);
            return;
        }
        if (help.find(topic)) |e| {
            try help.printOne(out, e);
            return;
        }
        try help.printUnknown(out, topic);
        exitWith(out, 1);
    }
    // `<cmd> --help` / `<cmd> -h` / `<cmd> help`
    for (args) |a| {
        if (!help.isHelpArg(a)) continue;
        if (help.find(cmd)) |e| {
            try help.printOne(out, e);
            return;
        }
        try help.printUnknown(out, cmd);
        exitWith(out, 1);
    }

    var ctx: Ctx = .{
        .arena = arena,
        .client = &client,
        .out = out,
        .io = io,
        // 允许为空：tpl-from-image 等离线命令不需要控制面；实际使用时报错（见 ctx.control）
        .api = cfg.apiURL() orelse "",
        .key = cfg.apiKey(),
    };

    if (eq(cmd, "health")) return cmd_health.run(&ctx, args);
    if (eq(cmd, "new")) return cmdNew(&ctx, args);
    if (eq(cmd, "ls")) return cmd_ls.run(&ctx, args);
    if (eq(cmd, "rm")) return cmd_rm.run(&ctx, args);
    if (eq(cmd, "exec")) return cmdExec(&ctx, args);
    if (eq(cmd, "code")) return cmdCode(&ctx, args);
    if (try cmd_template.dispatch(&ctx, cmd, args)) return;
    if (try cmd_ports.dispatch(&ctx, cmd, args)) return;
    if (try cmd_files.dispatch(&ctx, cmd, args)) return;
    if (try cmd_lifecycle.dispatch(&ctx, cmd, args)) return;
    if (try cmd_image.dispatch(&ctx, cmd, args)) return;
    // ---- P0 新增（用法说明见各命令文件的 pub const help）----
    if (try cmd_info.dispatch(&ctx, cmd, args)) return;
    if (try cmd_logs.dispatch(&ctx, cmd, args)) return;
    if (try cmd_raw.dispatch(&ctx, cmd, args)) return;
    if (try cmd_connect.dispatch(&ctx, cmd, args)) return;

    try help.printUnknown(out, cmd);
    exitWith(out, 1);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 打印完立即以指定码退出（process.exit 不跑 defer，所以先 flush）。
fn exitWith(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

// health / ls / rm 已移到独立模块（cmd_health.zig / cmd_ls.zig / cmd_rm.zig），
// 用法说明见各自的 `pub const help`；main.zig 这里只保留 dispatch 接线。

fn cmdNew(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    // --template 优先；没有则按 --need 动态挑（与 tpl-pick 同一逻辑）
    var tpl: []const u8 = "";
    if (a.get("template")) |t| {
        // 先查服务端别名（GET /templates/aliases/{名}）；失败再退回本地匹配
        // （模板 ID 全等 / 别名 / imageInfo 子串唯一命中）；都未命中就原样交给服务端。
        if (cmd_template.resolveTemplateRef(c, t)) |id| {
            tpl = id;
            std.debug.print("[template] {s} → {s}\n", .{ t, id });
        } else {
            tpl = t;
        }
    } else {
        // 默认 --need=code（aio-code 沙箱：不需要浏览器时的一律选择；
        // 需要浏览器/桌面时显式给 --need=browser|desktop）
        const need = a.get("need") orelse "code";
        const p = cmd_template.pickByNeed(c, need) catch {
            try c.out.print("没有满足 --need={s} 的 READY 模板\n", .{need});
            return error.NotFound;
        };
        tpl = p.id;
        std.debug.print("[template] --need={s} → {s}\n", .{ need, p.id });
    }

    var timeout_part: []const u8 = "";
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(i64, t, 10)) |n| {
            timeout_part = try std.fmt.allocPrint(c.arena, ",\"timeout\":{d}", .{n});
        } else |_| {}
    }
    const meta_part = try buildMetadata(c, a);
    const payload = try std.fmt.allocPrint(c.arena, "{{\"templateID\":\"{s}\"{s}{s}}}", .{ tpl, timeout_part, meta_part });

    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.POST, "/sandboxes", payload, buf);
    const sid = envd.extractString(c.arena, res.body, "sandboxID") orelse {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    try c.out.print("{s}\n", .{sid});

    // 提示网关与端点（查模板详情拿端口，推断 aiod 网关）
    const detail_path = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{tpl});
    const dres = c.control(.GET, detail_path, null, buf) catch return;
    const raw_ports = envd.extractString(c.arena, dres.body, "com.exposed_ports") orelse return;
    const ports = cmd_template.parsePorts(c.arena, raw_ports) catch return;
    const gw = cmd_template.guessGateway(ports, "");
    if (gw == 0) return;
    const proxy = cfg.proxyURL() orelse return;
    const base = try std.fmt.allocPrint(c.arena, "{s}/sandbox/{s}", .{ ctxmod.trimSlash(proxy), sid });
    std.debug.print("[sandbox] AIO 网关: {s}/{d}/   ← aiod-cli 的 SANDBOX_BASE\n", .{ base, gw });
    std.debug.print("[sandbox] envd    : {s}/49983/\n", .{base});
}

/// code <sid> <代码...> [--lang=python|js|bash] [--timeout=秒] [--env=...]
/// 用解释器直接跑代码（等价 exec python3 -c ...；不依赖 Jupyter 内核，任何镜像可用）。
fn cmdCode(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    if (a.pos.len < 2) return error.MissingArg;
    const sid = a.pos[0];
    const src = a.joinFrom(1, " ");
    const lang = a.get("lang") orelse "python";
    const q = try shellQuote(c.arena, src);
    const cmd = if (eq(lang, "python") or eq(lang, "python3"))
        try std.fmt.allocPrint(c.arena, "python3 -c {s}", .{q})
    else if (eq(lang, "js") or eq(lang, "javascript") or eq(lang, "node") or eq(lang, "nodejs"))
        try std.fmt.allocPrint(c.arena, "node -e {s}", .{q})
    else if (eq(lang, "bash") or eq(lang, "sh") or eq(lang, "shell"))
        try std.fmt.allocPrint(c.arena, "bash -c {s}", .{q})
    else {
        try c.out.print("不支持的语言: {s}（可选 python / js / bash）\n", .{lang});
        return error.BadLang;
    };
    const envs_json = try envsFromFlags(c, a);
    var timeout_ms: u64 = 120_000;
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(u64, t, 10)) |n| timeout_ms = n * 1000 else |_| {}
    }
    try runInSandbox(c, sid, cmd, null, if (envs_json.len > 0) envs_json else null, timeout_ms);
}

/// 从 --env=K=V / --env=NAME 构建 envs JSON（值从本机环境读时不出现在命令行）。
fn envsFromFlags(c: *Ctx, a: util.Args) ![]const u8 {
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 32 << 10));
    var first = true;
    for (a.flags) |kv| {
        if (!std.mem.eql(u8, kv[0], "env")) continue;
        var name: []const u8 = kv[1];
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, kv[1], '=')) |i| {
            name = kv[1][0..i];
            value = kv[1][i + 1 ..];
        } else {
            const z = try c.arena.allocSentinel(u8, kv[1].len, 0);
            @memcpy(z[0..kv[1].len], kv[1]);
            const p = std.c.getenv(z.ptr) orelse continue;
            value = std.mem.span(p);
        }
        if (!first) try w.print(",", .{});
        first = false;
        try w.print("\"{s}\":\"{s}\"", .{ name, try envd.jsonEscape(c.arena, value) });
    }
    return w.buffered();
}

/// 在沙箱里跑命令并打印结果（连接 envd → 执行 → 输出 stdout/stderr/exit）。
fn runInSandbox(c: *Ctx, sid: []const u8, command: []const u8, cwd: ?[]const u8, envs_json: ?[]const u8, timeout_ms: u64) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const envd_base = try c.envdBase(sid);
    const res = try envd.exec(c.arena, c.client, envd_base, token, null, command, cwd, envs_json, timeout_ms, buf);
    if (res.stdout.len > 0) try c.out.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) try c.out.print("{s}", .{res.stderr});
    if (res.exit_code != 0) try c.out.print("（exit {d}）\n", .{res.exit_code});
}

/// POSIX 单引号转义（' → '\''）：把任意代码安全嵌入 shell 命令。
fn shellQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var cnt: usize = 2;
    for (s) |ch| {
        cnt += if (ch == '\'') 4 else 1;
    }
    const out = try arena.alloc(u8, cnt);
    var i: usize = 0;
    out[i] = '\'';
    i += 1;
    for (s) |ch| {
        if (ch == '\'') {
            @memcpy(out[i..][0..4], "'\\''");
            i += 4;
        } else {
            out[i] = ch;
            i += 1;
        }
    }
    out[i] = '\'';
    i += 1;
    return out[0..i];
}

fn cmdExec(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    if (a.pos.len < 2) return error.MissingArg;
    const sid = a.pos[0];
    const command = a.joinFrom(1, " ");

    // 环境变量注入：--env=K=V 直接给值；--env=NAME 从本机环境读同名变量
    // （对齐旧 Go 版 envpush 的用法，避免在命令行里出现明文敏感值）
    var envs_json: []const u8 = "";
    {
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 32 << 10));
        var first = true;
        for (a.flags) |kv| {
            if (!std.mem.eql(u8, kv[0], "env")) continue;
            var name: []const u8 = kv[1];
            var value: []const u8 = "";
            if (std.mem.indexOfScalar(u8, kv[1], '=')) |i| {
                name = kv[1][0..i];
                value = kv[1][i + 1 ..];
            } else {
                const z = try c.arena.allocSentinel(u8, kv[1].len, 0);
                @memcpy(z[0..kv[1].len], kv[1]);
                const p = std.c.getenv(z.ptr) orelse continue;
                value = std.mem.span(p);
            }
            if (!first) try w.print(",", .{});
            first = false;
            try w.print("\"{s}\":\"{s}\"", .{ name, try envd.jsonEscape(c.arena, value) });
        }
        envs_json = w.buffered();
    }

    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const envd_base = try c.envdBase(sid);

    var timeout_ms: u64 = 60_000;
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(u64, t, 10)) |n| timeout_ms = n * 1000 else |_| {}
    }

    const res = try envd.exec(c.arena, c.client, envd_base, token, null, command, a.get("cwd"), if (envs_json.len > 0) envs_json else null, timeout_ms, buf);
    if (res.stdout.len > 0) try c.out.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) try c.out.print("{s}", .{res.stderr});
    if (res.exit_code != 0) try c.out.print("（exit {d}）\n", .{res.exit_code});
}

/// 追加一个 metadata 键值（comma=true 时前面补逗号）
fn addKV(c: *Ctx, out: []const u8, k: []const u8, v: []const u8, comma: bool) ![]const u8 {
    const e = try envd.jsonEscape(c.arena, v);
    return try std.fmt.allocPrint(c.arena, "{s}{s}\"{s}\":\"{s}\"", .{ out, if (comma) "," else "", k, e });
}


/// 组装 metadata：agent（谁开的）/ task（做什么）/ note（显示名）
/// 缺省取环境变量 CUBESANDBOX_AGENT_NAME，保证任何沙箱都能溯源；admin WebUI 会逐条渲染这些字段。
fn buildMetadata(c: *Ctx, a: util.Args) ![]const u8 {
    const agent = a.get("agent") orelse cfg.getenv("CUBESANDBOX_AGENT_NAME") orelse "cube-cli";
    const task = a.get("task");
    const note = a.get("note") orelse (if (task) |t| try std.fmt.allocPrint(c.arena, "{s} · {s}", .{ agent, t }) else agent);
    var out: []const u8 = "";
    if (task) |t| out = try addKV(c, out, "task", t, false);
    out = try addKV(c, out, "agent", agent, out.len > 0);
    out = try addKV(c, out, "note", note, true);
    out = try addKV(c, out, "cli", "cube-cli", true);
    return try std.fmt.allocPrint(c.arena, ",\"metadata\":{{{s}}}", .{out});
}
