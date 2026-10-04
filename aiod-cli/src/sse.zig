//! sse.zig —— SSE（Server-Sent Events）流式客户端（零依赖，手写）。
//!
//! 用途：aiod-cli 的 watch-events（GET /v2/watch/<id>/events）。
//!
//! 实测流格式（aio-daemon 0.9.2，Rust axum 后端）：
//!   event: watch_started\ndata: {"watcher_id":"..."}\n\n
//!   id: <watcher_id>:<seq>\nevent: file_change\ndata: {seq,type,path,...}\n\n
//!   注：id 行可能出现在 event 行之前 —— 解析按"块"（\n\n 分隔）进行，不依赖行序。
//!
//! 实现说明：走 std.http.Client 低层 API（request → sendBodiless → receiveHead →
//! response.reader），body 是流式读取（chunked 由标准库解码），不会一次性读完整个流。
const std = @import("std");

pub const Event = struct {
    name: []const u8,
    id: []const u8,
    /// 多行 data 按 SSE 规范以 \n 拼接（arena 分配）
    data: []const u8,
};

pub const Options = struct {
    url: []const u8,
    headers: []const std.http.Header = &.{},
};

const chunk_size = 8192;
const block_max = 256 * 1024;
const data_max = 128 * 1024;

/// 流式订阅；每收到一个完整事件调用 onEvent(ctx, ev)。
/// onEvent 返回 false 表示提前终止（正常退出，不报错）。
pub fn subscribe(
    client: *std.http.Client,
    arena: std.mem.Allocator,
    options: Options,
    ctx: anytype,
    comptime onEvent: fn (@TypeOf(ctx), Event) anyerror!bool,
) !void {
    const uri = try std.Uri.parse(options.url);
    var req = try std.http.Client.request(client, .GET, uri, .{
        .keep_alive = false,
        .extra_headers = options.headers,
    });
    req.headers.accept_encoding = .omit;
    defer req.deinit();
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    const status: u16 = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) {
        std.debug.print("[sse] 订阅失败：HTTP {d}\n", .{status});
        return error.HttpStatus;
    }
    if (response.head.content_encoding != .identity) {
        std.debug.print("[sse] 响应带压缩编码（不支持），请检查服务端配置\n", .{});
        return error.UnsupportedCompressionMethod;
    }

    var transfer_buf: [4096]u8 = undefined;
    const r = response.reader(&transfer_buf);

    var acc: [block_max]u8 = undefined;
    var alen: usize = 0;
    var chunk: [chunk_size]u8 = undefined;

    while (true) {
        var iov = [1][]u8{chunk[0..]};
        const n = r.readVec(&iov) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) continue;
        if (alen + n > acc.len) return error.EventTooLarge;
        @memcpy(acc[alen..][0..n], chunk[0..n]);
        alen += n;

        while (std.mem.indexOf(u8, acc[0..alen], "\n\n")) |i| {
            const ev = try parseBlock(arena, acc[0..i]);
            if (!try onEvent(ctx, ev)) return;
            const remain = alen - (i + 2);
            std.mem.copyForwards(u8, acc[0..remain], acc[i + 2 .. alen]);
            alen = remain;
        }
    }
}

fn parseBlock(arena: std.mem.Allocator, block: []const u8) !Event {
    var name: []const u8 = "";
    var id: []const u8 = "";
    const data = try arena.alloc(u8, data_max);
    var dn: usize = 0;

    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line0| {
        const line = trimRight(line0, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "id:")) {
            id = trimLeft(line[3..]);
        } else if (std.mem.startsWith(u8, line, "event:")) {
            name = trimLeft(line[6..]);
        } else if (std.mem.startsWith(u8, line, "data:")) {
            const d0 = trimLeft(line[5..]);
            if (dn + d0.len + 1 <= data.len) {
                @memcpy(data[dn..][0..d0.len], d0);
                dn += d0.len;
                data[dn] = '\n';
                dn += 1;
            }
        }
    }
    if (dn > 0) dn -= 1; // 去掉尾随换行
    return .{ .name = name, .id = id, .data = data[0..dn] };
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn trimRight(s: []const u8, chars: []const u8) []const u8 {
    var e = s.len;
    while (e > 0) {
        var hit = false;
        for (chars) |ch| {
            if (s[e - 1] == ch) {
                hit = true;
                break;
            }
        }
        if (!hit) break;
        e -= 1;
    }
    return s[0..e];
}
