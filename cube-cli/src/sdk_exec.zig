//! Core SDK —— 沙箱内进程与代码执行（走 envd 数据面）。
//!
//! 包含同步执行、后台异步启动、增量日志拉取、信号发送、标准输入与代码运行。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const envd = @import("envd.zig");
const httpc = @import("httpc.zig");

const Sdk = sdkmod.Sdk;

pub const EXEC_DIR = "/tmp/.cube-cli-exec";

pub const ExecOptions = struct {
    cwd: ?[]const u8 = null,
    env_json: ?[]const u8 = null,
    user: ?[]const u8 = null,
    timeout_s: u64 = 0,
};

pub const ExecResult = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: i32 = 0,
};

fn shellQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 2;
    for (s) |c| {
        if (c == '\'') count += 4 else count += 1;
    }
    const out = try arena.alloc(u8, count);
    var i: usize = 0;
    out[i] = '\'';
    i += 1;
    for (s) |c| {
        if (c == '\'') {
            out[i] = '\'';
            out[i + 1] = '\\';
            out[i + 2] = '\'';
            out[i + 3] = '\'';
            i += 4;
        } else {
            out[i] = c;
            i += 1;
        }
    }
    out[i] = '\'';
    return out;
}

pub fn newTag(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    var rb: [6]u8 = undefined;
    std.Io.random(io, &rb);
    const hex = "0123456789abcdef";
    const out = try arena.alloc(u8, 12);
    for (rb, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

/// 同步执行命令（等待执行完毕返回）。
pub fn sandboxExec(self: *Sdk, sid: []const u8, cmd: []const u8, opt: ExecOptions) !ExecResult {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const timeout_ms: u64 = opt.timeout_s * 1000;
    const res = try envd.exec(
        self.arena,
        self.client,
        dp.base,
        dp.token,
        opt.user,
        cmd,
        opt.cwd,
        opt.env_json,
        timeout_ms,
        buf,
    );
    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = res.exit_code,
    };
}

pub const AsyncResult = struct {
    pid: i64,
    tag: []const u8,
    stdout_file: []const u8,
    stderr_file: []const u8,
};

/// 异步后台执行命令（启动后立即分离返回 pid 与日志文件路径）。
pub fn sandboxExecAsync(self: *Sdk, sid: []const u8, cmd: []const u8, opt: ExecOptions, no_stdin: bool) !AsyncResult {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);

    const tag = try newTag(self.io, self.arena);
    const out_path = try std.fmt.allocPrint(self.arena, "{s}/{s}.out", .{ EXEC_DIR, tag });
    const err_path = try std.fmt.allocPrint(self.arena, "{s}/{s}.err", .{ EXEC_DIR, tag });
    const exit_path = try std.fmt.allocPrint(self.arena, "{s}/{s}.exit", .{ EXEC_DIR, tag });

    var inner: []const u8 = cmd;
    if (opt.timeout_s > 0) {
        inner = try std.fmt.allocPrint(self.arena, "timeout -k 5 {d} bash -c {s}", .{ opt.timeout_s, try shellQuote(self.arena, cmd) });
    }
    const wrapper = try std.fmt.allocPrint(
        self.arena,
        "mkdir -p {s} 2>/dev/null; {{ {s} ; }} > {s} 2> {s}; echo $? > {s}",
        .{ EXEC_DIR, inner, out_path, err_path, exit_path },
    );

    const cwd_part = if (opt.cwd) |wd|
        try std.fmt.allocPrint(self.arena, ",\"cwd\":\"{s}\"", .{try envd.jsonEscape(self.arena, wd)})
    else
        "";
    const envs = opt.env_json orelse "";
    const stdin_flag: []const u8 = if (no_stdin) "false" else "true";
    const payload = try std.fmt.allocPrint(
        self.arena,
        "{{\"process\":{{\"cmd\":\"/bin/bash\",\"args\":[\"-l\",\"-c\",\"{s}\"],\"envs\":{{{s}}}{s}}},\"stdin\":{s}}}",
        .{ try envd.jsonEscape(self.arena, wrapper), envs, cwd_part, stdin_flag },
    );

    const res = try envd.startDetached(self.arena, self.client, dp.base, dp.token, opt.user, payload, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
    const pid32 = envd.extractInt(res.body, "pid") orelse return error.NoPid;
    const pid: i64 = pid32;

    const meta = try std.fmt.allocPrint(
        self.arena,
        "{{\"pid\":{d},\"tag\":\"{s}\",\"out\":\"{s}\",\"err\":\"{s}\",\"exit\":\"{s}\",\"cmd\":\"{s}\"}}",
        .{ pid, tag, out_path, err_path, exit_path, try envd.jsonEscape(self.arena, cmd) },
    );
    const meta_path = try std.fmt.allocPrint(self.arena, "{s}/{d}.meta", .{ EXEC_DIR, pid });
    _ = envd.writeFile(self.arena, self.client, dp.base, dp.token, opt.user, meta_path, meta, buf) catch {};

    return .{
        .pid = pid,
        .tag = tag,
        .stdout_file = out_path,
        .stderr_file = err_path,
    };
}

pub const LogsResult = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    next_offset: u64 = 0,
    next_stderr_offset: u64 = 0,
    exit_code: ?i64 = null,
    is_alive: bool = false,
};

