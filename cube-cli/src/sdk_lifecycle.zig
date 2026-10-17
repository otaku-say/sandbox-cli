//! Core SDK —— 沙箱生命周期域操作（控制面 REST）。
//!
//! 约定：所有函数返回**数据**（响应体 / 结构化结果），不打印、不 exit。
//! CLI 命令与 MCP 工具都从这里取能力。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const httpc = @import("httpc.zig");
const jsonfmt = @import("jsonfmt.zig");
const envd = @import("envd.zig");
const cfg = @import("cfg.zig");

const Sdk = sdkmod.Sdk;

// ---------------- ls ----------------

pub const ListQuery = struct {
    metadata: []const []const u8 = &.{},
    state: ?[]const u8 = null,
    limit: ?[]const u8 = null,
    v2: bool = false,
};

/// GET /sandboxes（v1）或 /v2/sandboxes（v2）。返回响应体（调用方决定渲染方式）。
pub fn sandboxList(self: *Sdk, q: ListQuery) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    var n: usize = 0;
    for (q.metadata) |kv| {
        if (kv.len == 0) continue;
        if (n > 0) try w.writeAll("&");
        n += 1;
        try w.print("metadata={s}", .{try jsonfmt.qenc(self.arena, kv, true)});
    }
    if (q.state) |s| {
        if (n > 0) try w.writeAll("&");
        n += 1;
        try w.print("state={s}", .{try jsonfmt.qenc(self.arena, s, false)});
    }
    if (q.v2) {
        if (q.limit) |l| {
            if (n > 0) try w.writeAll("&");
            n += 1;
            try w.print("limit={s}", .{l});
        }
    }
    const base = if (q.v2) "/v2/sandboxes" else "/sandboxes";
    const path = if (n > 0)
        try std.fmt.allocPrint(self.arena, "{s}?{s}", .{ base, w.buffered() })
    else
        base;
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

// ---------------- 网关推断（agent 用得上：直接得到 aiod 的 SANDBOX_BASE） ----------------

/// 沙箱的 aiod 网关端口：与 CLI `new` 的提示同源（模板暴露端口 + guessGateway）；拿不到就退 8080。
pub fn gatewayPort(self: *Sdk, template_id: []const u8) u16 {
    const sdk_template = @import("sdk_template.zig");
    if (template_id.len == 0) return 8080;
    const detail = sdk_template.templateInfo(self, template_id) catch return 8080;
    const raw = envd.extractString(self.arena, detail, "com.exposed_ports") orelse return 8080;
    const ports = sdk_template.parsePorts(self.arena, raw) catch return 8080;
    const image = envd.extractString(self.arena, detail, "imageInfo") orelse "";
    const gw = sdk_template.guessGateway(ports, image);
    return if (gw == 0) 8080 else gw;
}

/// 沙箱的 aiod 数据面基址：`<proxy>/sandbox/<sid>/<端口>`；未配置 proxy 时返回空串。
pub fn sandboxBaseURL(self: *Sdk, sid: []const u8, template_id: []const u8) []const u8 {
    if (self.proxy.len == 0) return "";
    const port = gatewayPort(self, template_id);
    return std.fmt.allocPrint(self.arena, "{s}/sandbox/{s}/{d}", .{ self.proxy, sid, port }) catch "";
}

// ---------------- info ----------------

pub const InfoOptions = struct {
    /// 轮询到指定状态（如 running）；null = 不轮询。
    wait_state: ?[]const u8 = null,
    timeout_s: u64 = 120,
};

/// GET /sandboxes/<id>；可轮询到目标状态。返回最终响应体。
pub fn sandboxInfo(self: *Sdk, sid: []const u8, opt: InfoOptions) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    var res = try self.control(.GET, path, null, buf);
    if (opt.wait_state) |target| {
        var i: u64 = 0;
        var reached = false;
        if (stateOf(self.arena, res.body)) |s| {
            if (std.mem.eql(u8, s, target)) reached = true;
        }
        while (!reached and i < opt.timeout_s) : (i += 1) {
            try std.Io.sleep(self.io, .fromSeconds(1), .awake);
            res = try self.control(.GET, path, null, buf);
            if (stateOf(self.arena, res.body)) |s| {
                if (std.mem.eql(u8, s, target)) {
                    reached = true;
                    break;
                }
            }
        }
        if (!reached) return error.WaitTimeout;
    }
    return self.arena.dupe(u8, res.body);
}

