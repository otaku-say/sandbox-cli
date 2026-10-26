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

/// æ‰“å°å®Œç«‹å–Ä»¥æŒ‡å®šç é€€å‡ºï¼ˆprocess.exit ä¸è·‘ deferï¼Œæ‰€ä»¥å…ˆ flushï¼‰ã€‚
fn exitWith(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

// health / ls / rm å·²ç§»åˆ°ç‹¬ç«‹æ¨¡å—ï¼ˆcmd_health.zig / cmd_ls.zig / cmd_rm.zigï¼‰ï¼Œ
// ç”¨æ³•è¯´æ˜è§å„è‡ªçš„ `pub const help;ï&ÛXZ[‹šYÈ:/æzaã9cê¹/çyåfH\Ü]Ú9£©yî¯øà ‚‚™›ˆÛY™]ÊÎˆ
İ\™ÜÎˆ×XÛÛœİ×XÛÛœİN
H]›ÚYÂˆÛÛœİHHH][œ\œÙJË˜\™[˜K\™ÜÊNÂˆËÈK][\]H9/&9ab;ï&ù¬¨y§"yb&y£"HK[™YY9bª9  y£${ï"9.#ˆ\XÚÈ9d#9. :`.ú/¤{ï"Bˆ˜\ˆˆ×XÛÛœİNHˆÂˆYˆ
K™Ù]
[\]HŠJHÂˆËÈ9ab9§éy§#yb¨yêëùb*ùd#{ï"ÑUİ[\]\ËØ[X\Ù\ËŞùd#_{ï"{ï&ùi,z-)ya£z` 9fç¹§+9g,9c.zacBˆËÈ;ï"9ª(y§oÈQ9aj9ëbHÈ9b*ùd#HÈ[XYÙR[™›È9kd9.,¹e+ù. 9doy.+{ï"{ï&ú`ïy§*¹doy.+yl,yc§ù¨-ù.©9îæy§#yb¨yêëøà ‚ˆYˆ
ÛYİ[\]Kœ™\ÛÛ™U[\]T™YŠË
JHYÂˆHYÂˆİ™XYËœš[
–İ[\]WHÜßH8¡¤ˆÜßWˆ‹ÈYJNÂˆH[ÙHÂˆHÂˆBˆH[ÙHÂˆËÈ:næ:+©K[™YYXÛÙ{ï"Z[ËXÛÙH9¬¦yë¬{ï&¹.#zg :) y­cú)â9fj9¥í¹æ¡9. 9o¢ú`"y¢ê{ï&ÂˆËÈ:g :) y­cú)â9fjù¨c:gh¹¥í¹¦/¹o#ùîæHK[™YYXœ›İÜÙ\Ÿ\ÚİÜ;ï"BˆÛÛœİ™YYHK™Ù]
›™YYŠHÜ™[ÙH˜ÛÙHÂˆÛÛœİHÛYİ[\]KœXÚĞS™YY
Ë™YY
HØ]ÚÂˆHË›İ]œš[
¹¬¨y§"y®èz-¬ÈK[™YY^ÜßH9æ¡‘PQH9ª(y§o×ˆ‹Û™YYJNÂˆ™]\›ˆ\œ›Ü‹“›İ›İ[™ÂˆNÂˆHšYÂˆİ™XYËœš[
–İ[\]WHK[™YY^ÜßH8¡¤ˆÜßWˆ‹È™YYšYJNÂˆB‚ˆ˜\ˆ[Y[İ]Ü\ˆ×XÛÛœİNHˆÂˆYˆ
K™Ù]
[Y[İ]ŠJHÂˆYˆ
İ™›]œ\œÙR[
ML
JHŸÂˆ[Y[İ]Ü\HHİ™›]˜[ØÔš[
Ë˜\™[˜K‹[Y[İ]ÙH‹ÛŸJNÂˆH[ÙHßßBˆBˆÛÛœİY]WÜ\HHZ[Y]Y]JËJNÂˆÛÛœİ^˜WÜ\HHZ[Ü™X]Q^˜\ÊËJNÂˆÛÛœİ^[ØYHHİ™›]˜[ØÔš[
Ë˜\™[˜KŞ×[\]RQ—ÜßWÜß^Üß^Üß__H‹È[Y[İ]Ü\Y]WÜ\^˜WÜ\JNÂ‚ˆÛÛœİYˆHHË˜\™[˜K˜[ØÊN•QŠNÂˆÛÛœİ™\ÈHHË˜ÛÛ›Û
”ÔÕ‹ÜØ[™›Ş\È‹^[ØYYŠNÂˆÛÛœİÚYH[™™^˜Xİİš[™ÊË˜\™[˜K™\Ë˜›ÙKœØ[™›ŞQŠHÜ™[ÙHÂˆHË›İ]œš[
ÜßWˆ‹Ü™\Ë˜›Ù_JNÂˆ™]\›ÂˆNÂˆHË›İ]œš[
ÜßWˆ‹ÜÚYJNÂ‚ˆËÈ9£ä9é.¹ïdyalù.#¹êëùà®{ï"9§éyª(y§oú+é¹ áy¢ïùêëùcèûï#9£ª9¥«HZ[Ù9ïdyalûï"BˆÛÛœİ]Z[Ü]HHİ™›]˜[ØÔš[
Ë˜\™[˜K‹İ[\]\ËŞÜßH‹İJNÂˆÛÛœİ™\ÈHË˜ÛÛ›Û
‘ÑU]Z[Ü][YŠHØ]Ú™]\›ÂˆÛÛœİ˜]×ÜÜÈH[™™^˜Xİİš[™ÊË˜\™[˜K™\Ë˜›ÙK˜ÛÛK™^ÜÙYÜÜÈŠHÜ™[ÙH™]\›ÂˆÛÛœİÜÈHÛYİ[\]Kœ\œÙTÜÊË˜\™[˜K˜]×ÜÜÊHØ]Ú™]\›ÂˆÛÛœİİÈHÛYİ[\]K™İY\ÜÑØ]]Ø^JÜËˆŠNÂˆYˆ
İÈOH
H™]\›ÂˆÛÛœİ›ŞHHÙ™Ëœ›ŞUT“

HÜ™[ÙH™]\›ÂˆÛÛœİ˜\ÙHHHİ™›]˜[ØÔš[
Ë˜\™[˜KÜßKÜØ[™›ŞŞÜßH‹Èİ[Ùš[TÛ\Ú
›ŞJKÚYJNÂˆİ™XYËœš[
–ÜØ[™›ŞHRSÈ9ïdyalÎˆÜßKŞÙKÈ8¡¤Z[ÙXÛH9æ¡ĞS‘“ÖĞTÑWˆ‹È˜\ÙKİÈJNÂˆİ™XYËœš[
–ÜØ[™›ŞH[™ˆÜßKÍNNË×ˆ‹Ø˜\Ù_JNÂŸB‚‹ËËÈÛÙHÚYˆ9.èùè K‹‹ˆËK[[ÙOZ[\œÙ\›™[HËK[[™Ï\]ÛŸœß˜\ÚHËK][Y[İ]yéä—HËKY[K‹‹—HËK]\Ù\WB‹ËËÈ[\œ;ï":næ:+©;ï"{ï&¹ëby.íÈ^XÈ]ÛŒÈXÈ‹‹»ï"9.#y/§z-eº)èúaâ¹fj9§#yb¨{ï#9.îù/ezeg9`ãùcëùå*;ï"xà ‚‹ËËÈÙ\›™[;ï&”ÑÈ[—ØÛÙH9æ¡:`&º`dÈ8 %8 %ÔÕ›ŞO‹ÜØ[™›ŞÏÚY‹ÍNNNKÙ^Xİ]{ï"™œÛÛ»ï"xà ‚™›ˆÛYÛÙJÎˆ
İ\™ÜÎˆ×XÛÛœİ×XÛÛœİN
H]›ÚYÂˆÛÛœİHHH][œ\œÙJË˜\™[˜K\™ÜÊNÂˆYˆ
KœÜË›[ˆŠH™]\›ˆ\œ›Ü‹“Z\ÜÚ[™Ğ\™ÎÂˆÛÛœİÚYHKœÜÖÌNÂˆÛÛœİÜ˜ÈHKš›Ú[‘œ›ÛJKˆŠNÂˆÛÛœİ[™ÈHK™Ù]
›[™ÈŠHÜ™[ÙHœ]ÛˆÂˆÛÛœİ[œ×ÚœÛÛˆHH][™[œÒœÛÛŠË˜\™[˜KK™›YÜÊNÂˆ˜\ˆ[Y[İ]Û\ÎˆMHÂˆYˆ
K™Ù]
[Y[İ]ŠJHÂˆYˆ
İ™›]œ\œÙR[
ML
JHŸ[Y[İ]Û\ÈHˆ
ˆL[ÙHßßBˆB‚ˆYˆ
K™Ù]
›[ÙHŠJH_ÂˆYˆ
][™\JKšÙ\›™[ŠJHÂˆ™]\›ˆÛYÜ›ØËšÙ\›™[[ŠËÚYÜ˜ËK™Ù]
›[™ÈŠK[œ×ÚœÛÛ‹[Y[İ]Û\ÊNÂˆBˆYˆ
]][™\JKš[\œŠJHÂˆHË›İ]œš[
¹.#y¥+ù£ yæ¡9ª(yo#ÎˆÜß{ï"9cëú`"H[\œÈÙ\›™[;ï"Wˆ‹Û_JNÂˆ™]\›ˆ\œ›Ü‹˜Y\™ÎÂˆBˆB‚ˆÛÛœİHHH][œÚ[][İJË˜\™[˜KÜ˜ÊNÂˆÛÛœİÛYHYˆ
\J[™Ëœ]ÛˆŠHÜˆ\J[™Ëœ]ÛŒÈŠJBˆHİ™›]˜[ØÔš[
Ë˜\™[˜Kœ]ÛŒÈXÈÜßH‹Ü_JBˆ[ÙHYˆ
\J[™ËšœÈŠHÜˆ\J[™Ëš˜]˜\ØÜš\ŠHÜˆ\J[™Ë››ÙHŠHÜˆ\J[™Ë››ÙZœÈŠJBˆHİ™›]˜[ØÔš[
Ë˜\™[˜K››ÙHYHÜßH‹Ü_JBˆ[ÙHYˆ
\J[™Ë˜˜\ÚŠHÜˆ\J[™ËœÚŠHÜˆ\J[™ËœÚ[ŠJBˆHİ™›]˜[ØÔš[
Ë˜\™[˜K˜˜\ÚXÈÜßH‹Ü_JBˆ[ÙHÂˆHË›İ]œš[
¹.#y¥+ù£ yæ¡:+ëz* ˆÜß{ï"9cëú`"H]ÛˆÈœÈÈ˜\Ú;ï"Wˆ‹Û[™ßJNÂˆ™]\›ˆ\œ›Ü‹˜Y[™ÎÂˆNÂˆH[’[”Ø[™›Ş
ËÚYÛY[Yˆ
[œ×ÚœÛÛ‹›[ˆˆ
H[œ×ÚœÛÛˆ[ÙH[[Y[İ]Û\ËK™Ù]
\Ù\ˆŠJNÂŸB‚‹ËËÈ9g*9¬¦yë¬zaã:-äydoy.é9nm¹¢dùcl9îäù§§;ï":/ç¹£©H[™8¡¤ˆ9¢iú(c8¡¤ˆ:/¤ùaîˆİİ]Üİ\œ‹Ù^];ï"xà ‚™›ˆ[’[”Ø[™›Ş
Îˆ
İÚYˆ×XÛÛœİNÛÛ[X[™ˆ×XÛÛœİNİÙˆÖ×XÛÛœİN[œ×ÚœÛÛˆÖ×XÛÛœİN[Y[İ]Û\ÎˆM\Ù\ˆÖ×XÛÛœİN
H]›ÚYÂˆÛÛœİYˆHHË˜\™[˜K˜[ØÊN•QŠNÂˆÛÛœİÚÙ[ˆHHË˜ÛÛ›™XİÚÙ[ŠÚYYŠNÂˆÛÛœİ[™Ø˜\ÙHHHË™[™˜\ÙJÚY
NÂˆÛÛœİ™\ÈHH[™™^XÊË˜\™[˜KË˜ÛY[[™Ø˜\ÙKÚÙ[‹\Ù\‹ÛÛ[X[™İÙ[œ×ÚœÛÛ‹[Y[İ]Û\ËYŠNÂˆYˆ
™\Ëœİİ]›[ˆˆ
HHË›İ]œš[
ÜßH‹Ü™\Ëœİİ]JNÂˆYˆ
™\Ëœİ\œ‹›[ˆˆ
HHË›İ]œš[
ÜßH‹Ü™\Ëœİ\œŸJNÂˆYˆ
™\Ë™^]ØÛÙHOH
HHË›İ]œš[
»ï"^]Ù{ï"Wˆ‹Ü™\Ë™^]ØÛÙ_JNÂŸB‚‹ËËÈ^XÈÚYˆ9doy.é‹‹ˆËKXİÙWHËKY[SSQ_ÏU—HËK][Y[İ]yéä—HËK]\Ù\yå*9¢-×B™›ˆÛY^XÊÎˆ
İ\™ÜÎˆ×XÛÛœİ×XÛÛœİN
H]›ÚYÂˆÛÛœİHHH][œ\œÙJË˜\™[˜K\™ÜÊNÂˆYˆ
KœÜË›[ˆŠH™]\›ˆ\œ›Ü‹“Z\ÜÚ[™Ğ\™ÎÂˆÛÛœİÚYHKœÜÖÌNÂˆ˜\ˆÛÛ[X[™ˆ×XÛÛœİNHˆÂ‚ˆËÈ9¥+ù£ y/cyïk¹cà¹¥l9..ˆ‹Hˆ9¥í¹.ã¹¨!ùaáº/¤ùaiz+îùcå¹k£9¥m9doy.é;ï":`oùacyi#y§`¹o%ycíËÒ”ÓÓ¹mc9ieú(ªùi%¹l`ˆÚ[9biyé®ûï"BˆYˆ
KœÜË›[ˆOHˆ[™İ›Y[K™\[
NKœÜÖÌWK‹HŠJHÂˆÛÛœİİ[—ØYˆHHË˜\™[˜K˜[ØÊN•QŠNÂˆ˜\ˆ˜YˆÎNL—]NH[™Yš[™YÂˆ˜\ˆˆHİ’[Ë‘š[Kœİ[Š
Kœ™XY\ŠËš[Ë	œ˜YŠNÂˆ˜\ˆİ[ˆ\Ú^™HHÂˆÚ[H
İ[İ[—ØY‹›[ŠHÂˆÛÛœİˆH‹š[\™˜XÙKœ™XYÛXÙTÚÜ
İ[—ØY–İİ[‹—JHØ]Úœ™XZÎÂˆYˆ
ˆOH
Hœ™XZÎÂˆİ[
ÏHÂˆBˆÛÛ[X[™Hİ›Y[Kš[JNİ[—ØY–Ì‹İ[Kˆ——ŠNÂˆH[ÙHÂˆYˆ
KœÜË›[ˆOHŠHÂˆÛÛ[X[™HKœÜÖÌWNÂˆH[ÙHÂˆ˜\ˆÈHİ’[Ë•Üš]\‹™š^Y
HË˜\™[˜K˜[ØÊNL
JNÂˆ›Üˆ
KœÜÖÌK‹—K‹ŠH_ÂˆYˆ
Hˆ
HHËœš[
ˆ‹ßJNÂˆËÈ9i ¹§§9cà¹¥l9a¡yd*ùên¹¨/8à yb!¹cíøà yceycã9o%ycíù¢%¹¢ë9cíûï#9/oùå*Ú[][İH9/çy¢©ˆYˆ
İ›Y[Kš[™^Ù[JNˆÉ×Š
I	Šß˜ŠHOH[Üˆİ›Y[Kš[™^Ù”ØØ[\ŠN	×	ÊHOH[
HÂˆÛÛœİHHH][œÚ[][İJË˜\™[˜K
NÂˆHËœš[
ÜßH‹Ü_JNÂˆH[ÙHÂˆHËœš[
ÜßH‹ÜJNÂˆBˆBˆÛÛ[X[™HË˜Y™™\™Y

NÂˆBˆB‚ˆËÈ9ã«ùh ùcæ:aãù¬ê9ai{ï&‹KY[RÏUˆ9æí9£©yîæy`/;ï&ËKY[SSQH9.ã¹§+9§.¹ã«ùh ú+îùd#9d#ycæ:aãÂˆËÈ;ï"9¥cù¡'ù`/9.#yoáyaî¹ã¬9g*9doy.é:(cÈ:/æùê"ùb%ú(j:aã;ï"BˆÛÛœİ[œ×ÚœÛÛˆHH][™[œÒœÛÛŠË˜\™[˜KK™›YÜÊNÂ‚ˆÛÛœİYˆHHË˜\™[˜K˜[ØÊN•QŠNÂˆÛÛœİÚÙ[ˆHHË˜ÛÛ›™XİÚÙ[ŠÚYYŠNÂˆÛÛœİ[™Ø˜\ÙHHHË™[™˜\ÙJÚY
NÂ‚ˆËÈ9.#ˆÑÈ9kîzod;ï&¹ï.¹ç y.#z+¯¹¢*¹«h»ï"[Š[Y[İ]S›Û™JH8¡¤ˆ9.#ycäHÛÛ›™XİU[Y[İ]S\ûï"{ï&ÂˆËÈ9¦/¹o#ÈK][Y[İ]yéäˆ9¢cy/g9..ˆ[™9/©ùèk9¢*¹«h¸à ‚ˆ˜\ˆ[Y[İ]Û\ÎˆMHÂˆYˆ
K™Ù]
[Y[İ]ŠJHÂˆYˆ
İ™›]œ\œÙR[
ML
JHŸ[Y[İ]Û\ÈHˆ
ˆL[ÙHßßBˆB‚ˆÛÛœİ™\ÈHH[™™^XÊË˜\™[˜KË˜ÛY[[™Ø˜\ÙKÚÙ[‹K™Ù]
\Ù\ˆŠKÛÛ[X[™K™Ù]
˜İÙŠKYˆ
[œ×ÚœÛÛ‹›[ˆˆ
H[œ×ÚœÛÛˆ[ÙH[[Y[İ]Û\ËYŠNÂˆYˆ
™\Ëœİİ]›[ˆˆ
HHË›İ]œš[
ÜßH‹Ü™\Ëœİİ]JNÂˆYˆ
™\Ëœİ\œ‹›[ˆˆ
HHË›İ]œš[
ÜßH‹Ü™\Ëœİ\œŸJNÂˆYˆ
™\Ë™^]ØÛÙHOH
HHË›İ]œš[
»ï"^]Ù{ï"Wˆ‹Ü™\Ë™^]ØÛÙ_JNÂŸB‚‹ËËÈ™]È9æ¡9cëú`"y¢jyleykeù«­{ï"9kîzodÑÈØ[™›Ş˜Ü™X]H9æ¡9cëú`"ycà¹¥l;ï"{ï&‚‹ËËÈKY[RÏU»ï"9cëúaãyi#{ï"H8¡¤ˆ[•˜\œûï":/æùê"ù¬ê9ai{ï"B‹ËËÈK]›Û[YOycmùd#VÎ¹£ º/oz-ëùo¡H8¡¤ˆ›Û[YS[İ[ûï":-ëùo¡9ï.¹ç HÛ[Ï9cmùd#O»ï"B‹ËËÈK[Y™XŞXÛOZÚ[]\ÙH8¡¤ˆY™XŞXÛK›Û•[Y[İ];ï"]\ÙHH9ênºeì¹£ º-mûï"B‹ËËÈKX]]Ë\™\İ[YH8¡¤ˆY™XŞXÛK˜]]Ô™\İ[YO]Y{ï":acyd"]\Ù{ï"B‹ËËÈK[›ËZ[\›™]8¡¤ˆ[İ×Ú[\›™]ØXØÙ\Ü×™˜[ÙH‹Ûİ]JNÂˆYˆ
K™Ù]
™\İšX][Û‹\ØÛÜHŠJHØßÂˆ˜\ˆ\İˆ×XÛÛœİNHˆÂˆ˜\ˆ]Hİ›Y[KÚÙ[š^™TØØ[\ŠNØË	Ë	ÊNÂˆ˜\ˆˆHYNÂˆÚ[H
]›™^

JHÚßÂˆ\İHHİ™›]˜[ØÔš[
Ë˜\™[˜KÜß^ÜßWÜßWˆ‹È\İYˆ
ŠHˆˆ[ÙH‹‹H[™šœÛÛ‘\ØØ\JË˜\™[˜KÚÊHJNÂˆˆH˜[ÙNÂˆBˆİ]HHİ™›]˜[ØÔš[
Ë˜\™[˜KÜßK™\İšX][Û”ØÛÜW–ŞÜßWH‹Èİ]\İJNÂˆBˆYˆ
K™Ù]
›XÜŠJHXÜÂˆËÈK[XÜO”ÓÓ»ï&‘Lˆ9ao9k®yæ¡PÔ9§#yb¨zacyïkº`#ù/(9b,ÔÕÜØ[™›Ş\Âˆİ]HHİ™›]˜[ØÔš[
Ë˜\™[˜KÜßK›XÜÜßH‹Èİ]XÜJNÂˆBˆ™]\›ˆİ]ÂŸB‚‹ËËÈ:/ïyb¨9. 9.*ˆY]Y]H:e+¹`/;ï"ÛÛ[XO]YH9¥í¹bczghº(iz`%ùcíûï"B™›ˆYÕŠÎˆ
İİ]ˆ×XÛÛœİNÎˆ×XÛÛœİNˆ×XÛÛœİNÛÛ[XNˆ›ÛÛ
HV×XÛÛœİNÂˆÛÛœİHHH[™šœÛÛ‘\ØØ\JË˜\™[˜KŠNÂˆ™]\›ˆHİ™›]˜[ØÔš[
Ë˜\™[˜KÜß^ÜßWÜßW—ÜßWˆ‹Èİ]Yˆ
ÛÛ[XJH‹ˆ[ÙHˆ‹ËHJNÂŸB‚‚‹ËËÈ9îá:(áHY]Y]{ï&˜YÙ[;ï":, yo 9æ¡;ï"KÈ\Úûï"9`f¹.à9.b;ï"KÈ›İ{ï"9¦/¹é.¹d#{ï"B‹ËËÈ9ï.¹ç ycå¹ã«ùh ùcæ:aãÈÕP‘TĞS‘“ÖĞQÑS•ÓSQ{ï#9/çz+ày.îù/ey¬¦yë¬z`ïz ïy®«ù®¤;ï&ØYZ[ˆÙX•RH9/&º`$9§hy®,¹§äú/æy.¦ùkeù«­xà ‚™›ˆZ[Y]Y]JÎˆ
İNˆ][\™ÜÊHV×XÛÛœİNÂˆÛÛœİYÙ[HK™Ù]
˜YÙ[ŠHÜ™[ÙHÙ™Ë™Ù][ŠÕP‘TĞS‘“ÖĞQÑS•ÓSQHŠHÜ™[ÙH˜İX™KXÛHÂˆÛÛœİ\ÚÈHK™Ù]
\ÚÈŠNÂˆÛÛœİ›İHHK™Ù]
››İHŠHÜ™[ÙH
Yˆ
\ÚÊHHİ™›]˜[ØÔš[
Ë˜\™[˜KÜßH0­ÈÜßH‹ÈYÙ[JH[ÙHYÙ[
NÂˆ˜\ˆİ]ˆ×XÛÛœİNHˆÂˆYˆ
\ÚÊHİ]HHYÕŠËİ]\ÚÈ‹˜[ÙJNÂˆİ]HHYÕŠËİ]˜YÙ[‹YÙ[İ]›[ˆˆ
NÂˆİ]HHYÕŠËİ]››İH‹›İKYJNÂˆİ]HHYÕŠËİ]˜ÛH‹˜İX™KXÛH‹YJNÂˆ™]\›ˆHİ™›]˜[ØÔš[
Ë˜\™[˜K‹›Y]Y]WŞŞÜß__H‹Ûİ]JNÂŸB