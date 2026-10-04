//! 生命周期 / 快照 / 持久卷（全部走控制面 REST）
//!
//!   POST   /sandboxes/<id>/pause              暂停（挂起快照，0 成本）
//!   POST   /sandboxes/<id>/resume            恢复（body 可带 timeout）
//!   POST   /sandboxes/<id>/timeout           设置空闲超时
//!   POST   /sandboxes/<id>/refreshes         续期（新增时间窗）
//!   POST   /sandboxes/<id>/snapshots         打快照
//!   GET    /snapshots                        快照列表
//!   POST   /sandboxes/<id>/rollback          回滚到快照
//!   DELETE /templates/<snapshotID>           删除快照（官方刻意未开 /snapshots/{id} DELETE）
//!   GET/POST/DELETE /volumes                 持久卷
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const envd = @import("envd.zig");
const cfg = @import("cfg.zig");
const httpc = @import("httpc.zig");
const jsonfmt = @import("jsonfmt.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

fn sidOf(a: util.Args) ![]const u8 {
    return a.at(0) orelse error.MissingArg;
}

fn post(c: *Ctx, path: []const u8, body: []const u8, msg: []const u8, arg: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    _ = try c.control(.POST, path, body, buf);
    try c.out.print("{s} {s}\n", .{ msg, arg });
}

/// pause <sid> [--wait] [--timeout=秒]
fn cmdPause(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/pause", .{sid});
    const buf = try c.arena.alloc(u8, BUF);
    _ = try c.control(.POST, path, "{}", buf);
    if (a.has("wait")) {
        var limit_s: u64 = 30;
        if (a.get("timeout")) |t| limit_s = std.fmt.parseInt(u64, t, 10) catch 30;
        try waitState(c, sid, "paused", limit_s);
    } else {
        try c.out.print("paused {s}\n", .{sid});
    }
}

/// resume <sid> [--timeout=秒]
fn cmdResume(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/resume", .{sid});
    var body: []const u8 = "{}";
    if (a.get("timeout")) |t| {
        body = try std.fmt.allocPrint(c.arena, "{{\"timeout\":{s}}}", .{t});
    }
    try post(c, path, body, "resumed", sid);
}

/// timeout <sid> <秒> | timeout <sid> --timeout=秒   （-1 = 永不回收）
fn cmdTimeout(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const secs = a.get("timeout") orelse (a.at(1) orelse return error.MissingArg);
    _ = std.fmt.parseInt(i64, secs, 10) catch {
        try c.out.print("错误：秒数需要整数（收到 {s}）\n", .{secs});
        return error.BadArg;
    };
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/timeout", .{sid});
    const body = try std.fmt.allocPrint(c.arena, "{{\"timeout\":{s}}}", .{secs});
    try post(c, path, body, "timeout set", sid);
}

/// refresh <sid> <秒> | refresh <sid> --duration=秒   （续期：新增时间窗）
fn cmdRefresh(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const secs = a.get("duration") orelse (a.at(1) orelse return error.MissingArg);
    _ = std.fmt.parseInt(i64, secs, 10) catch {
        try c.out.print("错误：秒数需要整数（收到 {s}）\n", .{secs});
        return error.BadArg;
    };
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/refreshes", .{sid});
    const body = try std.fmt.allocPrint(c.arena, "{{\"duration\":{s}}}", .{secs});
    try post(c, path, body, "refreshed", sid);
}

/// snap <sid> [--name=名称]
fn cmdSnap(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/snapshots", .{sid});
    var body: []const u8 = "{}";
    if (a.get("name")) |n| {
        body = try std.fmt.allocPrint(c.arena, "{{\"name\":\"{s}\"}}", .{try envd.jsonEscape(c.arena, n)});
    }
    const res = try c.control(.POST, path, body, buf);
    // 尽量提取 snapshotID
    if (envd.extractString(c.arena, res.body, "snapshotID")) |id| {
        try c.out.print("{s}\n", .{id});
    } else {
        try c.out.print("{s}\n", .{res.body});
    }
}

/// snap-ls [--sandbox=sid] [--backend=xfs|s3] [--limit=N] [--next=TOKEN] [--all] [--json]
fn cmdSnapLs(c: *Ctx, a: util.Args) !void {
    var page_limit: u32 = 0;
    if (a.get("limit")) |l| {
        page_limit = std.fmt.parseInt(u32, l, 10) catch {
            try c.out.print("错误：--limit= 需要正整数（收到 {s}）\n", .{l});
            return error.BadArg;
        };
        if (page_limit == 0) {
            try c.out.print("错误：--limit= 需要正整数\n", .{});
            return error.BadArg;
        }
    }
    const all = a.has("all");
    var token: []const u8 = a.get("next") orelse "";
    var total: usize = 0;
    var pages: usize = 0;
    var header_printed = false;
    var acc = std.Io.Writer.fixed(try c.arena.alloc(u8, 32 << 20));
    var acc_first = true;
    var last: ?httpc.Response = null;

    while (true) {
        const path = try snapLsPath(c, a, page_limit, token);
        const buf = try c.arena.alloc(u8, BUF);
        const res = try c.control(.GET, path, null, buf);
        last = res;
        pages += 1;
        const items = try snapItems(c, res.body);
        if (a.has("json")) {
            if (all) {
                for (items) |it| {
                    if (!acc_first) {
                        acc.writeAll(",") catch {
                            try c.out.print("错误：--all 累积结果超过 32MiB，请分页拉取（--next=）\n", .{});
                            return error.OutputTooLarge;
                        };
                    }
                    acc_first = false;
                    acc.print("{f}", .{std.json.fmt(it, .{})}) catch {
                        try c.out.print("错误：--all 累积结果超过 32MiB，请分页拉取（--next=）\n", .{});
                        return error.OutputTooLarge;
                    };
                }
            }
        } else {
            if (!header_printed) {
                try c.out.print("{s:<30} {s:<9} {s:<6} {s:<34} {s}\n", .{ "快照ID", "状态", "后端", "来源沙箱", "创建时间" });
                header_printed = true;
            }
            for (items) |it| try printSnapRow(c, it);
        }
        total += items.len;
        const nt = res.header("x-next-token") orelse "";
        if (!all or nt.len == 0 or std.mem.eql(u8, nt, token) or pages >= 500) break;
        token = nt;
    }

    if (a.has("json")) {
        if (all) {
            try c.out.print("[{s}]\n", .{acc.buffered()});
        } else if (last) |res| {
            try c.out.print("{s}\n", .{res.body});
        }
        return;
    }
    try c.out.print("共 {d} 条\n", .{total});
    if (!all) {
        if (last) |res| {
            if (res.header("x-next-token")) |nt| {
                if (nt.len > 0) {
                    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 2048));
                    try w.writeAll("下一页: cube-cli snap-ls");
                    if (a.get("sandbox")) |s| try w.print(" --sandbox={s}", .{s});
                    if (a.get("backend")) |b| try w.print(" --backend={s}", .{b});
                    if (page_limit > 0) try w.print(" --limit={d}", .{page_limit});
                    try w.print(" --next={s}（或加 --all 自动翻页）\n", .{nt});
                    try c.out.print("{s}", .{w.buffered()});
                }
            }
        }
    }
}

