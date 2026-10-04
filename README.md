# sandbox-cli

CubeSandbox 命令行工具集，Zig 实现，静态单文件分发。

## 组件

| 目录 | 工具 | 作用 |
|---|---|---|
| `cube-cli/` | `cube-cli` | **控制面**：沙箱生命周期、模板画像与选择、快照/分叉、持久卷 |
| `aiod-cli/` | `aiod-cli` | **沙箱内 v2 API 遥控**：命令执行、文件传输、PTY 终端、浏览器、代码解释器 |

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

**cube-cli（控制面）**

| 变量 | 必填 | 说明 |
|---|---|---|
| `CUBESANDBOX_API_URL` | 是 | 控制面地址 |
| `CUBESANDBOX_API_KEY` | 否 | 控制面 API Key（部署未启用鉴权时可省略） |
| `CUBESANDBOX_PROXY_URL` | exec / 文件 / ports 必填 | 数据面网关地址（拼沙箱访问 URL 用） |
| `CUBESANDBOX_AGENT_NAME` | 否 | `new` 写入 `metadata.agent` 的默认名字 |

仅支持 CUBESANDBOX_* 新命名（旧名不再兼容）。

**aiod-cli（数据面）**

| 变量 | 必填 | 说明 |
|---|---|---|
| `SANDBOX_BASE` | 是（`help` 除外） | aiod 网关地址。两种写法：`https://<网关>/sandbox/<sandboxID>/8080`（远程遥控）或 `http://127.0.0.1:8080`（沙箱内自测）。末尾多余的 `/` 会自动去掉。 |
| `SANDBOX_KEY` | 否 | 鉴权 Key（非空时附 `Authorization: Bearer` + `X-API-Key`） |

`SANDBOX_BASE` 的值就是 `cube-cli new` 打印的 `[sandbox] AIO 网关:` 那行。

## 构建

需要 Zig **0.17.0**。两个工具的构建方式一致，产物名按目标架构区分：

```bash
# 本机架构
cd cube-cli && zig build -Doptimize=ReleaseFast        # → zig-out/bin/cube-cli
cd aiod-cli  && zig build -Doptimize=ReleaseFast        # → zig-out/bin/aiod-cli

# 交叉编译到 ARM（iSH / 手机 / aarch64 机器）
cd cube-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
cd aiod-cli  && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
```

| 目标三元组 | 产物文件名 | 用在哪 |
|---|---|---|
| `aarch64-linux-musl` | `cube-cli-aarch64-linux-musl` / `aiod-cli-aarch64-linux-musl` | iSH（iOS）、ARM 服务器 |
| `x86_64-linux-musl` | `cube-cli-x86_64-linux-musl` / `aiod-cli-x86_64-linux-musl` | x86 服务器、桌面 Linux |

两种架构都必须能编过；ReleaseFast + strip 后每个约 1.1–1.3 MB 静态单文件。

## 命令速查：先看 `help`

**`help` 就是权威命令面。** 命令表在 `cube-cli/src/help.zig` 与 `aiod-cli/src/help.zig`，
`docs/*.md` 由 `scripts/gen-docs.py` 从**编译产物**自动生成——**文档随代码走**，
改了命令先改 `help.zig`，再跑一次生成脚本，README 不再重复维护命令清单。

```bash
# 三个工具都是同一种入口
<cli> help              # 分组速查（常用命令，≤60 行）
<cli> help all          # 完整命令表，一条一行
<cli> help <命令>       # 单命令详解：用途 / 用法 / 参数 / 示例 / 注意
<cli> <命令> --help     # 同上，且**只打印不执行**
<cli> <命令> -h         # 同上
```

`cube-cli` 常用：

```bash
cube-cli version                 # 版本 / 仓库地址 / 构建信息
cube-cli health                  # 控制面健康检查
cube-cli tpl-ls                  # 列出模板
cube-cli new --need=code         # 建沙箱（默认就是 aio-code 镜像）
cube-cli ls                      # 列出沙箱
cube-cli exec <sandboxID> 'zig version' --timeout=300
cube-cli snap <sandboxID> --name=before-refactor
```

`aiod-cli` 常用（先 `export SANDBOX_BASE=...`）：

