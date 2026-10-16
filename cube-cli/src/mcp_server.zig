//! MCP 门面：stdio + JSON-RPC 2.0 服务循环。
//!
//! **stdout 纪律**：只有本文件写 stdout，且只写「完整一行 JSON-RPC 消息 + 换行 + flush」。
//! 任何日志/诊断走 stderr（std.debug.print），stdout 永远不出现 banner/进度/调试。
//!
//! 分帧：一行一条消息（NDJSON）。读侧用 `takeDelimiter('\n')`——它阻塞到分隔符到达
//! （普通 read 语义，走 os.read 而非 sendfile/splice），是交互式管道唯一可用的原语；
//! `readSliceShort` / `readVec` 会等到缓冲区填满，会把交互式客户端卡死。
//!
//! 支持：initialize / notifications/initialized / ping / tools/list / tools/call。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const registry = @import("mcp_tools.zig");
const cfg = @import("cfg.zig");

/// 单条消息上限（读取缓冲容量）：超出回 -32600 并丢弃该行，服务不中断。
const max_line_bytes: usize = 32 << 20;
const err_msg_max: usize = 4000;

pub const Options = struct {
    verbose: bool = false,
};

const instructions =
    "本服务把 CubeSandbox 控制面/数据面能力暴露为 MCP 工具（沙箱生命周期、执行、文件、模板、卷、快照、PTY）。\\n" ++
    "配置经环境变量注入：CUBESANDBOX_API_URL / CUBESANDBOX_API_KEY / CUBESANDBOX_PROXY_URL。\\n" ++
    "破坏性工具（sandbox_delete 等）在 description 里已标注，请先与用户确认。\\n" ++
    "单条消息上限 32 MiB；长输出会被截断到 4 MiB，增量读取请用 offset 类参数。";

const Next = union(enum) {
    line: []u8,
    eof,
    too_large,
};

/// 服务主循环；返回进程退出码。
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    ov: sdkmod.Overrides,
    opts: Options,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const stdin_buf = try gpa.alloc(u8, max_line_bytes);
    defer gpa.free(stdin_buf);
    var stdin_r = std.Io.File.stdin().reader(io, stdin_buf);
    const r = &stdin_r.interface;

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_w.interface;

    if (opts.verbose) std.debug.print("[mcp] {s} mcp-server 就绪（stdio）\n", .{types.server_name});

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();

        const nxt = readLine(gpa, r) catch |e| {
            std.debug.print("[mcp] stdin 读取失败：{s}\n", .{@errorName(e)});
            return 1;
        };
        switch (nxt) {
            .eof => break,
            .too_large => {
                // 超限消息已整行丢弃，回协议错误后继续服务
                try writeError(a, out, null, -32600, "消息过大：单条 MCP 消息上限 32 MiB");
                continue;
            },
            .line => |line| {
                defer gpa.free(line);
                // handler 内部异常一律拦在 handleLine 里；能逃出来的只有 stdout 写失败（客户端断开）。
                handleLine(a, io, out, client, ov, opts, line) catch return 0;
            },
        }
    }

    out.flush() catch {};
    if (opts.verbose) std.debug.print("[mcp] stdin EOF，正常退出\n", .{});
    return 0;
}

/// 读一条完整消息（阻塞到 \n 到达）；空行跳过；EOF → .eof。
fn readLine(gpa: std.mem.Allocator, r: *std.Io.Reader) !Next {
    while (true) {
        const maybe = r.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                // 丢弃超长残行（unlimited 版本不会再次 StreamTooLong）
                _ = r.discardDelimiterExclusive('\n') catch return e;
                return .too_large;
            },
            else => return e,
        };
        const raw = maybe orelse return .eof;
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        return .{ .line = try gpa.dupe(u8, line) };
    }
}