/// 组装 /snapshots 查询串（sandboxID / backend / limit / nextToken）。
fn snapLsPath(c: *Ctx, a: util.Args, limit: u32, token: []const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 4096));
    try w.writeAll("/snapshots");
    var sep: u8 = '?';
    if (a.get("sandbox")) |s| {
        try w.print("{c}sandboxID={s}", .{ sep, try jsonfmt.qenc(c.arena, s, false) });
        sep = '&';
    }
    if (a.get("backend")) |b| {
        try w.print("{c}backend={s}", .{ sep, try jsonfmt.qenc(c.arena, b, false) });
        sep = '&';
    }
    if (limit > 0) {
        try w.print("{c}limit={d}", .{ sep, limit });
        sep = '&';
    }
    if (token.len > 0) {
        try w.print("{c}nextToken={s}", .{ sep, try jsonfmt.qenc(c.arena, token, false) });
        sep = '&';
    }
    return w.buffered();
}

/// 解析快照列表响应：裸数组（本部署）或 {"data":[...]}（新版上游）都吃。
fn snapItems(c: *Ctx, body: []const u8) ![]const std.json.Value {
    const v = std.json.parseFromSlice(std.json.Value, c.arena, body, .{}) catch {
        try c.out.print("JSON 解析失败: {s}\n", .{body[0..@min(body.len, 300)]});
        return error.BadJson;
    };
    switch (v.value) {
        .array => |arr| return arr.items,
        .object => |o| {
            if (o.get("data")) |d| {
                if (d == .array) return d.array.items;
            }
        },
        else => {},
    }
    return &.{};
}