fn stateOf(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return null;
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("state") orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---------------- create ----------------

pub const CreateOptions = struct {
    template: ?[]const u8 = null,
    need: []const u8 = "code",
    timeout: ?i64 = null,
    note: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    task: ?[]const u8 = null,
    env_vars: ?[]const u8 = null,
    volumes: []const []const u8 = &.{},
    lifecycle: ?[]const u8 = null,
    auto_resume: ?bool = null,
    no_internet: ?bool = null,
    distribution_scope: ?[]const u8 = null,
    mcp: ?[]const u8 = null,
};

pub const CreateResult = struct { body: []const u8, template_id: []const u8 };

/// 新建沙箱。挑不到 READY 模板时返回 error.TemplateUnavailable（不拿假 ID 硬发请求）。
pub fn sandboxCreate(self: *Sdk, opt: CreateOptions) !CreateResult {
    var tpl = opt.template orelse "";
    if (tpl.len > 0) {
        // 模板别名 → templateID（与 CLI `new --template=<别名>` 的服务端别名解析一致）；
        // 解析不到就原样透传，交给服务端处理。
        const sdk_template = @import("sdk_template.zig");
        if (sdk_template.resolveAliasRef(self, tpl)) |id| tpl = id;
    }
    if (tpl.len == 0) {
        const sdk_template = @import("sdk_template.zig");
        const picked = sdk_template.templatePick(self, opt.need) catch return error.TemplateUnavailable;
        tpl = picked.id;
        if (tpl.len == 0) return error.TemplateUnavailable;
    }

    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 64 << 10));
    try w.print("{{\"templateID\":\"{s}\"", .{try envd.jsonEscape(self.arena, tpl)});

    if (opt.timeout) |t| {
        try w.print(",\"timeout\":{d}", .{t});
    }

    const agent = opt.agent orelse cfg.getenv("CUBESANDBOX_AGENT_NAME") orelse "cube-cli";
    const note = opt.note orelse (if (opt.task) |tsk| try std.fmt.allocPrint(self.arena, "{s} · {s}", .{ agent, tsk }) else agent);
    try w.print(",\"metadata\":{{\"agent\":\"{s}\",\"note\":\"{s}\",\"cli\":\"cube-cli\"", .{
        try envd.jsonEscape(self.arena, agent),
        try envd.jsonEscape(self.arena, note),
    });
    if (opt.task) |tsk| {
        try w.print(",\"task\":\"{s}\"", .{try envd.jsonEscape(self.arena, tsk)});
    }
    try w.writeAll("}");

    if (opt.env_vars) |ev| {
        if (ev.len > 0) try w.print(",\"envVars\":{s}", .{ev});
    }
    if (opt.volumes.len > 0) {
        try w.writeAll(",\"volumeMounts\":[");
        for (opt.volumes, 0..) |v, i| {
            if (i > 0) try w.writeAll(",");
            const ci = std.mem.indexOfScalar(u8, v, ':');
            const name = if (ci) |idx| v[0..idx] else v;
            const path = if (ci) |idx| v[idx + 1 ..] else try std.fmt.allocPrint(self.arena, "/mnt/{s}", .{name});
            try w.print("{{\"name\":\"{s}\",\"path\":\"{s}\"}}", .{
                try envd.jsonEscape(self.arena, name),
                try envd.jsonEscape(self.arena, path),
            });
        }
        try w.writeAll("]");
    }
    if (opt.lifecycle) |lc| {
        const on = if (std.mem.eql(u8, lc, "pause")) "pause" else "kill";
        try w.print(",\"lifecycle\":{{\"onTimeout\":\"{s}\"", .{on});
        if (opt.auto_resume orelse false) try w.writeAll(",\"autoResume\":true");
        try w.writeAll("}");
    }
    if (opt.no_internet orelse false) {
        try w.writeAll(",\"allow_internet_access\":false");
    }
    if (opt.distribution_scope) |sc| {
        try w.writeAll(",\"distributionScope\":[");
        var it = std.mem.tokenizeScalar(u8, sc, ',');
        var first = true;
        while (it.next()) |tok| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\"", .{try envd.jsonEscape(self.arena, tok)});
        }
        try w.writeAll("]");
    }
    if (opt.mcp) |mcp| {
        try w.print(",\"mcp\":{s}", .{mcp});
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.POST, "/sandboxes", w.buffered(), buf);
    return .{ .body = try self.arena.dupe(u8, res.body), .template_id = tpl };
}

