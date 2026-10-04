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
    _ = timeout_ms; // TODO: 写入 Connect-Timeout-Ms 头
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

    var hs: [4]std.http.Header = undefined;
    var n: usize = 0;
    hs[n] = .{ .name = "Content-Type", .value = connect.content_type };
    n += 1;
    hs[n] = .{ .name = "Connect-Protocol-Version", .value = connect.protocol_version };
    n += 1;
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
            if (extractB64Field(arena, env.payload, "stdout")) |v| {
                b64decode(out_buf, &out_len, v);
            }
        }
        if (std.mem.indexOf(u8, env.payload, "\"stderr\"")) |_| {
            if (extractB64Field(arena, env.payload, "stderr")) |v| {
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
fn extractInt(payload: []const u8, field: []const u8) ?i32 {
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
fn extractB64Field(arena: std.mem.Allocator, payload: []const u8, field: []const u8) ?[]const u8 {
    const pat = std.fmt.allocPrint(arena, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, payload, pat) orelse return null;
    const s0 = start + pat.len;
    const end = std.mem.indexOfPos(u8, payload, s0, "\"") orelse return null;
    return payload[s0..end];
}