fn snapField(c: *Ctx, item: std.json.Value, key: []const u8) []const u8 {
    const x = jsonfmt.objGet(item, key) orelse return "-";
    return jsonfmt.valueStr(c.arena, x) catch "-";
}

fn printSnapRow(c: *Ctx, item: std.json.Value) !void {
    try c.out.print("{s:<30} {s:<9} {s:<6} {s:<34} {s}\n", .{
        snapField(c, item, "snapshotID"),
        snapField(c, item, "status"),
        snapField(c, item, "backend"),
        snapField(c, item, "originSandboxID"),
        snapField(c, item, "createdAt"),
    });
}

/// snap-rm <snapshotID>   —— 走模板删除接口
fn cmdSnapRm(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{id});
    _ = try c.control(.DELETE, path, null, buf);
    try c.out.print("snapshot removed {s}\n", .{id});
}

/// rollback <sid> <snapshotID> [--json] [--wait] [--timeout=秒]
fn cmdRollback(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const snap = a.at(1) orelse return error.MissingArg;
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/rollback", .{sid});
    const body = try std.fmt.allocPrint(c.arena, "{{\"snapshotID\":\"{s}\"}}", .{try envd.jsonEscape(c.arena, snap)});
    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.controlRaw(.POST, path, body, &.{}, buf);
    if (!res.ok()) {
        if (res.status == 404) {
            try c.out.print("沙箱或快照不存在（{s} ← {s}）\n", .{ sid, snap });
        } else if (res.status == 409) {
            try c.out.print("回滚冲突：可能有进行中的生命周期操作，稍后重试（HTTP 409）\n", .{});
        } else {
            try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        }
        return error.HttpError;
    }
    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
    } else {
        const op = envd.extractString(c.arena, res.body, "operationID") orelse "-";
        const st = envd.extractString(c.arena, res.body, "status") orelse "-";
        try c.out.print("已回滚 {s} ← {s}\n", .{ sid, snap });
        try c.out.print("operationID: {s}\nstatus: {s}\n", .{ op, st });
    }
    if (a.has("wait")) {
        var limit_s: u64 = 60;
        if (a.get("timeout")) |t| limit_s = std.fmt.parseInt(u64, t, 10) catch 60;
        waitStateQuiet(c, sid, "running", limit_s, a.has("json")) catch |e| return e;
    }
}

