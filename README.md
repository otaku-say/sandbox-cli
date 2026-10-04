# sandbox-cli

CubeSandbox 命令行工具集，Zig 实现，静态单文件分发。

## 组件

| 目录 | 工具 | 作用 |
|---|---|---|
| `cube-cli/` | `cube-cli` | **控制面**：沙箱生命周期、模板画像与选择、快照/分叉、持久卷 |
| `aio-cli/` | `aio-cli` | **沙箱内 v2 API 遥控**：命令执行、文件传输、PTY 终端、浏览器、代码解释器 |

## DNS 容错（iSH 等环境必需）

Zig 标准库的解析器**不会跳过不可达的 nameserver**。若 `/etc/resolv.conf` 把 IPv6
链路本地地址（`fe80::/10`）排在第一位——iSH for iOS 正是如此——它会拿这个地址直接查询，
报文发不出去就整个解析以 `error.NameServerFailure` 收场，每次还要空耗数秒超时。
musl libc 会自动跳过这类地址，所以在同一台机器上 `curl` 一切正常，这两个 CLI 却连
一个域名都解析不出来。

两个 CLI 都内置了 `netfix.zig`：启动时若检测到此类地址，就在**进程内**接管域名解析
（注入 `std.Io` 的 `netLookup`），过滤掉不可达的 nameserver 后用其余地址查询。
**不改系统文件、不依赖 libc、不引入第三方依赖**；配置正常时不安装任何钩子（零开销）。

实现要点（都是踩过的坑，改之前先读）：

- `Io.Threaded` 的 `netLookup` 内部用的是**它自己的 io**（`t.io()`），不是调用方传入的
  那个。因此"把 `/etc/resolv.conf` 重定向到副本"这类文件层做法会被绕过（strace 实证：
  它仍然打开真实文件）。唯一有效的注入点就是 `netLookup` 本身。
- 包装 `std.Io` 时，`Io.userdata` 必须**原样透传**——它是底层实现的私有数据（指向
  `Threaded` 实例）。换成自己的结构体会让其它 vtable 函数解引用错位，直接段错误。
- 查询实现复用标准库公开件：`HostName.ResolvConf.init(io)`（用我们包装过的 io 读过滤副本）、
  `HostName.DnsResponse`、`HostName.expand`；只有查询报文构造与 UDP 收发是自己写的。

## 为什么是 Zig

这些工具在 iOS 的 iSH（Linux 用户态环境）里频繁调用，**进程启动开销是主要成本**。
同一任务（HTTPS GET + 自定义请求头）的实测：

| 语言 | 纯启动 | 二进制 |
|---|---|---|
| Go | ~170 ms | 5.3 MB |
| **Zig** | **~2 ms** | **~1 MB** |

Go 的 ~170ms 是 runtime 初始化的固定开销（与二进制体积无关：1.3 MB 的 hello world 与 5.3 MB 的完整程序一样慢）。
Zig 静态链接 musl，无 runtime、无 GC，启动接近 C 程序。

其他收益：**零第三方依赖**（HTTP/TLS/JSON 全在标准库）、交叉编译内置
（`-Dtarget=aarch64-linux-musl` 一条命令，无需额外工具链）。

## 配置

**所有部署相关取值一律通过环境变量传入，仓库内不含任何主机名、IP 或凭据。**

| 变量 | 说明 |
|---|---|
| `CUBESANDBOX_API_URL` | 控制面地址 |
| `CUBESANDBOX_API_KEY` | 控制面 API Key（部署未启用鉴权时可省略） |
| `CUBESANDBOX_PROXY_URL` | 数据面网关地址（拼沙箱访问 URL 用） |

仅支持 CUBESANDBOX_* 新命名（旧名不再兼容）。

## 构建

需要 Zig **0.17.0**。

```bash
cd cube-cli
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
# 产物：zig-out/bin/cube-cli
```

目标三元组：`aarch64-linux-musl`（ARM 设备 / iSH）、`x86_64-linux-musl`（x86 服务器）。

## 用法

```bash
cube-cli version           # 版本
cube-cli health            # 控制面健康检查
cube-cli tpl-ls            # 列出模板
```

## 注意

Zig 0.17 的标准库与旧版本差异很大（`std.io` → `std.Io`、`std.http.Client` 需注入 `io`、
`main` 签名改为接收 `std.process.Init`）。本仓库代码按 0.17 编写，**不要**参照网上基于 0.11–0.14 的示例。
