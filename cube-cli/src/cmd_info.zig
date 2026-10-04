//! info —— 沙箱详情（GET /sandboxes/<id>）。
//!
//! 打印：state / cpu / 内存 / 磁盘 / endAt / metadata（agent·task·note 显眼）/ volumeMounts / domain。
//! --wait=<目标态> 轮询到该状态（默认目标 running 由调用方给，缺省 120s 超时）。
const std = @import("std");
const httpc = @import("httpc.zig");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const jsonfmt = @import("jsonfmt.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

pub const help =
    \\info <sandboxID> [--json] [--wait=目标状态] [--timeout=秒]
    \\  沙箱详情：状态 / CPU / 内存 / 磁盘 / 回收时刻 / 归属标记 / 卷挂载 / 域名。
    \\  --wait=running 轮询直到进入目标状态（默认上限 120 秒，可 --timeout 调整）。
    \\  --json 原样输出接口 JSON。
;

/// 详情用 tolerant 解析：字段类型变化时退回原始 JSON，而不是整条命令失败。
const Detail = struct {
    sandboxID: ?[]const u8 = null,
    templateID: ?[]const u8 = null,
    state: []const u8 = "",
    cpuCount: ?i64 = null,
    cpuMilli: ?i64 = null,
    memoryMB: ?i64 = null,
    diskSizeMB: ?i64 = null,
    startedAt: ?std.json.Value = null,
    endAt: ?std.json.Value = null,
    domain: ?std.json.Value = null,
    metadata: ?std.json.Value = null,
    volumeMounts: ?std.json.Value = null,
};

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "info")) return false;
    try run(c, argv);
    return true;
}

fn fetch(c: *Ctx, sid: []const u8) !httpc.Response {
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}", .{sid});
    return c.control(.GET, path, null, buf);
}

pub fn run(c: *Ctx, argv: []const []const u8) !void {
    const a = try util.parse(c.arena, argv);
    const sid = a.at(0) orelse {
        try c.out.print("用法:\n{s}\n", .{help});
        return error.MissingArg;
    };

    // --host[=端口]：打印 domain 与 SDK get_host(port) 的虚拟域名（排障对照上游文档）
    if (a.get("host")) |hv| {
        const res0 = try fetch(c, sid);
        const parsed = std.json.parseFromSlice(Detail, c.arena, res0.body, .{ .ignore_unknown_fields = true }) catch {
            try c.out.print("{s}\n", .{res0.body});
            return;
        };
        const domain: []const u8 = if (parsed.value.domain) |dv| (jsonfmt.valueStr(c.arena, dv) catch "-") else "-";
        if (std.mem.eql(u8, hv, "true")) {
            try jsonfmt.field(c.out, "域名", domain);
            const h = try std.fmt.allocPrint(c.arena, "49983-{s}.{s}", .{ sid, domain });
            try jsonfmt.field(c.out, "envd 虚拟域名", h);
            try c.out.print("（上游 SDK get_host 的 `<端口>-<沙箱ID>.<域名>` 形式；\n", .{});
            try c.out.print("  本部署没有该域名解析，实际数据面走 <CUBESANDBOX_PROXY_URL>/sandbox/<sid>/<端口>/ 路径路由。）\n", .{});
            return;
        }
        const port = std.fmt.parseInt(u16, hv, 10) catch {
            try c.out.print("--host 取值应为端口或留空：如 --host=49999\n", .{});
            return error.BadArg;
        };
        try c.out.print("{d}-{s}.{s}\n", .{ port, sid, domain });
        return;
    }

    const wait = a.get("wait");
    var limit_s: u64 = 120;
    if (a.get("timeout")) |t| limit_s = std.fmt.parseInt(u64, t, 10) catch 120;

    var res = try fetch(c, sid);
    if (wait) |target| {
        if (target.len == 0) {
            try c.out.print("错误：--wait 需要目标状态（如 --wait=running）\n", .{});
            return error.BadArg;
        }
        var waited: u64 = 0;
        while (waited < limit_s) {
            const st = stateOf(c, res.body) orelse "";
            if (std.mem.eql(u8, st, target)) break;
            std.debug.print("[info] 等待 {s}（当前 {s}，{d}/{d}s）\n", .{ target, st, waited, limit_s });
            try std.Io.sleep(c.io, .fromSeconds(2), .awake);
            waited += 2;
            res = try fetch(c, sid);
        }
        const st = stateOf(c, res.body) orelse "";
        if (!std.mem.eql(u8, st, target)) {
            try c.out.print("超时 {d}s：{s} 未进入 {s}（当前 {s}）\n", .{ limit_s, sid, target, st });
            return error.WaitTimeout;
        }
    }

    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    try printDetail(c, sid, res.body);
}