fn readDelta(self: *Sdk, base: []const u8, token: ?[]const u8, user: ?[]const u8, path: []const u8, off: u64, limit: u64, buf: []u8) !struct { data: []const u8, next: u64 } {
    const res = try envd.readFileRange(self.arena, self.client, base, token, user, path, off, buf);
    if (res.status == 404 or res.status == 416) return .{ .data = "", .next = off };
    if (!res.ok()) return error.HttpError;
    var data: []const u8 = res.body;
    if (res.status != 206) {
        if (off >= data.len) {
            data = "";
        } else {
            data = data[off..];
        }
    }
    if (limit > 0 and data.len > limit) data = data[0..limit];
    return .{ .data = self.arena.dupe(u8, data) catch data, .next = off + @as(u64, @intCast(data.len)) };
}

/// 拉取异步进程日志。
pub fn sandboxExecLogs(self: *Sdk, sid: []const u8, pid: i64, user: ?[]const u8, off_out: u64, off_err: u64, limit: u64) !LogsResult {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);

    const meta_path = try std.fmt.allocPrint(self.arena, "{s}/{d}.meta", .{ EXEC_DIR, pid });
    const meta_res = envd.readFile(self.arena, self.client, dp.base, dp.token, user, meta_path, buf) catch return error.NoMeta;
    if (!meta_res.ok()) return error.NoMeta;

    const out_path = envd.extractString(self.arena, meta_res.body, "out") orelse return error.NoMeta;
    const err_path = envd.extractString(self.arena, meta_res.body, "err") orelse return error.NoMeta;
    const exit_path = envd.extractString(self.arena, meta_res.body, "exit") orelse return error.NoMeta;

    const d_out = try readDelta(self, dp.base, dp.token, user, out_path, off_out, limit, buf);
    const d_err = try readDelta(self, dp.base, dp.token, user, err_path, off_err, limit, buf);

    var exit_code: ?i64 = null;
    const exit_res = envd.readFile(self.arena, self.client, dp.base, dp.token, user, exit_path, buf) catch null;
    if (exit_res) |er| {
        if (er.ok() and er.body.len > 0) {
            exit_code = std.fmt.parseInt(i64, std.mem.trim(u8, er.body, " \r\n\t"), 10) catch null;
        }
    }

    const procs_res = envd.listProcs(self.arena, self.client, dp.base, dp.token, user, buf) catch null;
    var is_alive = false;
    if (procs_res) |pr| {
        if (pr.ok()) {
            const pat = std.fmt.allocPrint(self.arena, "\"pid\":{d}", .{pid}) catch "";
            if (pat.len > 0 and std.mem.indexOf(u8, pr.body, pat) != null) is_alive = true;
        }
    }

    return .{
        .stdout = d_out.data,
        .stderr = d_err.data,
        .next_offset = d_out.next,
        .next_stderr_offset = d_err.next,
        .exit_code = exit_code,
        .is_alive = is_alive,
    };
}

