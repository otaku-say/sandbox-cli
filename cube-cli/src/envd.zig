//! envd 客户端：进程执行。
//!
//! 协议（E2B 兼容）：
//!   POST {envd}/process.Process/Start
//!   Content-Type: application/connect+json, Connect-Protocol-Version: 1
//!   Authorization: Basic base64("<user>:")
//!   body = Connect envelope(5 字节头 + JSON)
//!   响应 = envelope 流：{event:{start|data|end}}，data 的 stdout/stderr 是 base64
const std = @import("std");
const httpc = @import("httpc.zig");
const connect = @import("connect.zig");

pub const Result = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: i32 = 0,
    pid: i32 = 0,
};

/// JSON 字符串转义（不依赖 std.json 的 Stringify，行为可控）。
pub fn jsonEscape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var n: usize = 0;
    for (s) |c| {
        n += switch (c) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => if (c < 0x20) 6 else 1,
        };
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |c| {
        switch (c) {
            '"' => {
                out[i] = '\\';
                out[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                out[i] = '\\';
                out[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                out[i] = '\\';
                out[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                out[i] = '\\';
                out[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                out[i] = '\\';
                out[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    _ = std.fmt.bufPrint(out[i .. i + 6], "\\u{x:0>4}", .{c}) catch {};
                    i += 6;
                } else {
                    out[i] = c;
                    i += 1;
                }
            },
        }
    }
    return out[0..i];
}

/// Basic base64("<user>:")，user 缺省 root。
pub fn basicUser(arena: std.mem.Allocator, user: ?[]const u8) ![]const u8 {
    const u = user orelse "root";
    const raw = try std.fmt.allocPrint(arena, "{s}:", .{u});
    const dest = try arena.alloc(u8, raw.len * 2 + 8);
    const b64 = std.base64.standard.Encoder.encode(dest, raw);
    return std.fmt.allocPrint(arena, "Basic {s}", .{b64});
}

fn appendTo(dst: []u8, len: *usize, src: []const u8) !void {
    if (len.* + src.len > dst.len) return error.OutputTooLarge;
    @memcpy(dst[len.* .. len.* + src.len], src);
    len.* += src.len;
}

fn b64decode(dst: []u8, len: *usize, encoded: []const u8) void {
    const n = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return;
    if (len.* + n > dst.len) return;
    const out = dst[len.*..][0..n];
    std.base64.standard.Decoder.decode(out, encoded) catch return;
    len.* += n;
}

/// 执行一条命令，汇总 stdout/stderr/exitCode。
pub fn exec(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    cmd: []const u8,
    cwd: ?[]const u8,
    envs_json: ?[]const u8,
    timeout_ms: u64,
    buf: []u8,
) !Result {
    const esc = try jsonEscape(arena, cmd);
    var cwd_json: []const u8 = "";
    if (cwd) |c| {
        const ce = try jsonEscape(arena, c);
        cwd_json = try std.fmt.allocPrint(arena, ",\"cwd\":\"{s}\"", .{ce});
    }
    const payload = try std.fmt.allocPrint(
        arena,
        "{{\"process\":{{\"cmd\":\"/bin/bash\",\"args\":[\"-l\",\"-c\",\"{s}\"],\"envs\":{{{s}}}{s}}},\"stdin\":false}}",
        .{ esc, envs_json orelse "", cwd_json },
    );

    const framed_buf = try arena.alloc(u8, 5 + payload.len);
    const framed = try connect.encode(payload, framed_buf);

    const url = try std.fmt.allocPrint(arena, "{s}/process.Process/Start", .{envd_base});

    var hs: [5]std.http.Header = undefined;
    var n: usize = 0;
    hs[n] = .{ .name = "Content-Type", .value = connect.content_type };
    n += 1;
    hs[n] = .{ .name = "Connect-Protocol-Version", .value = connect.protocol_version };
    n += 1;
    // 与 SDK 对齐：timeout <= 0 时不发 Connect-Timeout-Ms（= 无硬截止）；
    // 给了正数才作为 envd 侧的硬截止（毫秒）。
    if (timeout_ms > 0) {
        hs[n] = .{ .name = "Connect-Timeout-Ms", .value = try std.fmt.allocPrint(arena, "{d}", .{timeout_ms}) };
        n += 1;
    }
    if (token) |t| {
        hs[n] = .{ .name = "X-Access-Token", .value = t };
        n += 1;
    }
    hs[n] = .{ .name = "Authorization", .value = try basicUser(arena, user) };
    n += 1;

    const res = try httpc.request(client, .POST, url, hs[0..n], framed, buf);
    if (!res.ok()) return error.HttpError;

    // 解析响应流
    var out_buf = try arena.alloc(u8, 4 << 20);
    var err_buf = try arena.alloc(u8, 1 << 20);
    var out_len: usize = 0;
    var err_len: usize = 0;
    var exit_code: i32 = 0;
    var pid: i32 = 0;

    var stream = connect.Stream{ .buf = res.body };
    while (try stream.next()) |env| {
        if (env.flag & connect.end_stream_flag != 0) continue;
        // 用最简解析：直接找字段
        if (std.mem.indexOf(u8, env.payload, "\"pid\"")) |_| {
            if (extractInt(env.payload, "pid")) |v| pid = v;
        }
        if (std.mem.indexOf(u8, env.payload, "\"exitCode\"")) |_| {
            if (extractInt(env.payload, "exitCode")) |v| exit_code = v;
        }
        if (std.mem.indexOf(u8, env.payload, "\"stdout\"")) |_| {
            if (extractString(arena, env.payload, "stdout")) |v| {
                b64decode(out_buf, &out_len, v);
            }
        }
        if (std.mem.indexOf(u8, env.payload, "\"stderr\"")) |_| {
            if (extractString(arena, env.payload, "stderr")) |v| {
                b64decode(err_buf, &err_len, v);
            }
        }
    }

    return .{
        .stdout = out_buf[0..out_len],
        .stderr = err_buf[0..err_len],
        .exit_code = exit_code,
        .pid = pid,
    };
}

/// 从 JSON 片段里取某个整数字段（粗粒度扫描；字段值只可能是整数）。
pub fn extractInt(payload: []const u8, field: []const u8) ?i32 {
    var buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
    const start = std.mem.indexOf(u8, payload, pat) orelse return null;
    var i = start + pat.len;
    while (i < payload.len and payload[i] == ' ') i += 1;
    var neg = false;
    if (i < payload.len and payload[i] == '-') {
        neg = true;
        i += 1;
    }
    var val: i32 = 0;
    var any = false;
    while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {
        val = val * 10 + (payload[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -val else val;
}

/// 取字符串字段的原始值（不含引号）。
///
/// 用于 base64 载荷（stdout/stderr/pty）与 token —— base64 字符集不含引号与反斜杠，
/// 因此简单切片是安全的。
pub fn extractString(arena: std.mem.Allocator, payload: []const u8, field: []const u8) ?[]const u8 {
    const pat = std.fmt.allocPrint(arena, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, payload, pat) orelse return null;
    const s0 = start + pat.len;
    const end = std.mem.indexOfPos(u8, payload, s0, "\"") orelse return null;
    // 必须复制：payload 通常指向可复用的网络读缓冲，后续请求会把它覆盖掉，
    // 直接把切片交出去会在下一次请求后变成垃圾（曾导致网关 URL 出现乱码）。
    return arena.dupe(u8, payload[s0..end]) catch null;
}

// ---------------- 文件操作 ----------------

/// URL 编码（保留 `/`，便于路径拼接）。
pub fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        n += if (safe) 1 else 3;
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        if (safe) {
            out[i] = ch;
            i += 1;
        } else {
            out[i] = '%';
            out[i + 1] = hex[ch >> 4];
            out[i + 2] = hex[ch & 0x0F];
            i += 3;
        }
    }
    return out[0..i];
}

/// 文件操作通用头：Content-Type + Connect 版本 + 可选鉴权 / Basic 用户作用域。
fn fileHeaders(arena: std.mem.Allocator, ctype: []const u8, token: ?[]const u8, user: ?[]const u8, out: []std.http.Header) !httpc.Headers {
    var n: usize = 0;
    out[n] = .{ .name = "Content-Type", .value = ctype };
    n += 1;
    out[n] = .{ .name = "Connect-Protocol-Version", .value = connect.protocol_version };
    n += 1;
    if (token) |t| {
        out[n] = .{ .name = "X-Access-Token", .value = t };
        n += 1;
    }
    if (user) |u| {
        out[n] = .{ .name = "Authorization", .value = try basicUser(arena, u) };
        n += 1;
    }
    return out[0..n];
}

fn fileURL(arena: std.mem.Allocator, envd_base: []const u8, path: []const u8, user: ?[]const u8) ![]const u8 {
    if (user) |u| {
        return std.fmt.allocPrint(arena, "{s}/files?path={s}&username={s}", .{
            envd_base, try urlEncode(arena, path), try urlEncode(arena, u),
        });
    }
    return std.fmt.allocPrint(arena, "{s}/files?path={s}", .{ envd_base, try urlEncode(arena, path) });
}

/// 读文件（GET /files）。
pub fn readFile(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    path: []const u8,
    buf: []u8,
) !httpc.Response {
    const url = try fileURL(arena, envd_base, path, user);
    var hs: [4]std.http.Header = undefined;
    const headers = try fileHeaders(arena, "application/octet-stream", token, user, &hs);
    return httpc.get(client, url, headers, buf);
}

/// 写文件（POST /files，原始 octet-stream）。
pub fn writeFile(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    path: []const u8,
    data: []const u8,
    buf: []u8,
) !httpc.Response {
    const url = try fileURL(arena, envd_base, path, user);
    var hs: [4]std.http.Header = undefined;
    const headers = try fileHeaders(arena, "application/octet-stream", token, user, &hs);
    return httpc.request(client, .POST, url, headers, data, buf);
}

/// 文件系统 RPC（POST /filesystem.Filesystem/<Method>，请求体是纯 JSON）。
pub fn fsRPC(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    method: []const u8,
    json_body: []const u8,
    buf: []u8,
) !httpc.Response {
    const url = try std.fmt.allocPrint(arena, "{s}/filesystem.Filesystem/{s}", .{ envd_base, method });
    var hs: [4]std.http.Header = undefined;
    const headers = try fileHeaders(arena, "application/json", token, user, &hs);
    return httpc.request(client, .POST, url, headers, json_body, buf);
}

/// 带 Range 的文件读：GET /files?... + `Range: bytes=<off>-`。
/// 200 = 服务端忽略 Range（全量，调用方自行切片）；206 = 从 off 起的内容。
pub fn readFileRange(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    path: []const u8,
    off: u64,
    buf: []u8,
) !httpc.Response {
    const url = try fileURL(arena, envd_base, path, user);
    var hs: [5]std.http.Header = undefined;
    const headers = try fileHeaders(arena, "application/octet-stream", token, user, &hs);
    var hlen = headers.len;
    hs[hlen] = .{ .name = "Range", .value = try std.fmt.allocPrint(arena, "bytes={d}-", .{off}) };
    hlen += 1;
    return httpc.request(client, .GET, url, hs[0..hlen], null, buf);
}

// ---------------- 进程控制（异步 / PTY / 信号 / 输入 / 流） ----------------
//
// 全部对应 envd 的 process.Process 服务（Connect 协议）：
//   List / Start / Connect / Update / SendSignal / SendInput
// 实测结论（2026-10-04，envd 0.5.13）：
//   - Start 的响应流断开后，进程**继续运行**（可放大输出/输入）→ 异步执行的基础
//   - Connect 只能连**仍在运行**的 pid，且不重放断开期间产生的输出（envd 无缓冲）
//   - Connect-Timeout-Ms 头对该流生效：到点服务端发 deadline_exceeded 并关流
//     （= 客户端侧"有界读"的可靠做法）

/// 通用 unary 调用：POST {base}/<path>（JSON body，Connect unary 语义）。
pub fn call(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    path: []const u8,
    json_body: []const u8,
    buf: []u8,
) !httpc.Response {
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ envd_base, path });
    var hs: [4]std.http.Header = undefined;
    const headers = try fileHeaders(arena, "application/json", token, user, &hs);
    return httpc.request(client, .POST, url, headers, json_body, buf);
}

/// 运行中的进程列表（POST /process.Process/List）。
pub fn listProcs(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    buf: []u8,
) !httpc.Response {
    return call(arena, client, envd_base, token, user, "process.Process/List", "{}", buf);
}

/// 发信号（signal = "SIGNAL_SIGKILL" / "SIGNAL_SIGTERM"）。
pub fn sendSignal(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    pid: i64,
    signal: []const u8,
    buf: []u8,
) !httpc.Response {
    const body = try std.fmt.allocPrint(arena, "{{\"process\":{{\"pid\":{d}}},\"signal\":\"{s}\"}}", .{ pid, signal });
    return call(arena, client, envd_base, token, user, "process.Process/SendSignal", body, buf);
}

/// 发输入（kind = "stdin" / "pty"；data 原始字节，base64 后进 JSON）。
pub fn sendInput(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    pid: i64,
    kind: []const u8,
    data: []const u8,
    buf: []u8,
) !httpc.Response {
    const enc = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    _ = std.base64.standard.Encoder.encode(enc, data);
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"process\":{{\"pid\":{d}}},\"input\":{{\"{s}\":\"{s}\"}}}}",
        .{ pid, kind, enc },
    );
    return call(arena, client, envd_base, token, user, "process.Process/SendInput", body, buf);
}

/// 调整 PTY 大小（POST /process.Process/Update）。
pub fn updatePty(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    pid: i64,
    rows: u64,
    cols: u64,
    buf: []u8,
) !httpc.Response {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"process\":{{\"pid\":{d}}},\"pty\":{{\"size\":{{\"rows\":{d},\"cols\":{d}}}}}}}",
        .{ pid, rows, cols },
    );
    return call(arena, client, envd_base, token, user, "process.Process/Update", body, buf);
}