pub fn systemHealth(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, "/health", null, buf);
    return self.arena.dupe(u8, res.body);
}

// ---------------- pause / resume / refresh / timeout ----------------

pub fn sandboxPause(self: *Sdk, sid: []const u8) !void {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/pause", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    _ = try self.control(.POST, path, "{}", buf);
}

pub fn sandboxResume(self: *Sdk, sid: []const u8, timeout_s: ?u64) !void {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/resume", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const body = if (timeout_s) |t|
        try std.fmt.allocPrint(self.arena, "{{\"timeout\":{d}}}", .{t})
    else
        "{}";
    _ = try self.control(.POST, path, body, buf);
}

pub fn sandboxRefresh(self: *Sdk, sid: []const u8, duration_s: ?u64) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/refreshes", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const body = if (duration_s) |d|
        try std.fmt.allocPrint(self.arena, "{{\"duration\":{d}}}", .{d})
    else
        "{}";
    const res = try self.control(.POST, path, body, buf);
    return self.arena.dupe(u8, res.body);
}

pub fn sandboxSetTimeout(self: *Sdk, sid: []const u8, seconds: i64) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/timeout", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const body = try std.fmt.allocPrint(self.arena, "{{\"timeout\":{d}}}", .{seconds});
    const res = try self.control(.POST, path, body, buf);
    return self.arena.dupe(u8, res.body);
}

/// PUT /sandboxes/<id>/network（**全量替换语义**，body 与 CLI `net` 完全一致）。
pub const NetSpec = struct {
    internet: ?bool = null,
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    public: ?bool = null,
    mask_host: ?[]const u8 = null,
};

pub fn sandboxSetNet(self: *Sdk, sid: []const u8, spec: NetSpec) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/network", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 1 << 16));
    try w.writeAll("{");
    var comma = false;
    if (spec.internet) |v| {
        try w.print("\"allowInternetAccess\":{s}", .{if (v) "true" else "false"});
        comma = true;
    }
    if (spec.allow.len > 0) {
        if (comma) try w.writeAll(",");
        try w.writeAll("\"allowOut\":[");
        for (spec.allow, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{try envd.jsonEscape(self.arena, d)});
        }
        try w.writeAll("]");
        comma = true;
    }
    if (spec.deny.len > 0) {
        if (comma) try w.writeAll(",");
        try w.writeAll("\"denyOut\":[");
        for (spec.deny, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{try envd.jsonEscape(self.arena, d)});
        }
        try w.writeAll("]");
        comma = true;
    }
    if (spec.public) |v| {
        if (comma) try w.writeAll(",");
        try w.print("\"allowPublicTraffic\":{s}", .{if (v) "true" else "false"});
        comma = true;
    }
    if (spec.mask_host) |v| {
        if (comma) try w.writeAll(",");
        try w.print("\"maskRequestHost\":\"{s}\"", .{try envd.jsonEscape(self.arena, v)});
        comma = true;
    }
    try w.writeAll("}");
    const res = try self.control(.PUT, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

// ---------------- ports ----------------

pub fn sandboxPorts(self: *Sdk, sid: []const u8) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const probe_cmd = "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null";
    const res = try envd.exec(self.arena, self.client, dp.base, dp.token, null, probe_cmd, null, null, 10000, buf);
    if (res.exit_code != 0 and res.stdout.len == 0) {
        return "（未读到监听端口：沙箱服务可能未就绪）";
    }

    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 64 << 10));
    try w.print("{s:<6} {s:<16} {s:<6} {s}\n", .{ "端口", "绑定", "外部", "访问地址" });
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    var count: usize = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "sl")) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next() orelse continue;
        const local = it.next() orelse continue;
        const colon = std.mem.indexOfScalar(u8, local, ':') orelse continue;
        const hex_port = local[colon + 1 ..];
        const port = std.fmt.parseInt(u16, hex_port, 16) catch continue;
        if (port == 0) continue;
        const st = it.next() orelse continue;
        if (!std.mem.eql(u8, st, "0A")) continue;

        const is_local = std.mem.startsWith(u8, local, "0100007F") or std.mem.endsWith(u8, local[0..colon], "00000000000000000000000001000000");
        const ext = !is_local;
        const bind = if (is_local) "127.0.0.1" else "0.0.0.0";
        const ext_str = if (ext) "可连" else "-";
        count += 1;
        if (ext and self.proxy.len > 0) {
            try w.print("{d:<6} {s:<16} {s:<6} {s}/sandbox/{s}/{d}/\n", .{ port, bind, ext_str, self.proxy, sid, port });
        } else {
            try w.print("{d:<6} {s:<16} {s:<6} （仅沙箱内部）\n", .{ port, bind, ext_str });
        }
    }
    if (count == 0) {
        return "（未读到监听端口：刚创建的沙箱里服务可能还在启动，稍等再测）";
    }
    return w.buffered();
}