/// clone <sid> [--n=N|-n=N] [--concurrency=C] [--timeout=秒] [--note=名]
///       [--keep-snapshot] [--no-rollback-on-fail]
/// 快照作模板批量克隆；默认串行、失败回滚已创建克隆体、结束后删快照。
fn cmdClone(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    var n: usize = 1;
    if (a.get("n") orelse shortEq(a, "n")) |v| {
        n = std.fmt.parseInt(usize, v, 10) catch {
            try c.out.print("错误：--n= 需要正整数（收到 {s}）\n", .{v});
            return error.BadArg;
        };
    }
    if (n == 0) n = 1;
    var conc: usize = 1;
    if (a.get("concurrency")) |v| {
        conc = std.fmt.parseInt(usize, v, 10) catch {
            try c.out.print("错误：--concurrency= 需要正整数（收到 {s}）\n", .{v});
            return error.BadArg;
        };
    }
    if (conc == 0) conc = 1;
    if (conc > n) conc = n;

    var timeout_part: []const u8 = "";
    if (a.get("timeout")) |t| {
        const tv = std.fmt.parseInt(i64, t, 10) catch {
            try c.out.print("错误：--timeout= 需要整数秒（收到 {s}）\n", .{t});
            return error.BadArg;
        };
        timeout_part = try std.fmt.allocPrint(c.arena, ",\"timeout\":{d}", .{tv});
    }

    // ① 打快照
    const buf = try c.arena.alloc(u8, BUF);
    const spath = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/snapshots", .{sid});
    const sres = try c.control(.POST, spath, "{}", buf);
    const snap = envd.extractString(c.arena, sres.body, "snapshotID") orelse {
        try c.out.print("快照创建失败: {s}\n", .{sres.body});
        return error.SnapshotFailed;
    };
    std.debug.print("[clone] 快照 {s}（模板 {s}，共 {d} 个，并发 {d}）\n", .{ snap, sid, n, conc });

    // ② 快照当模板，建 n 个（受 --concurrency 限制）
    const meta = try cloneMetaPart(c, a);
    const body = try std.fmt.allocPrint(c.arena, "{{\"templateID\":\"{s}\"{s}{s}}}", .{ snap, timeout_part, meta });

    const results = try c.arena.alloc([]const u8, n);
    for (results) |*r| r.* = "";
    const errs = try c.arena.alloc(ErrSlot, n);
    for (errs) |*e| e.* = .{};
    var next_idx = std.atomic.Value(usize).init(0);
    var abort = std.atomic.Value(bool).init(false);
    var job = CloneJob{
        .io = c.io,
        .api = c.api,
        .key = c.key,
        .body = body,
        .n = n,
        .results = results,
        .errs = errs,
        .next = &next_idx,
        .abort = &abort,
    };

    if (conc <= 1) {
        cloneWorker(&job);
    } else {
        const threads = try c.arena.alloc(std.Thread, conc);
        var spawned: usize = 0;
        for (0..conc) |_| {
            threads[spawned] = std.Thread.spawn(.{}, cloneWorker, .{&job}) catch break;
            spawned += 1;
        }
        if (spawned == 0) {
            // 线程起不来就退回串行
            cloneWorker(&job);
        } else {
            for (threads[0..spawned]) |t| t.join();
        }
    }

    var ok_count: usize = 0;
    var failed = false;
    for (results) |r| {
        if (r.len > 0) ok_count += 1 else failed = true;
    }
    if (failed) {
        for (errs, 0..) |*e, i| {
            if (e.len > 0) try c.out.print("克隆失败[{d}]: {s}\n", .{ i + 1, e.text() });
        }
        // 回滚已创建的克隆体（默认开）
        const rollback = !a.has("no-rollback-on-fail");
        if (ok_count > 0 and rollback) {
            std.debug.print("[clone] 回滚已创建的 {d} 个克隆体…\n", .{ok_count});
            var rolled: usize = 0;
            for (results) |r| {
                if (r.len == 0) continue;
                if (killOne(c, r)) rolled += 1;
            }
            try c.out.print("已回滚 {d}/{d} 个克隆体\n", .{ rolled, ok_count });
            if (rolled < ok_count) try c.out.print("⚠ 有克隆体未能回滚，请用 `cube-cli ls` 检查后手动 rm\n", .{});
        } else if (ok_count > 0) {
            try c.out.print("--no-rollback-on-fail：保留已创建的 {d} 个克隆体：\n", .{ok_count});
            for (results) |r| {
                if (r.len > 0) try c.out.print("{s}\n", .{r});
            }
        }
        // 快照清理（默认删；--keep-snapshot 保留）
        if (a.has("keep-snapshot")) {
            try c.out.print("快照保留: {s}\n", .{snap});
        } else {
            _ = killTemplate(c, snap);
        }
        return error.CloneFailed;
    }

    // ③ 成功：打印全部 ID
    for (results) |r| try c.out.print("{s}\n", .{r});
    std.debug.print("[clone] 共创建 {d} 个克隆体\n", .{n});
    if (a.has("keep-snapshot")) {
        std.debug.print("[clone] 快照保留: {s}（--keep-snapshot）\n", .{snap});
    } else {
        if (!killTemplate(c, snap)) {
            std.debug.print("[clone] ⚠ 快照删除失败，请手动 `cube-cli snap-rm {s}`\n", .{snap});
        } else {
            std.debug.print("[clone] 快照已删除: {s}\n", .{snap});
        }
    }
}

/// 匹配 `-n=3` 这类单字符短选项（返回 `=` 之后的值；本 CLI 约定等号写法）。
fn shortEq(a: util.Args, key: []const u8) ?[]const u8 {
    if (key.len != 1) return null;
    for (a.pos) |p| {
        if (p.len >= 4 and p[0] == '-' and p[1] == key[0] and p[2] == '=') return p[3..];
    }
    return null;
}

/// 组克隆体 metadata（agent 取环境变量，note 取 --note 或 "<agent> · clone"）。
fn cloneMetaPart(c: *Ctx, a: util.Args) ![]const u8 {
    const agent = cfg.getenv("CUBESANDBOX_AGENT_NAME") orelse "cube-cli";
    const note = a.get("note") orelse try std.fmt.allocPrint(c.arena, "{s} · clone", .{agent});
    return try std.fmt.allocPrint(
        c.arena,
        ",\"metadata\":{{\"agent\":\"{s}\",\"note\":\"{s}\",\"cli\":\"cube-cli\"}}",
        .{ try envd.jsonEscape(c.arena, agent), try envd.jsonEscape(c.arena, note) },
    );
}

