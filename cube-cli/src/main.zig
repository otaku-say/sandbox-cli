//! cube-cli â€”â€” CubeSandbox æ§åˆ¶é¢ CLIï¼ˆZigï¼‰
//!
//! çº¦å®šï¼šæ‰€æœ‰éƒ¨ç½²å–å€¼ä»ç¯å¢ƒå˜é‡è¯»å–ï¼Œæºç å†…ä¸å«ä»»ä½•çœŸå®ä¸»æœºå / IP / å‡­æ®ã€‚
//!   CUBESANDBOX_API_URL    æ§åˆ¶é¢åœ°å€
//!   CUBESANDBOX_API_KEY    æ§åˆ¶é¢ API Key
//!   CUBESANDBOX_PROXY_URL  æ•°æ®é¢ç½‘å…³ï¼ˆexec ç­‰æ²™ç®±å†…æ“ä½œéœ€è¦ï¼‰
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
const cmd_proc = @import("cmd_proc.zig");
const cmd_pty = @import("cmd_pty.zig");
const cmd_mcp = @import("cmd_mcp.zig");

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

    var arg_storage: [256][]const u8 = undefined;
    var arg_count: usize = 0;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |a| {
        if (arg_count == arg_storage.len) break;
        arg_storage[arg_count] = a;
        arg_count += 1;
    }
    const argv: []const []const u8 = arg_storage[0..arg_count];
    if (argv.len < 2) {
        try help.printTop(out);
        return;
    }
    const cmd = argv[1];
    const args = argv[2..];

    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try help.printVersion(out);
        return;
    }

    // ---- å¸®åŠ©ä½“ç³»ï¼ˆå¿…é¡»åœ¨ä»»ä½• dispatch ä¹‹å‰æ‹¦æˆªï¼š--help ç»ä¸è§¦å‘çœŸå®æ“ä½œï¼‰----
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
        // å…è®¸ä¸ºç©ºï¼štpl-from-image ç­‰ç¦»çº¿å‘½ä»¤ä¸éœ€è¦æ§åˆ¶é¢ï¼›å®é™…ä½¿ç”¨æ—¶æŠ¥é”™ï¼ˆè§ ctx.controlï¼‰
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
    // ---- P0 æ–°å¢ï¼ˆç”¨æ³•è¯´æ˜è§å„å‘½ä»¤æ–‡ä»¶çš„ pub const helpï¼‰----
    if (try cmd_info.dispatch(&ctx, cmd, args)) return;
    if (try cmd_logs.dispatch(&ctx, cmd, args)) return;
    if (try cmd_raw.dispatch(&ctx, cmd, args)) return;
    if (try cmd_connect.dispatch(&ctx, cmd, args)) return;
    // ---- ç¬¬äºŒæ‰¹ï¼ˆSDK å…¨é‡å¯¹é½ï¼‰ï¼šå¼‚æ­¥æ‰§è¡Œæ— / PTY åŸè¯­ ----
    if (try cmd_proc.dispatch(&ctx, cmd, args)) return;
    if (try cmd_pty.dispatch(&ctx, cmd, args)) return;
    if (try cmd_mcp.dispatch(&ctx, cmd, args)) return;

    try help.printUnknown(out, cmd);
    exitWith(out, 1);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// æ‰“å°å®Œç«‹å³ä»¥æŒ‡å®šç é€€å‡ºï¼ˆprocess.exit ä¸è·‘ deferï¼Œæ‰€ä»¥å…ˆ flushï¼‰ã€‚