fn handleLine(
    a: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    client: *std.http.Client,
    ov: sdkmod.Overrides,
    opts: Options,
    line: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch {
        try writeError(a, out, null, -32700, "Parse error：消息不是合法 JSON");
        return;
    };
    const v = parsed.value;
    switch (v) {
        .array => {
            try writeError(a, out, null, -32600, "不支持批处理（JSON-RPC batch not supported）");
            return;
        },
        .object => {},
        else => {
            try writeError(a, out, null, -32600, "Invalid Request：消息必须是 JSON 对象");
            return;
        },
    }
    const o = v.object;
    const id_opt = o.get("id");

    const jsonrpc_ok = blk: {
        const j = o.get("jsonrpc") orelse break :blk false;
        break :blk switch (j) {
            .string => |s| std.mem.eql(u8, s, "2.0"),
            else => false,
        };
    };
    const method: ?[]const u8 = blk: {
        const m = o.get("method") orelse break :blk null;
        break :blk switch (m) {
            .string => |s| s,
            else => null,
        };
    };
    if (!jsonrpc_ok or method == null) {
        try writeError(a, out, id_opt, -32600, "Invalid Request：jsonrpc 必须为 \"2.0\"，method 必须是字符串");
        return;
    }
    const m = method.?;
    const params = o.get("params");

    // 通知（无 id）：按 JSON-RPC 不得有任何响应。
    if (id_opt == null) {
        if (opts.verbose) std.debug.print("[mcp] 通知：{s}\n", .{m});
        return;
    }
    const id = id_opt.?;

    if (std.mem.eql(u8, m, "initialize")) {
        const pv = negotiateVersion(params);
        const res = try std.fmt.allocPrint(
            a,
            "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}},\"instructions\":\"{s}\"}}",
            .{ pv, types.server_name, cfg.version, instructions },
        );
        try writeRawResult(a, out, id, res);
        return;
    }
    if (std.mem.eql(u8, m, "ping")) {
        try writeRawResult(a, out, id, "{}");
        return;
    }
    if (std.mem.eql(u8, m, "tools/list")) {
        try writeToolsList(a, out, id);
        return;
    }
    if (std.mem.eql(u8, m, "tools/call")) {
        try handleToolsCall(a, io, out, client, ov, opts, id, params);
        return;
    }
    if (std.mem.startsWith(u8, m, "notifications/")) {
        if (opts.verbose) std.debug.print("[mcp] 忽略带 id 的通知：{s}\n", .{m});
        return;
    }
    try writeError(a, out, id, -32601, try std.fmt.allocPrint(a, "Method not found: {s}", .{m}));
}

/// 协议版本协商：客户端版本在支持集合内则原样回，否则回服务端最新。
fn negotiateVersion(params: ?std.json.Value) []const u8 {
    const latest = types.protocol_versions[0];
    const p = params orelse return latest;
    if (p != .object) return latest;
    const pv = p.object.get("protocolVersion") orelse return latest;
    const s = switch (pv) {
        .string => |x| x,
        else => return latest,
    };
    for (types.protocol_versions) |known| {
        if (std.mem.eql(u8, known, s)) return known;
    }
    return latest;
}

fn handleToolsCall(
    a: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    client: *std.http.Client,
    ov: sdkmod.Overrides,
    opts: Options,
    id: std.json.Value,
    params: ?std.json.Value,
) !void {
    const p = params orelse {
        try writeError(a, out, id, -32602, "Invalid params：tools/call 需要 params");
        return;
    };
    if (p != .object) {
        try writeError(a, out, id, -32602, "Invalid params：params 必须是对象");
        return;
    }
    const po = p.object;
    const name_v = po.get("name") orelse {
        try writeError(a, out, id, -32602, "Invalid params：缺少 name");
        return;
    };
    const name = switch (name_v) {
        .string => |s| s,
        else => {
            try writeError(a, out, id, -32602, "Invalid params：name 必须是字符串");
            return;
        },
    };
    const args_v: std.json.Value = po.get("arguments") orelse .null;
    switch (args_v) {
        .null, .object => {},
        else => {
            try writeError(a, out, id, -32602, "Invalid params：arguments 必须是对象");
            return;
        },
    }

    for (registry.tools) |t| {
        if (!std.mem.eql(u8, t.name, name)) continue;
        var sdk = sdkmod.Sdk.init(a, client, io, ov);
        var srv = types.Server{ .arena = a, .sdk = &sdk, .verbose = opts.verbose };
        var args = argmod.Args.init(args_v);
        if (opts.verbose) std.debug.print("[mcp] tools/call {s}\n", .{name});
        const res = t.handler(&srv, &args) catch |e| {
            // 参数校验失败（handler 里用 try 让 error.Arg 逃出来）→ 按协议给「可自纠正」的参数错误，
            // 而不是伪装成服务端崩溃（-32603）。
            if (e == error.Arg) {
                try writeToolResult(a, out, id, srv.argError(&args));
                return;
            }
            std.debug.print("[mcp] 工具 {s} 内部异常：{s}\n", .{ name, @errorName(e) });
            try writeError(a, out, id, -32603, try std.fmt.allocPrint(a, "Internal error：{s}", .{@errorName(e)}));
            return;
        };
        // 上游响应撑满缓冲 → 内容可能被截断，统一在结果里如实提示（避免 agent 用截断数据做判断）
        var final = res;
        if (sdk.last_truncated and !final.is_error and std.mem.indexOf(u8, final.text, "读取上限") == null) {
            final.text = try std.fmt.allocPrint(
                a,
                "{s}\n（注意：上游响应达到 {d} 字节读取上限，内容可能不完整；请用区间/分页参数缩小范围）",
                .{ final.text, sdkmod.BUF },
            );
        }
        try writeToolResult(a, out, id, final);
        return;
    }
    try writeError(a, out, id, -32602, try std.fmt.allocPrint(a, "Unknown tool: {s}", .{name}));
}