/// 单次克隆创建的错误现场（定长，跨线程可读写、无需分配）。
const ErrSlot = struct {
    len: usize = 0,
    buf: [320]u8 = undefined,

    fn set(self: *ErrSlot, comptime fmt: []const u8, args: anytype) void {
        var w = std.Io.Writer.fixed(&self.buf);
        w.print(fmt, args) catch {};
        self.len = w.buffered().len;
    }
    fn text(self: *const ErrSlot) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 克隆工作单元：主线程直接调用（并发=1）或由 cloneWorker 线程执行。
const CloneJob = struct {
    io: std.Io,
    api: []const u8,
    key: ?[]const u8,
    body: []const u8,
    n: usize,
    results: [][]const u8,
    errs: []ErrSlot,
    next: *std.atomic.Value(usize),
    abort: *std.atomic.Value(bool),
};

fn cloneWorker(job: *CloneJob) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = std.heap.smp_allocator, .io = job.io };
    defer client.deinit();

    while (!job.abort.load(.monotonic)) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.n) return;
        if (job.abort.load(.monotonic)) return;
        const buf = arena.alloc(u8, BUF) catch {
            job.errs[i].set("内存分配失败", .{});
            job.abort.store(true, .monotonic);
            return;
        };
        const url = std.fmt.allocPrint(arena, "{s}/sandboxes", .{ctxmod.trimSlash(job.api)}) catch {
            job.errs[i].set("URL 拼接失败", .{});
            job.abort.store(true, .monotonic);
            return;
        };
        var hs: [4]std.http.Header = undefined;
        var hn: usize = 0;
        hs[hn] = .{ .name = "Accept", .value = "application/json" };
        hn += 1;
        hs[hn] = .{ .name = "Content-Type", .value = "application/json" };
        hn += 1;
        if (job.key) |k| {
            hs[hn] = .{ .name = "Authorization", .value = std.fmt.allocPrint(arena, "Bearer {s}", .{k}) catch "" };
            hn += 1;
            hs[hn] = .{ .name = "X-API-Key", .value = k };
            hn += 1;
        }
        const res = httpc.request(&client, .POST, url, hs[0..hn], job.body, buf) catch |e| {
            job.errs[i].set("请求失败: {t}", .{e});
            job.abort.store(true, .monotonic);
            return;
        };
        if (!res.ok()) {
            job.errs[i].set("HTTP {d}: {s}", .{ res.status, res.body[0..@min(res.body.len, 200)] });
            job.abort.store(true, .monotonic);
            return;
        }
        if (envd.extractString(arena, res.body, "sandboxID")) |id| {
            job.results[i] = std.heap.smp_allocator.dupe(u8, id) catch "";
            if (job.results[i].len == 0) {
                job.errs[i].set("结果复制失败", .{});
                job.abort.store(true, .monotonic);
                return;
            }
        } else {
            job.errs[i].set("响应缺少 sandboxID: {s}", .{res.body[0..@min(res.body.len, 160)]});
            job.abort.store(true, .monotonic);
            return;
        }
    }
}

/// 删沙箱（用于回滚克隆体）：404 视为已删；503/409/408 按 Retry-After 重试。
fn killOne(c: *Ctx, id: []const u8) bool {
    const buf = c.arena.alloc(u8, BUF) catch return false;
    const path = std.fmt.allocPrint(c.arena, "/sandboxes/{s}", .{id}) catch return false;
    var attempt: u32 = 0;
    while (true) {
        const res = c.controlRaw(.DELETE, path, null, &.{}, buf) catch return false;
        if (res.ok() or res.status == 404) return true;
        const he = c.last_error;
        if (he.retryable() and attempt < 3) {
            const wait_s = he.retryAfter(2);
            if (wait_s > 0) std.Io.sleep(c.io, .fromSeconds(@intCast(wait_s)), .awake) catch {};
            attempt += 1;
            continue;
        }
        std.debug.print("[clone] 回滚 {s} 失败：HTTP {d} {s}\n", .{ id, res.status, res.body });
        return false;
    }
}

/// 删模板/快照（DELETE /templates/{id}）；404 视为已删。
fn killTemplate(c: *Ctx, id: []const u8) bool {
    const buf = c.arena.alloc(u8, BUF) catch return false;
    const path = std.fmt.allocPrint(c.arena, "/templates/{s}", .{id}) catch return false;
    const res = c.controlRaw(.DELETE, path, null, &.{}, buf) catch return false;
    if (res.ok() or res.status == 404) return true;
    std.debug.print("[clone] 删除 {s} 失败：HTTP {d} {s}\n", .{ id, res.status, res.body });
    return false;
}