/// 启动并**立即分离**：读到响应体里第一个 `"pid"` 字段就断开连接（进程继续运行）。
/// 调用方从返回体里自行提取 pid（envd.extractInt(res.body, "pid")）。
pub fn startDetached(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    payload_json: []const u8,
    buf: []u8,
) !httpc.Response {
    const framed_buf = try arena.alloc(u8, 5 + payload_json.len);
    const framed = try connect.encode(payload_json, framed_buf);
    const url = try std.fmt.allocPrint(arena, "{s}/process.Process/Start", .{envd_base});

    var hs: [5]std.http.Header = undefined;
    var n: usize = 0;
    hs[n] = .{ .name = "Content-Type", .value = connect.content_type };
    n += 1;
    hs[n] = .{ .name = "Connect-Protocol-Version", .value = connect.protocol_version };
    n += 1;
    hs[n] = .{ .name = "Connect-Content-Encoding", .value = "identity" };
    n += 1;
    if (token) |t| {
        hs[n] = .{ .name = "X-Access-Token", .value = t };
        n += 1;
    }
    hs[n] = .{ .name = "Authorization", .value = try basicUser(arena, user) };
    n += 1;
    return httpc.requestStopAt(client, .POST, url, hs[0..n], framed, buf, "\"pid\"");
}

