#!/usr/bin/env python3
"""Windows 参数适配：init.args.vector 在 Windows 上是 UTF-16(WTF-16)，
统一转成 UTF-8 后再走原有逻辑（POSIX 行为不变）。"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
TARGETS = [("cube-cli/src/main.zig", "argv_raw"), ("aiod-cli/src/main.zig", "raw")]

for rel, var in TARGETS:
    p = root / rel
    s = p.read_text()
    if "wtf16LeToWtf8Alloc" in s:
        continue
    if 'const builtin = @import("builtin");' not in s:
        s = s.replace('const std = @import("std");',
                      'const std = @import("std");\nconst builtin = @import("builtin");', 1)
    old = f"    for ({var}, 0..) |a, i| argv[i] = std.mem.span(a);"
    new = (f"    for ({var}, 0..) |a, i| {{\n"
           f"        argv[i] = if (comptime builtin.os.tag == .windows)\n"
           f"            try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(a))\n"
           f"        else\n"
           f"            std.mem.span(a);\n"
           f"    }}")
    if old not in s:
        raise SystemExit(f"pattern not found in {rel}")
    p.write_text(s.replace(old, new, 1))

print("ok")