/// vol-ls [--json]：卷列表（表格：卷ID / 名称）。
fn volLs(c: *Ctx, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.GET, "/volumes", null, buf);
    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    const v = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    var items: []const std.json.Value = &.{};
    switch (v.value) {
        .array => |arr| items = arr.items,
        .object => |o| {
            if (o.get("volumes")) |vv| {
                if (vv == .array) items = vv.array.items;
            }
        },
        else => {},
    }
    try c.out.print("{s:<40} {s}\n", .{ "卷ID", "名称" });
    for (items) |it| {
        const id = if (jsonfmt.objGet(it, "volumeID")) |x| jsonfmt.valueStr(c.arena, x) catch "-" else "-";
        const nm = if (jsonfmt.objGet(it, "name")) |x| jsonfmt.valueStr(c.arena, x) catch "-" else "-";
        try c.out.print("{s:<40} {s}\n", .{ id, nm });
    }
    try c.out.print("共 {d} 个\n", .{items.len});
}

/// vol-new [<名字>] [--driver=cos|s3|nfs|...] [--show-token] [--json]
/// 名字省略时由服务端生成 UUID。
fn volNew(c: *Ctx, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, BUF);
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 4096));
    try w.writeAll("{");
    var comma = false;
    if (a.at(0)) |name| {
        if (name.len > 0) {
            try w.print("\"name\":\"{s}\"", .{try envd.jsonEscape(c.arena, name)});
            comma = true;
        }
    }
    if (a.get("driver")) |d| {
        if (comma) try w.writeAll(",");
        try w.print("\"driver\":\"{s}\"", .{try envd.jsonEscape(c.arena, d)});
        comma = true;
    }
    try w.writeAll("}");
    const res = try c.control(.POST, "/volumes", w.buffered(), buf);
    const show = a.has("show-token");
    if (a.has("json")) {
        try c.out.print("{s}\n", .{try maskTokenJson(c, res.body, show)});
        return;
    }
    const id = envd.extractString(c.arena, res.body, "volumeID") orelse "";
    const nm = envd.extractString(c.arena, res.body, "name") orelse "";
    const tok = envd.extractString(c.arena, res.body, "token") orelse "";
    try c.out.print("已创建卷: {s}\n", .{if (nm.len > 0) nm else id});
    try c.out.print("volumeID: {s}\n", .{id});
    if (show) {
        try c.out.print("Token: {s}\n", .{tok});
    } else {
        try c.out.print("Token: {s}\n", .{if (tok.len > 0) "***" else "（无）"});
        std.debug.print("[vol] Token 默认脱敏；加 --show-token 显示完整值\n", .{});
    }
}

/// vol-info <卷ID> [--show-token] [--json]（默认脱敏 token）
fn volInfo(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/volumes/{s}", .{id});
    const res = try c.control(.GET, path, null, buf);
    const show = a.has("show-token");
    if (a.has("json")) {
        try c.out.print("{s}\n", .{try maskTokenJson(c, res.body, show)});
        return;
    }
    const vid = envd.extractString(c.arena, res.body, "volumeID") orelse id;
    const nm = envd.extractString(c.arena, res.body, "name") orelse "-";
    const tok = envd.extractString(c.arena, res.body, "token") orelse "";
    try c.out.print("卷ID  : {s}\n", .{vid});
    try c.out.print("名称  : {s}\n", .{nm});
    if (show) {
        try c.out.print("Token : {s}\n", .{tok});
    } else {
        try c.out.print("Token : {s}\n", .{if (tok.len > 0) "***（已脱敏；--show-token 显示完整值）" else "（无）"});
    }
}

/// vol-rm <卷ID>：409 = 仍被沙箱挂载（refcount>0）→ 中文提示。
fn volRm(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/volumes/{s}", .{id});
    const res = try c.controlRaw(.DELETE, path, null, &.{}, buf);
    if (res.ok()) {
        try c.out.print("已删除卷 {s}\n", .{id});
        return;
    }
    if (res.status == 404) {
        try c.out.print("卷不存在（可能已删除）: {s}\n", .{id});
        return;
    }
    if (res.status == 409) {
        try c.out.print("无法删除：卷 {s} 仍被沙箱挂载（refcount>0）。\n先销毁所有挂载它的沙箱（`cube-cli ls` 找到后 `cube-cli rm <sandboxID>`），再删卷。\n", .{id});
        try c.out.print("服务端返回: {s}\n", .{res.body[0..@min(res.body.len, 300)]});
        return error.VolumeInUse;
    }
    try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
    return error.HttpError;
}