fn exitWith(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

// health / ls / rm å·²ç§»åˆ°ç‹¬ç«‹æ¨¡å—ï¼ˆcmd_health.zig / cmd_ls.zig / cmd_rm.zigï¼‰ï¼Œ
// ç”¨æ³•è¯´æ˜è§å„è‡ªçš„ `pub const help`ï¼›main.zig è¿™é‡Œåªä¿ç•™ dispatch æ¥çº¿ã€‚

fn cmdNew(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    // --template ä¼˜å…ˆï¼›æ²¡æœ‰åˆ™æŒ‰ --need åŠ¨æ€æŒ‘ï¼ˆä¸ tpl-pick åŒä¸€é€»è¾‘ï¼‰
    var tpl: []const u8 = "";
    if (a.get("template")) |t| {
        // å…ˆæŸ¥æœåŠ¡ç«¯åˆ«åï¼ˆGET /templates/aliases/{å}ï¼‰ï¼›å¤±è´¥å†é€€å›æœ¬åœ°åŒ¹é…
        // ï¼ˆæ¨¡æ¿ ID å…¨ç­‰ / åˆ«å / imageInfo å­ä¸²å”¯ä¸€å‘½ä¸­ï¼‰ï¼›éƒ½æœªå‘½ä¸­å°±åŸæ ·äº¤ç»™æœåŠ¡ç«¯ã€‚
        if (cmd_template.resolveTemplateRef(c, t)) |id| {
            tpl = id;
            std.debug.print("[template] {s} â†’ {s}\n", .{ t, id });
        } else {
            tpl = t;
        }
    } else {
        // é»˜è®¤ --need=codeï¼ˆaio-code æ²™ç®±ï¼šä¸éœ€è¦æµè§ˆå™¨æ—¶çš„ä¸€å¾‹é€‰æ‹©ï¼›
        // éœ€è¦æµè§ˆå™¨/æ¡Œé¢æ—¶æ˜¾å¼ç»™ --need=browser|desktopï¼‰
        const need = a.get("need") orelse "code";
        const p = cmd_template.pickByNeed(c, need) catch {
            try c.out.print("æ²¡æœ‰æ»¡è¶³ --need={s} çš„ READY æ¨¡æ¿\n", .{need});
            return error.NotFound;
        };
        tpl = p.id;
        std.debug.print("[template] --need={s} â†’ {s}\n", .{ need, p.id });
    }

    var timeout_part: []const u8 = "";
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(i64, t, 10)) |n| {
            timeout_part = try std.fmt.allocPrint(c.arena, ",\"timeout\":{d}", .{n});
        } else |_| {}
    }
    const meta_part = try buildMetadata(c, a);
    const extra_part = try buildCreateExtras(c, a);
    const payload = try std.fmt.allocPrint(c.arena, "{{\"templateID\":\"{s}\"{s}{s}{s}}}", .{ tpl, timeout_part, meta_part, extra_part });

    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.POST, "/sandboxes", payload, buf);
    const sid = envd.extractString(c.arena, res.body, "sandboxID") orelse {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    try c.out.print("{s}\n", .{sid});

    // æç¤ºç½‘å…³ä¸ç«¯ç‚¹ï¼ˆæŸ¥æ¨¡æ¿è¯¦æƒ…æ‹¿ç«¯å£ï¼Œæ¨æ–­ aiod ç½‘å…³ï¼‰
    const detail_path = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{tpl});
    const dres = c.control(.GET, detail_path, null, buf) catch return;
    const raw_ports = envd.extractString(c.arena, dres.body, "com.exposed_ports") orelse return;
    const ports = cmd_template.parsePorts(c.arena, raw_ports) catch return;
    const gw = cmd_template.guessGateway(ports, "");
    if (gw == 0) return;
    const proxy = cfg.proxyURL() orelse return;
    const base = try std.fmt.allocPrint(c.arena, "{s}/sandbox/{s}", .{ ctxmod.trimSlash(proxy), sid });
    std.debug.print("[sandbox] AIO ç½‘å…³: {s}/{d}/   â† aiod-cli çš„ SANDBOX_BASE\n", .{ base, gw });
    std.debug.print("[sandbox] envd    : {s}/49983/\n", .{base});
}

/// code <sid> <ä»£ç ...> [--mode=interp|kernel] [--lang=python|js|bash] [--timeout=ç§’] [--env=...] [--user=]
/// interpï¼ˆé»˜è®¤ï¼‰ï¼šç­‰ä»· exec python3 -c ...ï¼ˆä¸ä¾èµ–è§£é‡Šå™¨æœåŠ¡ï¼Œä»»ä½•é•œåƒå¯ç”¨ï¼‰ã€‚
/// kernelï¼šSDK run_code çš„é€šé“ â€”â€” POST <proxy>/sandbox/<sid>/49999/executeï¼ˆndjsonï¼‰ã€‚
fn cmdCode(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    if (a.pos.len < 2) return error.MissingArg;
    const sid = a.pos[0];
    const src = a.joinFrom(1, " ");
    const lang = a.get("lang") orelse "python";
    const envs_json = try util.envsJson(c.arena, a.flags);
    var timeout_ms: u64 = 0;
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(u64, t, 10)) |n| timeout_ms = n * 1000 else |_| {}
    }

    if (a.get("mode")) |m| {
        if (util.eq(m, "kernel")) {
            return cmd_proc.kernelRun(c, sid, src, a.get("lang"), envs_json, timeout_ms);
        }
        if (!util.eq(m, "interp")) {
            try c.out.print("ä¸æ”¯æŒçš„æ¨¡å¼: {s}ï¼ˆå¯é€‰ interp / kernelï¼‰\n", .{m});
            return error.BadArg;
        }
    }

    const q = try util.shellQuote(c.arena, src);
    const cmd = if (eq(lang, "python") or eq(lang, "python3"))
        try std.fmt.allocPrint(c.arena, "python3 -c {s}", .{q})
    else if (eq(lang, "js") or eq(lang, "javascript") or eq(lang, "node") or eq(lang, "nodejs"))
        try std.fmt.allocPrint(c.arena, "node -e {s}", .{q})
    else if (eq(lang, "bash") or eq(lang, "sh") or eq(lang, "shell")
        try std.fmt.allocPrint(c.arena, "bash -c {s}", .{q})
    else {
        try c.out.print("ä¸æ”¯æŒçš„è¯­è¨€: {s}ï¼ˆå¯é€‰ python / js / bashï¼‰\n", .{lang});
        return error.BadLang;
    };
    try runInSandbox(c, sid, cmd, null, if (envs_json.len > 0) envs_json else null, timeout_ms, a.get("user"));
}