/// 终止异步进程（发信号）。
pub fn sandboxExecKill(self: *Sdk, sid: []const u8, pid: i64, user: ?[]const u8, sig: ?[]const u8) !void {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const s = sig orelse "SIGNAL_SIGKILL";
    const res = try envd.sendSignal(self.arena, self.client, dp.base, dp.token, user, pid, s, buf);
    self.last_status = res.status;
    if (!res.ok() and res.status != 404) {
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
}

/// 向异步进程写入标准输入。
pub fn sandboxExecStdin(self: *Sdk, sid: []const u8, pid: i64, user: ?[]const u8, data: []const u8) !void {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const res = try envd.sendInput(self.arena, self.client, dp.base, dp.token, user, pid, "stdin", data, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
}

pub const CodeOptions = struct {
    mode: []const u8 = "interp",
    lang: []const u8 = "python",
    timeout_s: u64 = 0,
    env_json: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

/// 运行代码片段（interp 解释器模式或 kernel 内核模式）。
pub fn sandboxCode(self: *Sdk, sid: []const u8, code: []const u8, opt: CodeOptions) !ExecResult {
    if (std.mem.eql(u8, opt.mode, "kernel")) {
        if (self.proxy.len == 0) return error.MissingConfig;
        const url = try std.fmt.allocPrint(self.arena, "{s}/sandbox/{s}/49999/execute", .{ self.proxy, sid });
        const envs_part = if (opt.env_json) |ej|
            try std.fmt.allocPrint(self.arena, "{{{s}}}", .{ej})
        else
            "null";
        const body = try std.fmt.allocPrint(
            self.arena,
            "{{\"code\":\"{s}\",\"language\":\"{s}\",\"env_vars\":{s}}}",
            .{ try envd.jsonEscape(self.arena, code), try envd.jsonEscape(self.arena, opt.lang), envs_part },
        );
        const buf = try self.arena.alloc(u8, sdkmod.BUF);
        var hs: [2]std.http.Header = undefined;
        hs[0] = .{ .name = "Content-Type", .value = "application/json" };
        hs[1] = .{ .name = "Accept", .value = "application/x-ndjson" };
        const res = try httpc.request(self.client, .POST, url, hs[0..2], body, buf);
        if (!res.ok()) {
            self.last_status = res.status;
            self.last_body = try self.arena.dupe(u8, res.body);
            return error.HttpError;
        }
        return .{ .stdout = try self.arena.dupe(u8, res.body), .stderr = "", .exit_code = 0 };
    } else if (!std.mem.eql(u8, opt.mode, "interp")) {
        return error.BadMode;
    }

    const q = try shellQuote(self.arena, code);
    const lang = opt.lang;
    const cmd = if (std.mem.eql(u8, lang, "python") or std.mem.eql(u8, lang, "python3"))
        try std.fmt.allocPrint(self.arena, "python3 -c {s}", .{q})
    else if (std.mem.eql(u8, lang, "js") or std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "node") or std.mem.eql(u8, lang, "nodejs"))
        try std.fmt.allocPrint(self.arena, "node -e {s}", .{q})
    else if (std.mem.eql(u8, lang, "bash") or std.mem.eql(u8, lang, "sh") or std.mem.eql(u8, lang, "shell"))
        try std.fmt.allocPrint(self.arena, "bash -c {s}", .{q})
    else
        return error.BadLang;

    return sandboxExec(self, sid, cmd, .{
        .cwd = null,
        .env_json = opt.env_json,
        .user = opt.user,
        .timeout_s = opt.timeout_s,
    });
}