/// token 脱敏（--show-token 时原样返回）：解析 JSON 把 token 值换成 "***"；
/// 解析失败时退回字符串扫描兜底。
fn maskTokenJson(c: *Ctx, body: []const u8, show: bool) ![]const u8 {
    if (show) return body;
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, body, .{}) catch {
        return maskTokenRaw(c, body);
    };
    var v = parsed.value;
    if (v == .object) {
        if (v.object.getPtr("token")) |tp| tp.* = .{ .string = "***" };
    }
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    w.print("{f}", .{std.json.fmt(v, .{})}) catch {
        return maskTokenRaw(c, body);
    };
    return w.buffered();
}

fn maskTokenRaw(c: *Ctx, body: []const u8) ![]const u8 {
    const pat = "\"token\":\"";
    const start = std.mem.indexOf(u8, body, pat) orelse return body;
    const s0 = start + pat.len;
    var e = s0;
    while (e < body.len and body[e] != '"') : (e += 1) {}
    return try std.fmt.allocPrint(c.arena, "{s}***{s}", .{ body[0..s0], body[e..] });
}

/// 轮询沙箱状态直到目标态（默认消息走 stdout）。
fn waitState(c: *Ctx, sid: []const u8, target: []const u8, limit_s: u64) !void {
    return waitStateQuiet(c, sid, target, limit_s, false);
}

/// quiet=true 时全部消息走 stderr（--json 模式不污染 stdout）。
fn waitStateQuiet(c: *Ctx, sid: []const u8, target: []const u8, limit_s: u64, quiet: bool) !void {
    var waited: u64 = 0;
    while (true) {
        const buf = try c.arena.alloc(u8, BUF);
        const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}", .{sid});
        const res = try c.control(.GET, path, null, buf);
        const st = stateOf(c, res.body) orelse "";
        if (std.ascii.eqlIgnoreCase(st, target)) {
            if (quiet) {
                std.debug.print("[wait] {s} 已进入 {s}\n", .{ sid, target });
            } else {
                try c.out.print("已进入 {s}: {s}\n", .{ target, sid });
            }
            return;
        }
        if (waited >= limit_s) {
            if (quiet) {
                std.debug.print("[wait] 超时 {d}s：{s} 未进入 {s}（当前 {s}）\n", .{ limit_s, sid, target, st });
            } else {
                try c.out.print("超时 {d}s：{s} 未进入 {s}（当前 {s}）\n", .{ limit_s, sid, target, st });
            }
            return error.WaitTimeout;
        }
        std.debug.print("[wait] 等待 {s}（当前 {s}，{d}/{d}s）\n", .{ target, st, waited, limit_s });
        try std.Io.sleep(c.io, .fromSeconds(2), .awake);
        waited += 2;
    }
}

fn stateOf(c: *Ctx, body: []const u8) ?[]const u8 {
    const v = std.json.parseFromSlice(std.json.Value, c.arena, body, .{}) catch return null;
    const s = jsonfmt.objGet(v.value, "state") orelse return null;
    if (s != .string) return null;
    return s.string;
}

fn qstr(c: *Ctx, s: []const u8) ![]const u8 {
    const e = try envd.jsonEscape(c.arena, s);
    const q = "\"";
    return try std.fmt.allocPrint(c.arena, "{s}{s}{s}", .{ q, e, q });
}
/// net <sid> [--no-internet] [--allow=域1,域2] [--deny=域1,域2]
/// 更新沙箱网络策略（PUT /sandboxes/<id>/network，204 即成功）。
/// net <sid> [--no-internet|--internet] [--allow=a,b] [--deny=a,b]
///        [--clear-allow] [--clear-deny] [--public=allow|deny] [--mask-host=1]
///        [--print] [--yes]
/// 平台语义：PUT 是「全量替换」，未出现的字段会被重置为默认值。
/// kv 追加 "key":value，逗号由 body 是否还是 "{" 决定
fn kv(c: *Ctx, body: []const u8, key: []const u8, val: []const u8) ![]const u8 {
    const comma: []const u8 = if (std.mem.eql(u8, body, "{")) "" else ",";
    return try std.fmt.allocPrint(c.arena, "{s}{s}\"{s}\":{s}", .{ body, comma, key, val });
}