/// 有界流式 POST（Connect framing）：带 Connect-Timeout-Ms（秒），
/// 读到 envd 在超时关流后的 EOF 为止（响应体含 deadline_exceeded 属正常收尾）。
pub fn streamPost(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    envd_base: []const u8,
    token: ?[]const u8,
    user: ?[]const u8,
    path: []const u8,
    payload_json: []const u8,
    timeout_s: u64,
    buf: []u8,
) !httpc.Response {
    const framed_buf = try arena.alloc(u8, 5 + payload_json.len);
    const framed = try connect.encode(payload_json, framed_buf);
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ envd_base, path });

    var hs: [6]std.http.Header = undefined;
    var n: usize = 0;
    hs[n] = .{ .name = "Content-Type", .value = connect.content_type };
    n += 1;
    hs[n] = .{ .name = "Connect-Protocol-Version", .value = connect.protocol_version };
    n += 1;
    hs[n] = .{ .name = "Connect-Content-Encoding", .value = "identity" };
    n += 1;
    if (timeout_s > 0) {
        hs[n] = .{ .name = "Connect-Timeout-Ms", .value = try std.fmt.allocPrint(arena, "{d}", .{timeout_s * 1000}) };
        n += 1;
    }
    if (token) |t| {
        hs[n] = .{ .name = "X-Access-Token", .value = t };
        n += 1;
    }
    hs[n] = .{ .name = "Authorization", .value = try basicUser(arena, user) };
    n += 1;
    return httpc.request(client, .POST, url, hs[0..n], framed, buf);
}
