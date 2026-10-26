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
        try help.printUnknown(out, topic);
        exitWith(out, 1);
    }

    var ctx: Ctx = .{
        .arena = arena,
        .client = &client,
        .out = out,
        .io = io,
        // å…è®®ô¸®w¨ªú)´pl-from-image ç­‰é›»çº¿å‘½ä»¤ä¸éœ€è¦æ§åˆ¶é¢ï¼›å®é™…ä½¿ç”¨æ—¶æŠ—é”™ï¼ˆè§ ctx.controlï¼‰
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
    // ---- æ¼¬äºŒæ‰»ï¼ˆSDK å–¡ç‡å¯¹é½ï¼‰ï¼šå¼‚æ­¥æ‰§è¡Œæ—¢ / PTY åŸè¯­ ----
    if (try cmd_proc.dispatch(&ctx, cmd, args)) return;
    if (try cmd_pty.dispatch(&ctx, cmd, args)) return;
    if (try cmd_mcp.dispatch(&ctx, cmd, args)) return;

    try help.printUnknown(out, cmd);
    exitWith(out, 1);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// æ‰“å°å®Œç«‹å³ä»¥æŒ‡å®šç é€ å‡ºï¼¢process.exit ä¸è·‘ deferï¼Œæ‰€ä»¥å…‰ flushï¼‰ã€‚
fn exitWith(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

// health / ls / rm å·²çŸåˆ°ç›®ç«ºæ¨¡å—ï¼ˆcmd_health.zig / cmd_ls.zig / cmd_rm.zigï¼‰,
// ç”¨æ³•è¯´æ˜èå„æ‡y¨BV"6öç7B†VÇûÉ¶Ö–âç¦–r‹ù˜xÎXú®KùŞyY’F—7F6‚hê^{«ş8  ¦fâ6ÖDæWr†3¢¤7G‚Â&w3¢µÖ6öç7BµÖ6öç7BS‚’fö–B°¢6öç7BÒG'’WF–Âç'6R†2æ&VæÂ&w2“°¢òòÒ×FV×ÆFRKÉXXûÉ¾k*iÈX‰hÈ’ÒÖæVVBXªhhÉûÈKˆâGÂ×–6²YÎKˆ˜¾‹éûÈ¢f"GÃ¢µÖ6öç7BS‚Ò"#°¢–b†ævWB‚'FV×ÆFR"’’ÇGÂ°¢òòXXiú^iÈŞXªzºşXŠ¾YŞûÈ„tUB÷FV×ÆFW2öÆ–6W2÷¾Y×ŞûÈûÉ¾ZK‹J^XhŞ˜Y¹îiÊÎYËXË˜XĞ¢òòûÈjŠiÛò”BXZzØ’òXŠ¾YÒò–ÖvT–æfòZÙK‹.YJşKˆYŞKŠŞûÈûÉ¾˜;ŞiÊ®YŞKŠŞ[Xéşj~KªN{¹iÈŞXªzºş8 ¢–b†6ÖE÷FV×ÆFRç&W6öÇfUFV×ÆFU&Vb†2ÂB’’Æ–GÂ°¢GÂÒ–C°¢7FBæFV'Vrç&–çB‚%·FV×ÆFUÒ·7Ò(i"·7ÕÆâ"Âç²BÂ–BÒ“°¢ÒVÇ6R°¢GÂÒC°¢Ğ¢ÒVÇ6R°¢òò›¹ŠêBÒÖæVVCÖ6öF^ûÈ†–òÖ6öFRk)zëûÉ®KˆŞ™ÈŠhkXşŠxYši{ny¨NKˆ[è¾˜hºûÉ°¢òò™ÈŠhkXşŠxYš‚şjÎ™Ú.i{ni‹î[Èş{¹’ÒÖæVVCÖ'&÷w6W'ÆFW6·F÷ûÈ¢6öç7BæVVBÒævWB‚&æVVB"’÷&VÇ6R&6öFR#°¢6öç7BÒ6ÖE÷FV×ÆFRç–6´'”æVVB†2ÂæVVB’6F6‚°¢G'’2æ÷WBç&–çB‚.k*iÈkº‹k2ÒÖæVVC×·7Òy¨B$TE’jŠiÛõÆâ"Âç¶æVVGÒ“°¢&WGW&âW'&÷"äæ÷Df÷VæC°¢Ó°¢GÂÒæ–C°¢7FBæFV'Vrç&–çB‚%·FV×ÆFUÒÒÖæVVC×·7Ò(i"·7ÕÆâ"Âç²æVVBÂæ–BÒ“°¢Ğ ¢f"F–ÖV÷WE÷'C¢µÖ6öç7BS‚Ò"#°¢–b†ævWB‚'F–ÖV÷WB"’’ÇGÂ°¢–b‡7FBæf×Bç'6T–çB†“cBÂBÂ’’ÆçÂ°¢F–ÖV÷WE÷'BÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ"ÅÂ'F–ÖV÷WEÂ#§¶GÒ"Âç¶çÒ“°¢ÒVÇ6RÅ÷Â·Ğ¢Ğ¢6öç7BÖWF÷'BÒG'’'V–ÆDÖWFFF†2Â“°¢6öç7BW‡G&÷'BÒG'’'V–ÆD7&VFTW‡G&2†2Â“°¢6öç7B–ÆöBÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·µÂ'FV×ÆFT”EÂ#¥Â'·7ÕÂ'·7×·7×·7××Ò"Âç²GÂÂF–ÖV÷WE÷'BÂÖWF÷'BÂW‡G&÷'BÒ“° ¢6öç7B'VbÒG'’2æ&VææÆÆö2‡S‚Â%Tb“°¢6öç7B&W2ÒG'’2æ6öçG&öÂ‚åõ5BÂ"÷6æF&÷†W2"Â–ÆöBÂ'Vb“°¢6öç7B6–BÒVçfBæW‡G&7E7G&–ær†2æ&VæÂ&W2æ&öG’Â'6æF&÷„”B"’÷&VÇ6R°¢G'’2æ÷WBç&–çB‚'·7ÕÆâ"Âç·&W2æ&öG—Ò“°¢&WGW&ã°¢Ó°¢G'’2æ÷WBç&–çB‚'·7ÕÆâ"Âç·6–GÒ“° ¢òòhùzK®{ÙX[>Kˆîzºşx+ûÈiú^jŠiÛşŠúnh8^h»şzºşXú>ûÈÎhêijÒ–öB{ÙX[>ûÈ¢6öç7BFWF–Å÷F‚ÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ"÷FV×ÆFW2÷·7Ò"Âç·GÇÒ“°¢6öç7BG&W2Ò2æ6öçG&öÂ‚ätUBÂFWF–Å÷F‚ÂçVÆÂÂ'Vb’6F6‚&WGW&ã°¢6öç7B&u÷÷'G2ÒVçfBæW‡G&7E7G&–ær†2æ&VæÂG&W2æ&öG’Â&6öÒæW‡÷6VE÷÷'G2"’÷&VÇ6R&WGW&ã°¢6öç7B÷'G2Ò6ÖE÷FV×ÆFRç'6U÷'G2†2æ&VæÂ&u÷÷'G2’6F6‚&WGW&ã°¢6öç7BwrÒ6ÖE÷FV×ÆFRæwVW74vFWv’‡÷'G2Â""“°¢–b†wrÓÒ’&WGW&ã°¢6öç7B&÷‡’Ò6frç&÷‡•U$Â‚’÷&VÇ6R&WGW&ã°¢6öç7B&6RÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7Ò÷6æF&÷‚÷·7Ò"Âç²7G†ÖöBçG&–Õ6Æ6‚‡&÷‡’’Â6–BÒ“°¢7FBæFV'Vrç&–çB‚%·6æF&÷…Ò”ò{ÙX[3¢·7Ò÷¶GÒò(i–öBÖ6Æ’y¨B4äD$õ…ô$4UÆâ"Âç²&6RÂwrÒ“°¢7FBæFV'Vrç&–çB‚%·6æF&÷…ÒVçfB¢·7ÒóC““ƒ2õÆâ"Âç¶&6WÒ“°§Ğ ¢òòò6öFRÇ6–CâÎKº>zââãâ²ÒÖÖöFSÖ–çFW'Æ¶W&æVÅÒ²ÒÖÆæs×—F†öçÆ§7Æ&6…Ò²Ò×F–ÖV÷WCŞzy%Ò²ÒÖVçcÒââåÒ²Ò×W6W#ÕĞ¢òòò–çFW'ûÈ›¹ŠêNûÈûÉ®zØK»rW†V2—F†öã2Ö2ââîûÈKˆŞKéŞ‹YnŠz>˜x®YšiÈŞXªûÈÎK»¾KÙ^™YÎX8şXúşyJûÈ8 ¢òòò¶W&æVÎûÉ¥4D²'Våö6öFRy¨N˜	®˜2(	N(	Bõ5BÇ&÷‡“â÷6æF&÷‚óÇ6–CâóC“““’öW†V7WF^ûÈ†æF§6öîûÈ8 ¦fâ6ÖD6öFR†3¢¤7G‚Â&w3¢µÖ6öç7BµÖ6öç7BS‚’fö–B°¢6öç7BÒG'’WF–Âç'6R†2æ&VæÂ&w2“°¢–b†ç÷2æÆVâÂ"’&WGW&âW'&÷"äÖ—76–æt&s°¢6öç7B6–BÒç÷5³Ó°¢6öç7B7&2Òæ¦ö–äg&öÒƒÂ""“°¢6öç7BÆærÒævWB‚&Æær"’÷&VÇ6R'—F†öâ#°¢6öç7BVçg5ö§6öâÒG'’WF–ÂæVçg4§6öâ†2æ&VæÂæfÆw2“°¢f"F–ÖV÷WEö×3¢ScBÒ°¢–b†ævWB‚'F–ÖV÷WB"’’ÇGÂ°¢–b‡7FBæf×Bç'6T–çB‡ScBÂBÂ’’ÆçÂF–ÖV÷WEö×2Òâ¢VÇ6RÅ÷Â·Ğ¢Ğ ¢–b†ævWB‚&ÖöFR"’’Æ×Â°¢–b‡WF–ÂæW†ÒÂ&¶W&æVÂ"’’°¢&WGW&â6ÖE÷&ö2æ¶W&æVÅ'Vâ†2Â6–BÂ7&2ÂævWB‚&Æær"’ÂVçg5ö§6öâÂF–ÖV÷WEö×2“°¢Ğ¢–b‚WF–ÂæW†ÒÂ&–çFW'"’’°¢G'’2æ÷WBç&–çB‚.KˆŞiJşhÈy¨NjŠ[Èó¢·7ŞûÈXúş˜’–çFW'ò¶W&æVÎûÈ•Æâ"Âç¶×Ò“°¢&WGW&âW'&÷"ä&D&s°¢Ğ¢Ğ ¢6öç7BÒG'’WF–Âç6†VÆÅV÷FR†2æ&VæÂ7&2“°¢6öç7B6ÖBÒ–b†W†ÆærÂ'—F†öâ"’÷"W†ÆærÂ'—F†öã2"’¢G'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'—F†öã2Ö2·7Ò"Âç·Ò¢VÇ6R–b†W†ÆærÂ&§2"’÷"W†ÆærÂ&¦f67&—B"’÷"W†ÆærÂ&æöFR"’÷"W†ÆærÂ&æöFV§2"’¢G'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ&æöFRÖR·7Ò"Âç·Ò¢VÇ6R–b†W†ÆærÂ&&6‚"’÷"W†ÆærÂ'6‚"’÷"W†ÆærÂ'6†VÆÂ"’¢G'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ&&6‚Ö2·7Ò"Âç·Ò¢VÇ6R°¢G'’2æ÷WBç&–çB‚.KˆŞiJşhÈy¨NŠúŞŠˆ¢·7ŞûÈXúş˜’—F†öâò§2ò&6ûÈ•Æâ"Âç¶ÆæwÒ“°¢&WGW&âW'&÷"ä&DÆæs°¢Ó°¢G'’'Vä–å6æF&÷‚†2Â6–BÂ6ÖBÂçVÆÂÂ–b†Vçg5ö§6öâæÆVââ’Vçg5ö§6öâVÇ6RçVÆÂÂF–ÖV÷WEö×2ÂævWB‚'W6W""’“°§Ğ ¢òòòYÊk)zë˜xÎ‹yYŞKºN[›nh™>XÛ{¹>iéÎûÈ‹ùîhêRVçfB(i"hš~ŠÂ(i"‹é>X{¢7FF÷WB÷7FFW'"öW†—NûÈ8 ¦fâ'Vä–å6æF&÷‚†3¢¤7G‚Â6–C¢µÖ6öç7BS‚Â6öÖÖæC¢µÖ6öç7BS‚Â7vC¢õµÖ6öç7BS‚ÂVçg5ö§6öã¢õµÖ6öç7BS‚ÂF–ÖV÷WEö×3¢ScBÂW6W#¢õµÖ6öç7BS‚’fö–B°¢6öç7B'VbÒG'’2æ&VææÆÆö2‡S‚Â%Tb“°¢6öç7BFö¶VâÒG'’2æ6öææV7EFö¶Vâ‡6–BÂ'Vb“°¢6öç7BVçfEö&6RÒG'’2æVçfD&6R‡6–B“°¢6öç7B&W2ÒG'’VçfBæW†V2†2æ&VæÂ2æ6Æ–VçBÂVçfEö&6RÂFö¶VâÂW6W"Â6öÖÖæBÂ7vBÂVçg5ö§6öâÂF–ÖV÷WEö×2Â'Vb“°¢–b‡&W2ç7FF÷WBæÆVââ’G'’2æ÷WBç&–çB‚'·7Ò"Âç·&W2ç7FF÷WGÒ“°¢–b‡&W2ç7FFW'"æÆVââ’G'’2æ÷WBç&–çB‚'·7Ò"Âç·&W2ç7FFW''Ò“°¢–b‡&W2æW†—Eö6öFRÒ’G'’2æ÷WBç&–çB‚.ûÈ†W†—B¶GŞûÈ•Æâ"Âç·&W2æW†—Eö6öFWÒ“°§Ğ ¢òòòW†V2Ç6–CâÎYŞKºBââãâ²ÒÖ7vCÕÒ²ÒÖVçcÔäÔWÄ³ÕeÒ²Ò×F–ÖV÷WCŞzy%Ò²Ò×W6W#ŞyJh‹uĞ¦fâ6ÖDW†V2†3¢¤7G‚Â&w3¢µÖ6öç7BµÖ6öç7BS‚’fö–B°¢6öç7BÒG'’WF–Âç'6R†2æ&VæÂ&w2“°¢–b†ç÷2æÆVâÂ"’&WGW&âW'&÷"äÖ—76–æt&s°¢6öç7B6–BÒç÷5³Ó°¢f"6öÖÖæC¢µÖ6öç7BS‚Ò"#° ¢òòiJşhÈKØŞ{ÚîXø.i[K‹¢"Ò"i{nK¸îj~Xxn‹é>XZ^Šû¾XùnZèÎi[NYŞKºNûÈ˜şXXŞZHŞiØ.[É^Xûrô¥4ôî[XÎZY~Š*¾ZIn["6†VÆÂXš^zk¾ûÈ¢–b†ç÷2æÆVâÓÒ"æB7FBæÖVÒæWÂ‡S‚Âç÷5³ÒÂ"Ò"’’°¢6öç7B7FF–åö'VbÒG'’2æ&VææÆÆö2‡S‚Â%Tb“°¢f"&'Vc¢³ƒ“%×S‚ÒVæFVf–æVC°¢f""Ò7FBä–òäf–ÆRç7FF–â‚’ç&VFW"†2æ–òÂg&'Vb“°¢f"F÷FÃ¢W6—¦RÒ°¢v†–ÆR‡F÷FÂÂ7FF–åö'VbæÆVâ’°¢6öç7BâÒ"æ–çFW&f6Rç&VE6Æ–6U6†÷'B‡7FF–åö'Ve·F÷FÂâåÒ’6F6‚'&V³°¢–b†âÓÒ’'&V³°¢F÷FÂ³Òã°¢Ğ¢6öÖÖæBÒ7FBæÖVÒçG&–Ò‡S‚Â7FF–åö'Ve³âçF÷FÅÒÂ"Ç%ÆåÇB"“°¢ÒVÇ6R°¢–b†ç÷2æÆVâÓÒ"’°¢6öÖÖæBÒç÷5³Ó°¢ÒVÇ6R°¢f"rÒ7FBä–òåw&—FW"æf—†VB‡G'’2æ&VææÆÆö2‡S‚ÂcBÃÂ’“°¢f÷"†ç÷5³âåÒÂââ’ÇÂ—Â°¢–b†’â’G'’rç&–çB‚""Âç·Ò“°¢òòZh.iéÎXø.i[Xh^Y
¾z›®jÎ8XˆnXû~8XÙ^XøÎ[É^Xû~h‰nhºÎXû~ûÈÎKÛşyJ‚6†VÆÅV÷FRKùŞhª@¢–b‡7FBæÖVÒæ–æFW„ödç’‡S‚ÂÂ"²uÂ"‚’GÂcÃâ£÷æ"’ÒçVÆÂ÷"7FBæÖVÒæ–æFW„öe66Æ"‡S‚ÂÂuÇBr’ÒçVÆÂ’°¢6öç7BÒG'’WF–Âç6†VÆÅV÷FR†2æ&VæÂ“°¢G'’rç&–çB‚'·7Ò"Âç·Ò“°¢ÒVÇ6R°¢G'’rç&–çB‚'·7Ò"Âç·Ò“°¢Ğ¢Ğ¢6öÖÖæBÒræ'VffW&VB‚“°¢Ğ¢Ğ ¢òòxêşZ(>Xù˜xşk:XZ^ûÉ¢ÒÖVçcÔ³Õby»Nhê^{¹XÎûÉ²ÒÖVçcÔäÔRK¸îiÊÎiË®xêşZ(>Šû¾YÎYŞXù˜xğ¢òòûÈiXşhIşXÎKˆŞ[ø^X{®xëYÊYŞKºNŠÂò‹ù¾zˆ¾X‰~Š˜xÎûÈ¢6öç7BVçg5ö§6öâÒG'’WF–ÂæVçg4§6öâ†2æ&VæÂæfÆw2“° ¢6öç7B'VbÒG'’2æ&VææÆÆö2‡S‚Â%Tb“°¢6öç7BFö¶VâÒG'’2æ6öææV7EFö¶Vâ‡6–BÂ'Vb“°¢6öç7BVçfEö&6RÒG'’2æVçfD&6R‡6–B“° ¢òòKˆâ4D²Zû›ÙûÉ®{Ë®yÈKˆŞŠëîhŠ®jÚ.ûÈ‡'Vâ‡F–ÖV÷WCÔæöæR’(i"KˆŞXù6öææV7BÕF–ÖV÷WBÔ×>ûÈûÉ°¢òòi‹î[ÈòÒ×F–ÖV÷WCŞzy"h˜ŞKÙÎK‹¢VçfBKê~zÎhŠ®jÚ.8 ¢f"F–ÖV÷WEö×3¢ScBÒ°¢–b†ævWB‚'F–ÖV÷WB"’’ÇGÂ°¢–b‡7FBæf×Bç'6T–çB‡ScBÂBÂ’’ÆçÂF–ÖV÷WEö×2Òâ¢VÇ6RÅ÷Â·Ğ¢Ğ ¢6öç7B&W2ÒG'’VçfBæW†V2†2æ&VæÂ2æ6Æ–VçBÂVçfEö&6RÂFö¶VâÂævWB‚'W6W""’Â6öÖÖæBÂævWB‚&7vB"’Â–b†Vçg5ö§6öâæÆVââ’Vçg5ö§6öâVÇ6RçVÆÂÂF–ÖV÷WEö×2Â'Vb“°¢–b‡&W2ç7FF÷WBæÆVââ’G'’2æ÷WBç&–çB‚'·7Ò"Âç·&W2ç7FF÷WGÒ“°¢–b‡&W2ç7FFW'"æÆVââ’G'’2æ÷WBç&–çB‚'·7Ò"Âç·&W2ç7FFW''Ò“°¢–b‡&W2æW†—Eö6öFRÒ’G'’2æ÷WBç&–çB‚.ûÈ†W†—B¶GŞûÈ•Æâ"Âç·&W2æW†—Eö6öFWÒ“°§Ğ ¢òòòæWry¨NXúş˜hš[^ZÙ~jë^ûÈZû›Ù4D²6æF&÷‚æ7&VFRy¨NXúş˜Xø.i[ûÈûÉ ¢òòòÒÖVçcÔ³ÕnûÈXúş˜xŞZHŞûÈ’(i"Vçef'>ûÈ‹ù¾zˆ¾k:XZ^ûÈ¢òòòÒ×föÇVÖSŞXÛ~YÕ³®hÈ.‹ÛŞ‹zş[èEÒ(i"föÇVÖTÖ÷VçG>ûÈ‹zş[èN{Ë®yÈöÖçBóÎXÛ~YÓîûÈ¢òòòÒÖÆ–fV7–6ÆSÖ¶–ÆÇÇW6R(i"Æ–fV7–6ÆRæöåF–ÖV÷WNûÈ‡W6RÒz›®™{.hÈ.‹[~ûÈ¢òòòÒÖWFò×&W7VÖR(i"Æ–fV7–6ÆRæWFõ&W7VÖS×G'V^ûÈ˜XŞY‚W6^ûÈ¢òòòÒÖæòÖ–çFW&æWB(i"ÆÆ÷uö–çFW&æWEö66W73ÖfÇ6^ûÈ†S&"h˜[›>ZÙ~jë^ûÈÎKˆâ4D²Kˆˆ{NûÈ¢òòòÒÖF—7G&–'WF–öâ×66÷SŞˆ¨.x+’Ä•(i"F—7G&–'WF–öå66÷^ûÈ™™Zé®‹>[ªnˆ¨.x+ûÈ¦fâ'V–ÆD7&VFTW‡G&2†3¢¤7G‚Â¢WF–Âä&w2’µÖ6öç7BS‚°¢f"÷WC¢µÖ6öç7BS‚Ò"#°¢6öç7BVçg2ÒG'’WF–ÂæVçg4§6öâ†2æ&VæÂæfÆw2“°¢–b†Vçg2æÆVââ’÷WBÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7ÒÅÂ&Vçef'5Â#§···7××Ò"Âç²÷WBÂVçg2Ò“°¢–b†ævWB‚'föÇVÖR"’’ÇgÂ°¢6öç7B6’Ò7FBæÖVÒæ–æFW„öe66Æ"‡S‚ÂbÂs¢r“°¢6öç7BæÖRÒ–b†6’’Æ—Âe³âæ•ÒVÇ6Rc°¢6öç7BF‚Ò–b†6’’Æ—Âe¶’²âåÒVÇ6RG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ"öÖçB÷·7Ò"Âç¶æÖWÒ“°¢÷WBÒG'’7FBæf×BæÆÆö5&–çB€¢2æ&VæÀ¢'·7ÒÅÂ'föÇVÖTÖ÷VçG5Â#¥··µÂ&æÖUÂ#¥Â'·7ÕÂ"ÅÂ'F…Â#¥Â'·7ÕÂ'×ÕÒ"À¢ç²÷WBÂG'’VçfBæ§6öäW66R†2æ&VæÂæÖR’ÂG'’VçfBæ§6öäW66R†2æ&VæÂF‚’ÒÀ¢“°¢Ğ¢–b†ævWB‚&Æ–fV7–6ÆR"’’ÆÆ7Â°¢6öç7Böã¢µÖ6öç7BS‚Ò–b‡7FBæÖVÒæWÂ‡S‚ÂÆ2Â'W6R"’’'W6R"VÇ6R&¶–ÆÂ#°¢f"Æ6&öG“¢µÖ6öç7BS‚ÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ%Â&öåF–ÖV÷WEÂ#¥Â'·7ÕÂ""Âç¶öçÒ“°¢–b†æ†2‚&WFò×&W7VÖR"’’Æ6&öG’ÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7ÒÅÂ&WFõ&W7VÖUÂ#§G'VR"Âç¶Æ6&öG—Ò“°¢÷WBÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7ÒÅÂ&Æ–fV7–6ÆUÂ#§···7××Ò"Âç²÷WBÂÆ6&öG’Ò“°¢Ğ¢–b†æ†2‚&æòÖ–çFW&æWB"’’÷WBÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7ÒÅÂ&ÆÆ÷uö–çFW&æWEö66W75Â#¦fÇ6R"Âç¶÷WGÒ“°¢–b†ævWB‚&F—7G&–'WF–öâ×66÷R"’’Ç67Â°¢f"Æ—7C¢µÖ6öç7BS‚Ò"#°¢f"—BÒ7FBæÖVÒçFö¶Væ—¦U66Æ"‡S‚Â62ÂrÂr“°¢f"bÒG'VS°¢v†–ÆR†—BææW‡B‚’’ÇFö·Â°¢Æ—7BÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7×·7ÕÂ'·7ÕÂ""Âç²Æ—7BÂ–b†b’""VÇ6R"Â"ÂG'’VçfBæ§6öäW66R†2æ&VæÂFö²’Ò“°¢bÒfÇ6S°¢Ğ¢÷WBÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7ÒÅÂ&F—7G&–'WF–öå66÷UÂ#¥··7ÕÒ"Âç²÷WBÂÆ—7BÒ“°¢Ğ¢–b†ævWB‚&Ö7"’’ÆÖ7Â°¢òòÒÖÖ7ÓÄ¥4ôãîûÉ¤S$"X[ÎZëy¨BÔ5iÈŞXª˜XŞ{Úî˜şKÊX‹õ5B÷6æF&÷†W0¢÷WBÒG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7ÒÅÂ&Ö7Â#§·7Ò"Âç²÷WBÂÖ7Ò“°¢Ğ¢&WGW&â÷WC°§Ğ ¢òòò‹ûŞXªKˆKŠ¢ÖWFFF™JîXÎûÈ†6öÖÖ×G'VRi{nX˜Ş™Ú.Š^˜	~Xû~ûÈ¦fâFDµb†3¢¤7G‚Â÷WC¢µÖ6öç7BS‚Â³¢µÖ6öç7BS‚Âc¢µÖ6öç7BS‚Â6öÖÖ¢&ööÂ’µÖ6öç7BS‚°¢6öç7BRÒG'’VçfBæ§6öäW66R†2æ&VæÂb“°¢&WGW&âG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7×·7ÕÂ'·7ÕÂ#¥Â'·7ÕÂ""Âç²÷WBÂ–b†6öÖÖ’"Â"VÇ6R""Â²ÂRÒ“°§Ğ  ¢òòò{¸NŠ8RÖWFFFûÉ¦vVçNûÈ‹[Èy¨NûÈ’òF6¾ûÈX®K¸K˜ûÈ’òæ÷F^ûÈi‹îzK®YŞûÈ¢òòò{Ë®yÈXùnxêşZ(>Xù˜xò5T$U4äD$õ…ôtTåEôäÔ^ûÈÎKùŞŠøK»¾KÙ^k)zë˜;Şˆ;Şkªşk©ûÉ¶FÖ–âvV%T’KÉ®˜	iÚk‹.iù>‹ùK©¾ZÙ~jë^8 ¦fâ'V–ÆDÖWFFF†3¢¤7G‚Â¢WF–Âä&w2’µÖ6öç7BS‚°¢6öç7BvVçBÒævWB‚&vVçB"’÷&VÇ6R6frævWFVçb‚$5T$U4äD$õ…ôtTåEôäÔR"’÷&VÇ6R&7V&RÖ6Æ’#°¢6öç7BF6²ÒævWB‚'F6²"“°¢6öç7Bæ÷FRÒævWB‚&æ÷FR"’÷&VÇ6R†–b‡F6²’ÇGÂG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ'·7Ò+r·7Ò"Âç²vVçBÂBÒ’VÇ6RvVçB“°¢f"÷WC¢µÖ6öç7BS‚Ò"#°¢–b‡F6²’ÇGÂ÷WBÒG'’FDµb†2Â÷WBÂ'F6²"ÂBÂfÇ6R“°¢÷WBÒG'’FDµb†2Â÷WBÂ&vVçB"ÂvVçBÂ÷WBæÆVââ“°¢÷WBÒG'’FDµb†2Â÷WBÂ&æ÷FR"Âæ÷FRÂG'VR“°¢÷WBÒG'’FDµb†2Â÷WBÂ&6Æ’"Â&7V&RÖ6Æ’"ÂG'VR“°¢&WGW&âG'’7FBæf×BæÆÆö5&–çB†2æ&VæÂ"ÅÂ&ÖWFFFÂ#§···7××Ò"Âç¶÷WGÒ“°§Ğ 