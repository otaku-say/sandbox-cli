# tls13.zig —— 纯 Zig 手写 TLS 1.3 客户端（PoC，已跑通真实 Cloudflare）

## 状态：端到端可用（2026-10-04）

对 api.cloudflare.com:443 完成全流程：ClientHello -> ServerHello -> EE ->
Certificate（3 链，ECDSA P-256）-> CertificateVerify（验签通过）-> Finished（双向校验）
-> 加密 HTTP GET -> 读回 /cdn-cgi/trace 响应（`tls=TLSv1.3` / `kex=X25519`）。

**无 fork、无 openssl 子进程、无 std.crypto.tls**（后者在 Zig 0.17 首次 flush 挂死，
2026-10-02 的 master 也未修：Client.zig/Writer.zig/Child.zig 与 0.17 diff 为 0 行）。

## 依赖的 std API（Zig 0.17，全部实测存在）
- `std.crypto.tls.hkdfExpandLabel` / `emptyHash`（白嫖，勿自写）
- `std.crypto.dh.X25519`（KeyPair.generateDeterministic + scalarmult）
- `std.crypto.aead.aes_gcm.Aes128Gcm`（encrypt/decrypt）
- `std.crypto.hash.sha2.Sha256`、`std.crypto.auth.hmac.sha2.HmacSha256`（注意是三层路径）
- `std.crypto.Certificate.parse` / `Parsed.verifyHostName` / `Certificate.rsa.*`（PSS 验签）
- `std.os.linux.getrandom`（无需 std.Io）
- 记录层用裸 syscall（std.posix 在 0.17 无 socket/connect 封装）：
  `std.os.linux.socket/connect/read/write`，`socklen_t = u32`

## 踩过的坑（全部已修，勿重复）
1. ClientHello 扩展漏写内部 vector 长度：supported_groups / signature_algorithms /
   key_share 三个扩展的「列表长度」字段缺失 -> 服务端 decode_error(50)。
2. ALPN 长度算错（ext_data len 与 ProtocolNameList len）。
3. `deriveKeyIv` 先按 32 字节展开再截断 -> 密钥全错。**HKDF-Expand-Label 的输出长度
   参与 info 计算**，必须按 cipher 真实 key 长度展开（16 就展开 16）。
4. `writeRecord` 内层明文长度算错：把「含 tag 的长度」当明文长度 -> AEAD 加密 49 字节
   再让 tag 覆盖最后 16 字节 -> 服务端 bad_record_mac(20)。
5. 客户端 Finished 消息漏了 4 字节握手头（`14 00 00 20`）-> 服务端 unexpected_message(10)。
6. **内层明文布局**：本实现对「收到」和「发出」的加密记录均按 `[内容][content_type]`
   处理。实测 OpenSSL 3.0.2 与 Cloudflare/BoringSSL 的握手加密记录、告警记录都是这个
   布局（我们的读方向保留了对两种布局的启发式兼容）。**改动此布局前必须在真实目标回归。**
7. 兼容性 CCS（`14 03 03 00 01 01`）需跳过，自己也补发一条更稳。

## 用法
```
zig build-exe tls13.zig -O ReleaseFast -femit-bin=tls13_poc
./tls13_poc --sni api.cloudflare.com --ip <A.B.C.D> --path /cdn-cgi/trace   # 带证书校验
./tls13_poc --sni localhost --ip 127.0.0.1 --port 8443 -k                  # 跳过主机名校验
```

## 交叉编译
`zig build-exe tls13.zig -O ReleaseFast -target aarch64-linux-musl`（待验证；
代码只用 std.os.linux + std.crypto，预期可直接静态编译）。

## 下一步（集成到 aio-cli 的 pty-ws）
- 抽成 `aio-cli/src/tls13.zig`：`Conn.fd` 抽象成 readFn/writeFn，与 socket 解耦
- `ws.zig` 在 socket 与帧层之间插一层：wss:// 时握手走 tls13，帧走 writeRecord(app_data)
- 调试输出受 `TrafficKeys.debug` 控制（默认 true，集成时置 false）

## 同目录附带
- `probe.py`：用 Python 独立构造 ClientHello 逐项探测扩展（定位扩展编码 bug 用）
- `check.py`：独立复算 X25519 / TLS1.3 key schedule / 各阶段密钥（与 Zig 输出对拍用）