/// net <sid> [--no-internet|--internet] [--allow=a,b] [--deny=a,b] [--clear-allow]
///        [--clear-deny] [--public=allow|deny] [--mask-host=1] [--print] [--yes]
/// 平台语义：PUT /sandboxes/<id>/network 是全量替换，未出现的字段被重置为默认。
fn cmdNet(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    var body: []const u8 = "{";
    var internet: ?bool = null;
    if (a.has("no-internet")) internet = false;
    if (a.has("internet")) internet = true;
    if (internet) |v| body = try kv(c, body, "allowInternetAccess", if (v) "true" else "false");
    body = try netArr(c, a, body, "allowOut", "allow", "clear-allow");
    body = try netArr(c, a, body, "denyOut", "deny", "clear-deny");
    if (a.get("public")) |v| body = try kv(c, body, "allowPublicTraffic", if (std.mem.eql(u8, v, "allow")) "true" else "false");
    if (a.get("mask-host")) |v| body = try kv(c, body, "maskRequestHost", try qstr(c, v));
    body = try std.fmt.allocPrint(c.arena, "{s}}}", .{body});
    std.debug.print("[net] 将 PUT /sandboxes/{s}/network ← {s}\n", .{ sid, body });
    const relaxed = a.has("internet");
    if (internet == null) std.debug.print("[net] ⚠ 未指定 --internet/--no-internet：该字段会被重置为默认（=允许公网访问）\n", .{}) else if (relaxed) std.debug.print("[net] ⚠ --internet 属放宽出网限制的操作\n", .{});
    if (a.has("print")) {
        std.debug.print("[net] --print：仅显示，未发送\n", .{});
        return;
    }
    if ((internet == null or relaxed) and !a.has("yes")) {
        try c.out.print("已阻止：上游 PUT 是全量替换语义，缺 allowInternetAccess 会静默恢复公网访问；--internet 属放宽操作。\n确认要按上面内容覆盖策略就加 --yes；只想看就加 --print。\n", .{});
        return error.NeedsConfirm;
    }
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/network", .{sid});
    const buf = try c.arena.alloc(u8, 2 << 20);
    _ = try c.control(.PUT, path, body, buf);
    try c.out.print("network updated（{s}）← {s}\n", .{ sid, body });
}

fn netArr(c: *Ctx, a: util.Args, body: []const u8, key: []const u8, flag: []const u8, clear: []const u8) ![]const u8 {
    if (a.get(flag)) |v| {
        var out: []const u8 = "";
        var it = std.mem.tokenizeScalar(u8, v, ',');
        var f2 = true;
        while (it.next()) |tok| {
            out = try std.fmt.allocPrint(c.arena, "{s}{s}\"{s}\"", .{ out, if (f2) "" else ",", try envd.jsonEscape(c.arena, tok) });
            f2 = false;
        }
        return try kv(c, body, key, try std.fmt.allocPrint(c.arena, "[{s}]", .{out}));
    }
    if (a.has(clear)) return try kv(c, body, key, "[]");
    return body;
}


fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "pause")) {
        try cmdPause(c, a);
        return true;
    }
    if (eq(cmd, "resume")) {
        try cmdResume(c, a);
        return true;
    }
    if (eq(cmd, "timeout")) {
        try cmdTimeout(c, a);
        return true;
    }
    if (eq(cmd, "refresh")) {
        try cmdRefresh(c, a);
        return true;
    }
    if (eq(cmd, "net")) {
        try cmdNet(c, a);
        return true;
    }
    if (eq(cmd, "snap")) {
        try cmdSnap(c, a);
        return true;
    }
    if (eq(cmd, "snap-ls")) {
        try cmdSnapLs(c, a);
        return true;
    }
    if (eq(cmd, "snap-rm")) {
        try cmdSnapRm(c, a);
        return true;
    }
    if (eq(cmd, "rollback")) {
        try cmdRollback(c, a);
        return true;
    }
    if (eq(cmd, "clone")) {
        try cmdClone(c, a);
        return true;
    }
    if (eq(cmd, "vol-ls")) {
        try volLs(c, a);
        return true;
    }
    if (eq(cmd, "vol-new")) {
        try volNew(c, a);
        return true;
    }
    if (eq(cmd, "vol-info")) {
        try volInfo(c, a);
        return true;
    }
    if (eq(cmd, "vol-rm")) {
        try volRm(c, a);
        return true;
    }
    return false;
}
