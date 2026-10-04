# aio-cli

沙箱内 **v2 API** 遥控 CLI（迁移中）。

对应旧实现的功能面：

- 命令：同步执行 / 异步 + 轮询 / 超时 / kill / stdin
- 文件：读、写、上传（multipart）、下载、目录树
- 终端：PTY over WebSocket（exec / screen / input / signal / 改尺寸）
- 其他：监听（watch）、代码解释器、浏览器（导航 / 截图 / evaluate / 原生 CDP）、MCP

Zig 标准库不含 WebSocket / SSE / multipart，这三块需自行实现。