fn stateOf(c: *Ctx, body: []const u8) ?[]const u8 {
    const v = std.json.parseFromSlice(std.json.Value, c.arena, body, .{}) catch return null;
    const s = jsonfmt.objGet(v.value, "state") orelse return null;
    if (s != .string) return null;
    return s.string;
}

fn printDetail(c: *Ctx, sid: []const u8, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(Detail, c.arena, body, .{ .ignore_unknown_fields = true }) catch {
        try c.out.print("{s}\n", .{body});
        return;
    };
    const d = parsed.value;

    try jsonfmt.field(c.out, "沙箱", d.sandboxID orelse sid);
    try jsonfmt.field(c.out, "模板", d.templateID orelse "-");
    try jsonfmt.field(c.out, "状态", if (d.state.len == 0) "-" else d.state);
    if (d.cpuCount != null or d.cpuMilli != null) {
        const txt = try std.fmt.allocPrint(c.arena, "{s} 核（{s}）", .{
            if (d.cpuCount) |v| try std.fmt.allocPrint(c.arena, "{d}", .{v}) else "?",
            if (d.cpuMilli) |v| try std.fmt.allocPrint(c.arena, "{d}m", .{v}) else "?",
        });
        try jsonfmt.field(c.out, "CPU", txt);
    }
    try jsonfmt.field(c.out, "内存", if (d.memoryMB) |v| try std.fmt.allocPrint(c.arena, "{d} MB", .{v}) else "-");
    try jsonfmt.field(c.out, "磁盘", if (d.diskSizeMB) |v| try std.fmt.allocPrint(c.arena, "{d} MB", .{v}) else "-");
    try jsonfmt.field(c.out, "开始", if (d.startedAt) |v| jsonfmt.valueStr(c.arena, v) catch "-" else "—");
    try jsonfmt.field(c.out, "截止", if (d.endAt) |v| jsonfmt.valueStr(c.arena, v) catch "-" else "无回收期限");
    try jsonfmt.field(c.out, "域名", if (d.domain) |v| jsonfmt.valueStr(c.arena, v) catch "-" else "-");

    // metadata：agent / task / note 三个归属键显眼列在最前
    if (d.metadata) |mv| {
        if (mv == .object) {
            const order = [_][]const u8{ "note", "agent", "task" };
            var note: ?[]const u8 = null;
            for (order) |k| {
                const v = mv.object.get(k) orelse continue;
                const s = jsonfmt.valueStr(c.arena, v) catch "-";
                if (std.mem.eql(u8, k, "note")) note = s;
                try c.out.print("  {s:<8}{s}\n", .{ k, s });
            }
            if (note) |n| try jsonfmt.field(c.out, "归属", n);
            var it = mv.object.iterator();
            var rest: usize = 0;
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "note") or
                    std.mem.eql(u8, kv.key_ptr.*, "agent") or
                    std.mem.eql(u8, kv.key_ptr.*, "task")) continue;
                try c.out.print("  {s:<8}{s}\n", .{ kv.key_ptr.*, jsonfmt.valueStr(c.arena, kv.value_ptr.*) catch "-" });
                rest += 1;
            }
            if (rest == 0 and note == null) try c.out.print("  （无）\n", .{});
        } else {
            try jsonfmt.field(c.out, "metadata", jsonfmt.valueStr(c.arena, mv) catch "-");
        }
    } else {
        try c.out.print("归属        （无 metadata）\n", .{});
    }

    // volumeMounts
    if (d.volumeMounts) |vv| {
        if (vv == .array and vv.array.items.len > 0) {
            try c.out.print("卷挂载\n", .{});
            for (vv.array.items) |item| {
                const name = if (jsonfmt.objGet(item, "name")) |n| jsonfmt.valueStr(c.arena, n) catch "-" else "-";
                const p = if (jsonfmt.objGet(item, "path")) |n| jsonfmt.valueStr(c.arena, n) catch "-" else "-";
                try c.out.print("  {s:<10}{s}\n", .{ name, p });
            }
        } else {
            try jsonfmt.field(c.out, "卷挂载", "无");
        }
    } else {
        try jsonfmt.field(c.out, "卷挂载", "无");
    }
}