```bash
aiod-cli health
aiod-cli exec 'zig version' --timeout=600000
aiod-cli write ./a.md /home/gem/a.md && aiod-cli cat /home/gem/a.md
aiod-cli br-go https://example.com && aiod-cli br-shot shot.png
ID=$(aiod-cli async 'sleep 60'); aiod-cli log "$ID" --follow; aiod-cli kill "$ID"
```

### 逐条文档

- [`docs/cube-cli.md`](docs/cube-cli.md) —— cube-cli 全部 37 条命令
- [`docs/aiod-cli.md`](docs/aiod-cli.md) —— aiod-cli 全部 76 条命令

重新生成：

```bash
cd cube-cli && zig build -Doptimize=ReleaseFast && cd ../aiod-cli && zig build -Doptimize=ReleaseFast
cd .. && python3 scripts/gen-docs.py --cube cube-cli/zig-out/bin/cube-cli --aio aiod-cli/zig-out/bin/aiod-cli
```

### 冒烟测试

```bash
sh tests/help_smoke.sh          # 帮助体系 + new --help 不建沙箱，可重复执行
```

### 漂移检查（跟进上游）

两条长期纪律各配一把自动尺，脚本在 `scripts/`（仅 Python 3 标准库）：

| 纪律 | 检查脚本 | 对照的签入清单 |
|---|---|---|
| aiod-cli 始终跟随 aiod 的 /v2 API | `scripts/check-v2-drift.py` | `scripts/v2-coverage.json`（74 个 v2 端点 → 命令 / 明确不做+原因） |
| cube-cli 始终跟随上游 Python SDK | `scripts/check-sdk-drift.py` | `scripts/sdk-coverage.json`（94 个公开方法 → 命令 / 明确不做+原因） |

```bash
# ① aiod v2 漂移（对活体网关；沙箱内默认 http://127.0.0.1:8080）
python3 scripts/check-v2-drift.py --base=https://<网关>/sandbox/<sid>/8080
python3 scripts/check-v2-drift.py --openapi=/path/openapi.json      # 离线快照模式

# ② SDK 漂移（本地 SDK 树，或从 GitHub 拉 tarball；默认跟踪清单里的 tracked_ref=master）
python3 scripts/check-sdk-drift.py --sdk=/path/to/sdk/python
python3 scripts/check-sdk-drift.py --fetch          # 想按发布版跟踪：--fetch --ref=v0.7.2
```

判读输出：

- **① 新增端点/方法**（上游有、清单无）= **需要跟进**：给 CLI 补命令，或把清单条目标 `not-planned` + 原因；
- **② 消失端点/方法**（清单有、上游无）= 上游删除/改名 → 复核清单；
- **③ 签名变化**（仅 SDK）= 方法签名变了 → 复核 CLI 参数是否跟随（`--no-signature-check` 可只看增删）；
- **④ 覆盖统计** = implemented（有命令）/ not-planned（明确不做）计数；
- **退出码**：0 = 无漂移；1 = 有漂移；2 = 拉取/清单错误 —— 可直接进 CI。

清单只由维护者更新（脚本只报告差异、不自动改清单）。`--json` 拿机器可读结果；
SDK 检查挂在 `.github/workflows/drift.yml`（每周一 + 手动触发）；v2 检查需要活体 aiod
（CI 里没有），在沙箱/本机手动跑首条命令。

## 注意

- **flag 一律 `--key=value` 等号写法**（`--need=code`）；布尔开关直接写 `--flag`。
- **未知命令**会打印「未知命令：xxx」并以**非 0** 退出码结束。
- `--help` / `-h` / `help <命令>` 三种写法等价，且**绝不触发真实操作**——
  `cube-cli new --help` 只打印帮助、不会真的建沙箱（`tests/help_smoke.sh` 里有回归验证）。
- 文档里标了「源码未实现」的选项确实没有接线（历史上旧文档写过的 `--env=` / `--limit=` /
  `--ref=` 等在当前实现里不存在），别照抄。

Zig 0.17 的标准库与旧版本差异很大（`std.io` → `std.Io`、`std.http.Client` 需注入 `io`、
`main` 签名改为接收 `std.process.Init`）。本仓库代码按 0.17 编写，**不要**参照网上基于 0.11–0.14 的示例。