fn writeToolsList(a: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value) !void {
    // 容量按内容算：name/description 转义最坏 6 倍，schema 原样
    var need: usize = 64 + idCap(id);
    for (registry.tools) |t| need += t.name.len * 6 + t.description.len * 6 + t.schema.len + 64;
    var w = std.Io.Writer.fixed(try a.alloc(u8, need));
    try w.writeAll("{\"tools\":[");
    for (registry.tools, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try argmod.writeEscaped(&w, t.name);
        try w.writeAll("\",\"description\":\"");
        try argmod.writeEscaped(&w, t.description);
        try w.writeAll("\",\"inputSchema\":");
        try w.writeAll(t.schema);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    try writeRawResult(a, out, id, w.buffered());
}

fn writeToolResult(a: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, res: types.ToolResult) !void {
    const text = types.clampText(a, res.text);
    const cap = text.len * 6 + (if (res.image_b64) |b| b.len + 256 else 0) + 4096;
    var w = std.Io.Writer.fixed(try a.alloc(u8, cap));
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&w, id);
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
    try argmod.writeEscaped(&w, text);
    try w.writeAll("\"}");
    if (res.image_b64) |b64| {
        try w.writeAll(",{\"type\":\"image\",\"data\":\"");
        try w.writeAll(b64);
        try w.writeAll("\",\"mimeType\":\"");
        try argmod.writeEscaped(&w, res.image_mime);
        try w.writeAll("\"}");
    }
    try w.print("],\"isError\":{s}}}}}", .{if (res.is_error) "true" else "false"});
    try out.writeAll(w.buffered());
    try out.writeAll("\n");
    try out.flush();
}

fn writeRawResult(a: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, result_json: []const u8) !void {
    var w = std.Io.Writer.fixed(try a.alloc(u8, idCap(id) + 64));
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&w, id);
    try w.writeAll(",\"result\":");
    try out.writeAll(w.buffered());
    try out.writeAll(result_json);
    try out.writeAll("}\n");
    try out.flush();
}

/// id 序列化所需的缓冲（字符串 id 转义最坏 6 倍；大整数也留足）。
fn idCap(id: std.json.Value) usize {
    return switch (id) {
        .string => |sv| sv.len * 6 + 32,
        else => 32,
    };
}

fn writeError(a: std.mem.Allocator, out: *std.Io.Writer, id_opt: ?std.json.Value, code: i32, msg: []const u8) !void {
    const m = clampUtf8(msg, err_msg_max);
    const cap = m.len * 6 + idCap(id_opt orelse .null) + 128;
    var w = std.Io.Writer.fixed(try a.alloc(u8, cap));
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id_opt) |idv| try writeId(&w, idv) else try w.writeAll("null");
    try w.print(",\"error\":{{\"code\":{d},\"message\":\"", .{code});
    try argmod.writeEscaped(&w, m);
    try w.writeAll("\"}}\n");
    try out.writeAll(w.buffered());
    try out.flush();
}

fn writeId(w: *std.Io.Writer, id: std.json.Value) !void {
    switch (id) {
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            // 非有限浮点在 JSON 里没有合法字面量，只能退化为 null
            if (std.math.isFinite(f)) try w.print("{d}", .{f}) else try w.writeAll("null");
        },
        // 超出 i64 的整数 / 溢出的浮点数会被 std.json 解析成 number_string —— 必须原样回传（id 保真）
        .number_string => |ns| try w.writeAll(ns),
        .string => |s| {
            try w.writeAll("\"");
            try argmod.writeEscaped(w, s);
            try w.writeAll("\"");
        },
        else => try w.writeAll("null"),
    }
}

/// 截断到 n 字节，并回退到 UTF-8 字符边界，避免截出半个字符。
fn clampUtf8(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var e = n;
    while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1;
    return s[0..e];
}

comptime {
    @setEvalBranchQuota(50_000);
    // 保证工具名唯一（编译期门禁：重名直接编译失败）
    for (registry.tools, 0..) |t, i| {
        for (registry.tools[i + 1 ..]) |u| {
            if (std.mem.eql(u8, t.name, u.name)) @compileError("MCP 工具名重复: " ++ t.name);
        }
    }
}