// ---------------- clone ----------------

pub const CloneOptions = struct {
    n: usize = 1,
    timeout: ?i64 = null,
    note: ?[]const u8 = null,
    keep_snapshot: bool = false,
};

pub fn sandboxClone(self: *Sdk, sid: []const u8, opt: CloneOptions) ![]const u8 {
    const sdk_snapshot = @import("sdk_snapshot.zig");
    const snap_body = try sdk_snapshot.snapshotCreate(self, sid, opt.note);
    const snap = envd.extractString(self.arena, snap_body, "snapshotID") orelse return error.SnapshotFailed;

    const n = if (opt.n == 0) 1 else opt.n;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 64 << 10));
    try w.print("快照: {s}\n克隆沙箱列表:\n", .{snap});

    const created = try self.arena.alloc([]const u8, n);
    for (0..n) |i| {
        const c_opt = CreateOptions{
            .template = snap,
            .timeout = opt.timeout,
            .note = opt.note,
        };
        const c_body = sandboxCreate(self, c_opt) catch |e| {
            for (created[0..i]) |csid| {
                _ = sandboxDelete(self, csid, true) catch {};
            }
            if (!opt.keep_snapshot) {
                _ = sdk_snapshot.snapshotDelete(self, snap) catch {};
            }
            return e;
        };
        const csid = envd.extractString(self.arena, c_body.body, "sandboxID") orelse snap;
        created[i] = csid;
        try w.print("  {d}: {s}\n", .{ i + 1, csid });
    }

    if (!opt.keep_snapshot) {
        _ = sdk_snapshot.snapshotDelete(self, snap) catch {};
    }

    return w.buffered();
}

// ---------------- rm（带生命周期互斥重试） ----------------

pub const DeleteResult = enum { deleted, already_gone };

pub fn sandboxDelete(self: *Sdk, sid: []const u8, allow_retry: bool) !DeleteResult {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    var attempt: u32 = 0;
    while (true) {
        const res = try self.controlRaw(.DELETE, path, null, &.{}, buf);
        if (res.ok()) return .deleted;
        if (res.status == 404) return .already_gone;
        const status = res.status;
        const body = try self.arena.dupe(u8, res.body);
        if (allow_retry and (status == 503 or status == 409 or status == 408) and attempt < 3) {
            var wait_s: u64 = 2;
            if (res.header("Retry-After")) |v| {
                wait_s = @min(std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch 2, 30);
            }
            attempt += 1;
            if (wait_s > 0) try std.Io.sleep(self.io, .fromSeconds(@intCast(wait_s)), .awake);
            continue;
        }
        self.last_status = status;
        self.last_body = body;
        return error.HttpError;
    }
}