/// åœ¨æ²™ç®±é‡Œè·‘å‘½ä»¤å¹¶æ‰“å°ç»“æœï¼ˆè¿§æ¥ envd â†’ æ‰§è¡Œ â†’ è¾“å‡º stdout/stderr/exitï¼‰ã€‚
fn runInSandbox(c: *Ctx, sid: []const u8, command: []const u8, cwd: ?[]const u8, envs_json: ?[]const u8, timeout_ms: u64, user: ?[]const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const envd_base = try c.envdBase(sid);
    const res = try envd.exec(c.arena, c.client, envd_base, token, user, command, cwd, envs_json, timeout_ms, buf);
    if (res.stdout.len > 0) try c.out.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) try c.out.print("{s}", .{res.stderr});
    if (res.exit_code != 0) try c.out.print("ï¼ˆexit {d}ï¼‰\n", .{res.exit_code});
}

/// exec <sid> <å‘½ä»¤...> [--cwd=] [--env=NAME|K=V] [--timeout=ç§’] [--user=ç”¨æˆ·]
fn cmdExec(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    if (a.pos.len < 2) return error.MissingArg;
    const sid = a.pos[0];
    var command: []const u8 = "";

    // æ”¯æŒä½ç½®å‚æ•°ä¸º "-" æ—¶ä»æ ‡å‡†è¾“å…¥è¯»å–å®Œæ•´å‘½ä»¤ï¼ˆé¿å…å¤æ‚å¼•å·/JSONåµŒå¥—è¢«å¤–å±‚ shell å‰¥ç¦»ï¼‰
    if (a.pos.len == 2 and std.mem.eql(u8, a.pos[1], "-")) {
        const stdin_buf = try c.arena.alloc(u8, BUF);
        var rbuf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().reader(c.io, &rbuf);
        var total: usize = 0;
        while (total < stdin_buf.len) {
            const n = r.interface.readSliceShort(stdin_buf[total..]) catch break;
            if (n == 0) break;
            total += ¸ì(€€€€€€€ô(€€€€€€€½µµ…¹€ôÍÑ¹µ•´¹ÑÉ¥´¡Ôà°ÍÑ‘¥¹}‰Õ™lÀ¸¹Ñ½Ñ…±t°€€ˆqÉq¹qĞˆ¤ì(€€€ô•±Í”ì(€€€€€€€¥˜€¡„¹Á½Ì¹±•¸€ôô€È¤ì(€€€€€€€½µµ…¹€ô„¹Á½ÍlÅtì(€€€ô•±Í”ì(€€€€€€€Ù…ÈÜ€ôÍÑ¹%¼¹]É¥Ñ•È¹™¥á•¡ÑÉäŒ¹…É•¹„¹…±±½Œ¡Ôà°€ØĞ€ğğ€ÄÀ¤¤ì(€€€€€€€™½È€¡„¹Á½ÍlÄ¸¹t°€À¸¸¤ñÀ°¥ğì(€€€€€€€€€€€¥˜€¡¤€ø€À¤ÑÉäÜ¹ÁÉ¥¹Ğ ˆ€ˆ°€¹íô¤ì(€€€€€€€€€€€€¼¼ƒ–ššzs–>šVÃ––B¯¦ëš‚ó–"–>ß–6W–>3–òW–>ßš"[š.³–>ß¾ò3’öÿR Í¡•±±EÕ½Ñ”ƒ’şwš*(€€€€€€€€€€€¥˜€¡ÍÑ¹µ•´¹¥¹‘•á=™¹ä¡Ôà°À°€ˆ€ìpˆ ¤‘ğ˜ğø¨ıù€ˆ¤€„ô¹Õ±°½ÈÍÑ¹µ•´¹¥¹‘•á=™M…±…È¡Ôà°À°€qĞœ¤€„ô¹Õ±°¤ì(€€€€€€€€€€€€€€€½¹ÍĞÄ€ôÑÉäÕÑ¥°¹Í¡•±±EÕ½Ñ”¡Œ¹…É•¹„°À¤ì(€€€€€€€€€€€€€€€ÑÉäÜ¹ÁÉ¥¹Ğ ‰íÍôˆ°€¹íÅô¤ì(€€€€€€€€€€€ô•±Í”ì(€€€€€€€€€€€€€€€ÑÉäÜ¹ÁÉ¥¹Ğ ‰íÍôˆ°€¹íÁô¤ì(€€€€€€€€€€€ô(€€€€€€€ô(€€€€€€€½µµ…¹€ôÜ¹‰Õ™™•É• ¤ì(€€€ô(€€€ô((€€€€¼¼ƒ:¿–Š–>c¦?šÎ£–—¾òh´µ•¹Øõ,õXƒnÓš:—îg–ó¾òl´µ•¹Øõ95ƒ’î;šr³šrë:¿–Š¢¾ï–B3–B7–>c¦<(€€€€¼¼ƒ¾ò#šV?š–ó’â7–ş–ë:Ã–r£–F÷’î“¢†0€¼ƒ¢şo¢/–"_¢†£¦3¾ò$(€€€½¹ÍĞ•¹ÙÍ}©Í½¸€ôÑÉäÕÑ¥°¹•¹ÙÍ)Í½¸¡Œ¹…É•¹„°„¹™±…Ì¤ì((€€€½¹ÍĞ‰Õ˜€ôÑÉäŒ¹…É•¹„¹…±±½Œ¡Ôà°	U¤ì(€€€½¹ÍĞÑ½­•¸€ôÑÉäŒ¹½¹¹•ÑQ½­•¸¡Í¥°‰Õ˜¤ì(€€€½¹ÍĞ•¹Ù‘}‰…Í”€ôÑÉäŒ¹•¹Ù‘	…Í”¡Í¥¤ì((€€€€¼¼ƒ’â8M,ƒ–¾ç¦öC¾òkòër’â7¢ºûš"«š¶‹¾ò!ÉÕ¸¡Ñ¥µ•½ÕĞõ9½¹”¤ƒŠHƒ’â7–>D½¹¹•ĞµQ¥µ•½ÕĞµ5Ï¾ò'¾òl(€€€€¼¼ƒšbû–ò<€´µÑ¥µ•½ÕĞ÷Hƒš&7’ös’âè•¹Ùƒ’úŸ†³š"«š¶‹(€€€Ù…ÈÑ¥µ•½ÕÑ}µÌèÔØĞ€ô€Àì(€€€¥˜€¡„¹•Ğ ‰Ñ¥µ•½ÕĞˆ¤¤ñÑğì(€€€€€€€¥˜€¡ÍÑ¹™µĞ¹Á…ÉÍ•%¹Ğ¡ÔØĞ°Ğ°€ÄÀ¤¤ñ¹ğÑ¥µ•½ÕÑ}µÌ€ô¸€¨€ÄÀÀÀ•±Í”ñ}ğíô(€€€ô((€€€½¹ÍĞÉ•Ì€ôÑÉä•¹Ù¹•á•Œ¡Œ¹…É•¹„°Œ¹±¥•¹Ğ°•¹Ù‘}‰…Í”°Ñ½­•¸°„¹•Ğ ‰ÕÍ•Èˆ¤°½µµ…¹°„¹•Ğ ‰İˆ¤°¥˜€¡•¹ÙÍ}©Í½¸¹±•¸€ø€À¤•¹ÙÍ}©Í½¸•±Í”¹Õ±°°Ñ¥µ•½ÕÑ}µÌ°‰Õ˜¤ì(€€€¥˜€¡É•Ì¹ÍÑ‘½ÕĞ¹±•¸€ø€À¤ÑÉäŒ¹½ÕĞ¹ÁÉ¥¹Ğ ‰íÍôˆ°€¹íÉ•Ì¹ÍÑ‘½ÕÑô¤ì(€€€¥˜€¡É•Ì¹ÍÑ‘•ÉÈ¹±•¸€ø€À¤ÑÉäŒ¹½ÕĞ¹ÁÉ¥¹Ğ ‰íÍôˆ°€¹íÉ•Ì¹ÍÑ‘•ÉÉô¤ì(€€€¥˜€¡É•Ì¹•á¥Ñ}½‘”€„ô€À¤ÑÉäŒ¹½ÕĞ¹ÁÉ¥¹Ğ ‹¾ò!•á¥Ğí‘÷¾ò%q¸ˆ°€¹íÉ•Ì¹•á¥Ñ}½‘•ô¤ì)ô((¼¼¼¹•Üƒj–>¿¦'š&§–ÆW–¶_šº×¾ò#–¾ç¦ö@M,M…¹‘‰½à¹É•…Ñ”ƒj–>¿¦'–>šVÃ¾ò'¾òh(¼¼¼€€€´µ•¹Øõ,õ[¾ò#–>¿¦7–’7¾ò$€€€€€€€€€ƒŠH•¹ÙY…ÉÏ¾ò#¢şo¢/šÎ£–—¾ò$(¼¼¼€€€´µÙ½±Õµ”÷–6ß–B5lëš2¢ö÷¢Ş¿–út€€€€€ƒŠHÙ½±Õµ•5½Õ¹ÑÏ¾ò#¢Ş¿–úòër€½µ¹Ğ¼ó–6ß–B4û¾ò$(¼¼¼€€€´µ±¥™•å±”õ­¥±±ñÁ…ÕÍ”€€€€€€ƒŠH±¥™•å±”¹½¹Q¥µ•½ÕÓ¾ò!Á…ÕÍ”€ôƒ¦ë¦^Ëš2¢Öß¾ò$(¼¼¼€€€´µ…ÕÑ¼µÉ•ÍÕµ”€€€€€€€€€€€€€€€ƒŠH±¥™•å±”¹…ÕÑ½I•ÍÕµ”õÑÉÕ—¾ò#¦7–B Á…ÕÍ—¾ò$(¼¼¼€€€´µ¹¼µ¥¹Ñ•É¹•Ğ€€€€€€€€€€€€€€€ƒŠH…±±½İ}¥¹Ñ•É¹•Ñ}…•ÍÍpˆé™…±Í”ˆ°€¹í½ÕÑô¤ì(€€€¥˜€¡„¹•Ğ ‰‘¥ÍÑÉ¥‰ÕÑ¥½¸µÍ½Á”ˆ¤¤ñÍğì(€€€€€€€Ù…È±¥ÍĞèmu½¹ÍĞÔà€ô€ˆˆì(€€€€€€€Ù…È¥Ğ€ôÍÑ¹µ•´¹Ñ½­•¹¥é•M…±…È¡Ôà°ÍŒ°€œ°œ¤ì(€€€€€€€Ù…È˜€ôÑÉÕ”ì(€€€€€€€İ¡¥±”€¡¥Ğ¹¹•áĞ ¤¤ñÑ½­ğì(€€€€€€€€€€€±¥ÍĞ€ôÑÉäÍÑ¹™µĞ¹…±±½AÉ¥¹Ğ¡Œ¹…É•¹„°€‰íÍõíÍõp‰íÍõpˆˆ°€¹ì±¥ÍĞ°¥˜€¡˜¤€ˆˆ•±Í”€ˆ°ˆ°ÑÉä•¹Ù¹©Í½¹Í…Á”¡Œ¹…É•¹„°Ñ½¬¤ô¤ì(€€€€€€€€€€€˜€ô™…±Í”ì(€€€€€€€ô(€€€€€€€½ÕĞ€ôÑÉäÍÑ¹™µĞ¹…±±½AÉ¥¹Ğ¡Œ¹…É•¹„°€‰íÍô±p‰‘¥ÍÑÉ¥‰ÕÑ¥½¹M½Á•pˆémíÍõtˆ°€¹ì½ÕĞ°±¥ÍĞô¤ì(€€€ô(€€€¥˜€¡„¹•Ğ ‰µÀˆ¤¤ñµÁğì(€€€€€€€€¼¼€´µµÀôñ)M=8û¾òiÉƒ–ó–ºçj5@ƒšr7–*‡¦7ö»¦?’òƒ–"ÀA=MP€½Í…¹‘‰½á•Ì(€€€€€€€½ÕĞ€ôÑÉäÍÑ¹™µĞ¹…±±½AÉ¥¹Ğ¡Œ¹…É•¹„°€‰íÍô±p‰µÁpˆéíÍôˆ°€¹ì½ÕĞ°µÀô¤ì(€€€ô(€€€É•ÑÕÉ¸½ÕĞì)ô((¼¼¼ƒ¢ş÷–*ƒ’â’â¨µ•Ñ…‘…Ñ„ƒ¦R»–ó¾ò!½µµ„õÑÉÕ”ƒš^Û–&7¦v‹¢†—¦_–>ß¾ò$)™¸…‘‘-X¡Œè€©Ñà°½ÕĞèmu½¹ÍĞÔà°¬èmu½¹ÍĞÔà°Øèmu½¹ÍĞÔà°½µµ„è‰½½°¤€…mu½¹ÍĞÔàì(€€€½¹ÍĞ”€ôÑÉä•¹Ù¹©Í½¹Í…Á”¡Œ¹…É•¹„°Ø¤ì(€€€É•ÑÕÉ¸ÑÉäÍÑ¹™µĞ¹…±±½AÉ¥¹Ğ¡Œ¹…É•¹„°€‰íÍõíÍõp‰íÍõpˆép‰íÍõpˆˆ°€¹ì½ÕĞ°¥˜€¡½µµ„¤€ˆ°ˆ•±Í”€ˆˆ°¬°”ô¤ì)ô(((¼¼¼ƒî¢µ•Ñ…‘…Ñ‡¾òi…•¹Ó¾ò#¢Â–òj¾ò$¼Ñ…Í¯¾ò#–k’î’æ#¾ò$¼¹½Ñ—¾ò#šbû’ë–B7¾ò$(¼¼¼ƒòër–>[:¿–Š–>c¦<U	M9	=a}9Q}95¾ò3’şw¢¾’îï’öWšÊgºÇ¦÷¢÷šê¿šêC¾òm…‘µ¥¸]•‰U$ƒ’òk¦Cšv‡šâËš~O¢şg’êo–¶_šº×)™¸‰Õ¥±‘5•Ñ…‘…Ñ„¡Œè€©Ñà°„èÕÑ¥°¹ÉÌ¤€…mu½¹ÍĞÔàì(€€€½¹ÍĞ…•¹Ğ€ô„¹•Ğ ‰…•¹Ğˆ¤½É•±Í”™œ¹•Ñ•¹Ø ‰U	M9	=a}9Q}95ˆ¤½É•±Í”€‰Õ‰”µ±¤ˆì(€€€½¹ÍĞÑ…Í¬€ô„¹•Ğ ‰Ñ…Í¬ˆ¤ì(€€€½¹ÍĞ¹½Ñ”€ô„¹•Ğ ‰¹½Ñ”ˆ¤½É•±Í”€¡¥˜€¡Ñ…Í¬¤ñÑğÑÉäÍÑ¹™µĞ¹…±±½AÉ¥¹Ğ¡Œ¹…É•¹„°€‰íÍôƒ
ÜíÍôˆ°€¹ì…•¹Ğ°Ğô¤•±Í”…•¹Ğ¤ì(€€€Ù…È½ÕĞèmu½¹ÍĞÔà€ô€ˆˆì(€€€¥˜€¡Ñ…Í¬¤ñÑğ½ÕĞ€ôÑÉä…‘‘-X¡Œ°½ÕĞ°€‰Ñ…Í¬ˆ°Ğ°™…±Í”¤ì(€€€½ÕĞ€ôÑÉä…‘‘-X¡Œ°½ÕĞ°€‰…•¹Ğˆ°…•¹Ğ°½ÕĞ¹±•¸€ø€À¤ì(€€€½ÕĞ€ôÑÉä…‘‘-X¡Œ°½ÕĞ°€‰¹½Ñ”ˆ°¹½Ñ”°ÑÉÕ”¤ì(€€€½ÕĞ€ôÑÉä…‘‘-X¡Œ°½ÕĞ°€‰±¤ˆ°€‰Õ‰”µ±¤ˆ°ÑÉÕ”¤ì(€€€É•ÑÕÉ¸ÑÉäÍÑ¹™µĞ¹…±±½AÉ¥¹Ğ¡Œ¹…É•¹„°€ˆ±p‰µ•Ñ…‘…Ñ…pˆéíííÍõõôˆ°€¹í½ÕÑô¤ì)ô(