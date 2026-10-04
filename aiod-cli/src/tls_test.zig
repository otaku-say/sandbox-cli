//! 最小 TLS 测试：验证 std.crypto.tls 能否建立连接并发 HTTP 请求
const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const gpa = std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 解析目标（用 hosts 里的 IPv4，绕开 DNS）
    const addr = try std.Io.net.IpAddress.parse("104.21.68.24", 443);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    std.debug.print("[1] TCP 已连接\n", .{});

    // CA bundle
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    const now = std.Io.Timestamp.now(io, .real);
    try bundle.rescan(gpa, io, now);
    std.debug.print("[2] CA bundle 已加载\n", .{});

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    var lock: std.Io.RwLock = .init;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;

    var client = try std.crypto.tls.Client.init(&stream_reader.interface, &stream_writer.interface, .{
        .host = .{ .explicit = "cubesandbox-api.4a8a.com" },
        .ca = .{ .bundle = .{
            .gpa = gpa,
            .io = io,
            .lock = &lock,
            .bundle = &bundle,
        } },
        .write_buffer = &tls_write_buf,
        .read_buffer = &tls_read_buf,
        .entropy = &entropy,
        .realtime_now = now,
        .allow_truncation_attacks = true,
    });
    std.debug.print("[3] TLS 握手完成\n", .{});

    const req = "GET /health HTTP/1.1\r\nHost: cubesandbox-api.4a8a.com\r\nConnection: close\r\n\r\n";
    std.debug.print("[3.1] writeAll 开始\n", .{});
    client.writer.writeAll(req) catch |e| {
        std.debug.print("[!] writeAll 失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[3.2] writeAll 完成，flush 开始\n", .{});
    client.writer.flush() catch |e| {
        std.debug.print("[!] flush 失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[4] flush 完成\n", .{});

    var buf: [4096]u8 = undefined;
    const n = client.reader.readSliceShort(&buf) catch |e| {
        std.debug.print("[!] 读取失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[5] 收到 {d} 字节:\n{s}\n", .{ n, buf[0..@min(n, 300)] });
}
