//! 分层诊断：只测 Stream.Writer/Reader（明文 HTTP，不经 TLS）
const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 明文 HTTP 到 1.1.1.1:80
    const addr = try std.Io.net.IpAddress.parse("104.21.68.24", 80);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    std.debug.print("[1] TCP ok\n", .{});

    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    std.debug.print("[2] writer 构造完成，开始写...\n", .{});
    w.interface.writeAll("GET /health HTTP/1.1\r\nHost: cubesandbox-api.4a8a.com\r\nConnection: close\r\n\r\n") catch |e| {
        std.debug.print("[!] writeAll 失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[3] writeAll 完成，flush...\n", .{});
    w.interface.flush() catch |e| {
        std.debug.print("[!] flush 失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[4] flush 完成\n", .{});

    var rbuf: [8192]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    std.debug.print("[5] reader 构造完成，开始读...\n", .{});
    const n = r.interface.readSliceShort(&rbuf) catch |e| {
        std.debug.print("[!] read 失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[6] 读到 {d} 字节:\n{s}\n", .{ n, rbuf[0..@min(n, 200)] });
}
