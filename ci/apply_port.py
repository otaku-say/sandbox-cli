#!/usr/bin/env python3
"""aiod-cli macOS 移植：把 Linux 专用 fd 读写 / 熵源替换为跨平台实现。

- ws.zig: FdStream/writeAllFd 改用 std.posix.read + libc write
- tls13.zig: randBytes 在 Linux 走 getrandom，其它平台走 arc4random_buf
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")

ws = root / "aiod-cli/src/ws.zig"
s = ws.read_text()

s = re.sub(
    r"(fn readFn\(ctx: \?\*anyopaque, buf: \[\]u8\) anyerror!usize \{).*?\n    \}",
    r"\1\n        const self: *FdStream = @ptrCast(@alignCast(ctx.?));\n"
    r"        return std.posix.read(self.fd, buf) catch return error.ReadFailed;\n    }",
    s, count=1, flags=re.S)

s = re.sub(
    r"(fn writeFn\(ctx: \?\*anyopaque, buf: \[\]const u8\) anyerror!usize \{).*?\n    \}",
    r"\1\n        const self: *FdStream = @ptrCast(@alignCast(ctx.?));\n"
    r"        const n = std.c.write(self.fd, buf.ptr, buf.len);\n"
    r"        if (n < 0) return error.WriteFailed;\n"
    r"        return @intCast(n);\n    }",
    s, count=1, flags=re.S)

s = re.sub(
    r"fn writeAllFd\(fd: std\.os\.linux\.fd_t, data: \[\]const u8\) !void \{.*?\n\}",
    "fn writeAllFd(fd: std.posix.fd_t, data: []const u8) !void {\n"
    "    var off: usize = 0;\n"
    "    while (off < data.len) {\n"
    "        const n = std.c.write(fd, data.ptr + off, data.len - off);\n"
    "        if (n < 0) {\n"
    "            if (n == -4) continue; // EINTR: Linux 与 macOS 同为 4\n"
    "            return error.WriteFailed;\n"
    "        }\n"
    "        if (n == 0) return error.WriteFailed;\n"
    "        off += @intCast(n);\n"
    "    }\n"
    "}",
    s, count=1, flags=re.S)

s = s.replace("fd: std.os.linux.fd_t", "fd: std.posix.fd_t")
ws.write_text(s)

tls = root / "aiod-cli/src/tls13.zig"
t = tls.read_text()
t = t.replace('const std = @import("std");',
              'const std = @import("std");\nconst builtin = @import("builtin");', 1)
t = re.sub(
    r"fn randBytes\(b: \[\]u8\) !void \{.*?\n\}",
    "fn randBytes(b: []u8) !void {\n"
    "    // 跨平台熵源：Linux 用 getrandom，macOS 用 arc4random_buf。\n"
    "    if (builtin.os.tag == .linux) {\n"
    "        const rc = linux.getrandom(b.ptr, b.len, 0);\n"
    "        if (linux.errno(rc) != .SUCCESS or rc != b.len) return error.NoEntropy;\n"
    "    } else {\n"
    "        std.c.arc4random_buf(b.ptr, b.len);\n"
    "    }\n"
    "}",
    t, count=1, flags=re.S)
tls.write_text(t)
print("ok")
