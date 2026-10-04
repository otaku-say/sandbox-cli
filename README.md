# sandbox-cli

CubeSandbox 命令行工具集，Zig 实现，静态单文件分发。

## 组件

| 目录 | 工具 | 作用 |
|---|---|---|
| `cube-cli/` | `cube-cli` | **控制面**：沙箱生命周期、模板画像与选择、快照/分叉、持久卷 |
| `aio-cli/` | `aio-cli` | **沙箱内 v2 API 遥控**：命令执行、文件传输、PTY 终端、浏览器、代码解释器 |

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

旧命名 `CUBE_API_URL` / `CUBE_API_KEY` / `CBS_PROXY_BASE` 仍兼容。

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
