#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-sdk-drift.py —— cube-cli × CubeSandbox Python SDK 漂移检查。

长期纪律：cube-cli 始终跟随上游 Python SDK（github.com/TencentCloud/CubeSandbox
的 sdk/python/，PyPI 包名 cubesandbox）。本脚本用 AST 提取 SDK 的全部公开方法
与签名，与签入清单 scripts/sdk-coverage.json 比对，输出：

  ① 新增方法：SDK 有、清单无  → 需要跟进（补 cube-cli 命令，或标记 not-planned+原因）
  ② 消失方法：清单有、SDK 无  → 上游删除/改名，复核清单
  ③ 签名变化：同名但签名/类型变化 → 复核命令参数是否要跟随
  ④ 覆盖统计：implemented / not-planned 计数

有漂移时退出码非 0（CI / 定时任务用）：
  退出码 0 = 无漂移；1 = 有漂移；2 = 输入/清单错误（拉取失败、清单不合法等）。

用法：
  python3 scripts/check-sdk-drift.py --sdk=/path/to/sdk/python    # 本地 SDK 树
  python3 scripts/check-sdk-drift.py --fetch                      # 从 GitHub 拉 tarball（默认 tracked_ref）
  python3 scripts/check-sdk-drift.py --fetch --ref=v0.7.2         # 指定 tag / 分支
  python3 scripts/check-sdk-drift.py --sdk=... --list             # 顺带列出全部条目

提取口径（与清单同构，改口径要两边同步并重生成清单）：
  - 扫描 <sdk>/cubesandbox/*.py；
  - 公开类 = 类名不以 "_" 开头（含 _xxx.py 内的公开具名类，宁可多收不漏）；
  - 公开方法 = 不以 "_" 开头，或带 @property 装饰器（属性也算）；
  - 同名 getter/setter 只记第一条；签名 = 参数列表（ast.unparse 归一化，不含返回值注解）；
  - 嵌套类、模块级函数不跟踪（当前 SDK 无此形态）。

仅用 Python 3 标准库。
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MANIFEST = os.path.join(HERE, "sdk-coverage.json")
DEFAULT_REPO = "TencentCloud/CubeSandbox"
VALID_STATUS = ("implemented", "not-planned")


# ---------------------------------------------------------------- 提取

def _decorator_names(node: ast.AST) -> list[str]:
    names = []
    for d in getattr(node, "decorator_list", []):
        if isinstance(d, ast.Name):
            names.append(d.id)
        elif isinstance(d, ast.Attribute):
            names.append(d.attr)
    return names


def _normalize_signature(node: ast.AST) -> str:
    return " ".join(ast.unparse(node.args).split())


def find_package_dir(root: str) -> str:
    """接受 sdk/python、仓库根、或包目录本身，返回 cubesandbox 包目录。"""
    root = os.path.abspath(root)
    candidates = [
        root,
        os.path.join(root, "cubesandbox"),
        os.path.join(root, "sdk", "python", "cubesandbox"),
        os.path.join(root, "sdk", "python"),
    ]
    for cand in candidates:
        if os.path.isdir(cand) and os.path.isfile(os.path.join(cand, "__init__.py")):
            return cand
    # 兜底：浅层搜索（如解压出来的 CubeSandbox-<ref>/sdk/python/cubesandbox）
    for dirpath, dirnames, _ in os.walk(root):
        if os.path.basename(dirpath) == "cubesandbox" and "__init__.py" in os.listdir(dirpath):
            return dirpath
        if dirpath.count(os.sep) - root.count(os.sep) > 4:
            dirnames[:] = []
    raise FileNotFoundError(
        f"在 {root} 下找不到 cubesandbox 包（应含 __init__.py；可指向 sdk/python 或仓库根）"
    )


def extract_methods(pkg_dir: str) -> dict[str, dict]:
    """返回 {ClassName.method: {signature, kind, file}}（按 key 排序）。"""
    out: dict[str, dict] = {}
    for fn in sorted(os.listdir(pkg_dir)):
        if not fn.endswith(".py"):
            continue
        path = os.path.join(pkg_dir, fn)
        try:
            tree = ast.parse(open(path, "r", encoding="utf-8").read(), filename=path)
        except SyntaxError as exc:
            raise ValueError(f"{fn}: 解析失败：{exc}") from exc
        for node in tree.body:
            if not isinstance(node, ast.ClassDef) or node.name.startswith("_"):
                continue
            for body in node.body:
                if not isinstance(body, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                decos = _decorator_names(body)
                is_prop = "property" in decos
                if body.name.startswith("_") and not is_prop:
                    continue
                key = f"{node.name}.{body.name}"
                if key in out:  # getter/setter 合并：保留第一条
                    continue
                if is_prop:
                    kind = "property"
                elif "classmethod" in decos:
                    kind = "classmethod"
                elif "staticmethod" in decos:
                    kind = "staticmethod"
                elif isinstance(body, ast.AsyncFunctionDef):
                    kind = "async-method"
                else:
                    kind = "method"
                out[key] = {
                    "signature": _normalize_signature(body),
                    "kind": kind,
                    "file": fn,
                }
    return dict(sorted(out.items()))


# ---------------------------------------------------------------- 拉取

def _download(url: str, timeout: float) -> str:
    req = urllib.request.Request(
        url, headers={"User-Agent": "sandbox-cli-drift-check", "Accept": "application/octet-stream"}
    )
    fd, tmp = tempfile.mkstemp(prefix="cubesandbox-sdk-", suffix=".tar.gz")
    with os.fdopen(fd, "wb") as f, urllib.request.urlopen(req, timeout=timeout) as resp:
        shutil.copyfileobj(resp, f)
    return tmp


def fetch_sdk(repo: str, ref: str, timeout: float) -> tuple[str, str]:
    """从 GitHub codeload 拉 tarball，解出 sdk/python/cubesandbox，返回 (包目录, 描述)。"""
    attempts = []
    if ref.startswith("refs/"):
        attempts = [f"https://codeload.github.com/{repo}/tar.gz/{ref}"]
    else:
        attempts = [
            f"https://codeload.github.com/{repo}/tar.gz/refs/heads/{ref}",
            f"https://codeload.github.com/{repo}/tar.gz/refs/tags/{ref}",
        ]
    tarball = None
    last_err: Exception | None = None
    used = None
    for url in attempts:
        try:
            tarball = _download(url, timeout)
            used = url
            break
        except urllib.error.HTTPError as exc:
            last_err = exc
        except urllib.error.URLError as exc:
            last_err = exc
    if tarball is None:
        raise RuntimeError(f"下载 {repo}@{ref} 失败（已试 {len(attempts)} 个 URL）：{last_err}")

    tmpdir = tempfile.mkdtemp(prefix="cubesandbox-sdk-tree-")
    try:
        with tarfile.open(tarball, "r:gz") as tf:
            members = []
            for m in tf.getmembers():
                name = m.name
                if not m.isfile() or ".." in name.split("/") or name.startswith("/"):
                    continue
                if "/sdk/python/" not in name:
                    continue
                members.append(m)
            if not members:
                raise RuntimeError(f"tarball 里没找到 sdk/python/（{used}）")
            try:
                tf.extractall(tmpdir, members=members, filter="data")
            except TypeError:  # Python < 3.12
                tf.extractall(tmpdir, members=members)
    finally:
        os.unlink(tarball)
    pkg = find_package_dir(tmpdir)
    return pkg, used


# ---------------------------------------------------------------- 清单

def load_manifest(path: str) -> dict:
    with open(path, "rb") as f:
        manifest = json.loads(f.read().decode("utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("清单根必须是对象")
    upstream = manifest.get("upstream")
    if not isinstance(upstream, dict):
        raise ValueError("清单缺少 upstream 对象")
    methods = manifest.get("methods")
    if not isinstance(methods, list):
        raise ValueError("清单缺少 methods 数组")
    seen = set()
    for i, m in enumerate(methods):
        where = f"methods[{i}]"
        if not isinstance(m, dict):
            raise ValueError(f"{where}: 必须是对象")
        key = m.get("key")
        status = m.get("status")
        if not isinstance(key, str) or "." not in key:
            raise ValueError(f"{where}: key 必须是 'Class.method' 形式")
        if status not in VALID_STATUS:
            raise ValueError(f"{where}: status 必须是 {VALID_STATUS} 之一（得到 {status!r}）")
        if status == "implemented" and not m.get("command"):
            raise ValueError(f"{where}: status=implemented 必须给 command")
        if status == "not-planned" and not m.get("reason"):
            raise ValueError(f"{where}: status=not-planned 必须给 reason")
        if key in seen:
            raise ValueError(f"{where}: key 重复：{key}")
        seen.add(key)
    return manifest


# ---------------------------------------------------------------- 主流程

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="cube-cli × CubeSandbox Python SDK 漂移检查（对照 scripts/sdk-coverage.json）"
    )
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--sdk", metavar="PATH", help="本地 SDK 树（sdk/python、仓库根或 cubesandbox 包目录）")
    src.add_argument("--fetch", action="store_true", help="从 GitHub 拉 tarball")
    ap.add_argument("--ref", help="--fetch 的 git ref（分支/tag；默认取清单 upstream.tracked_ref）")
    ap.add_argument("--repo", help=f"--fetch 的仓库（默认取清单，再缺省 {DEFAULT_REPO}）")
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST, help="覆盖清单路径")
    ap.add_argument("--timeout", type=float, default=120.0, help="下载超时秒数（默认 120）")
    ap.add_argument("--no-signature-check", action="store_true", help="忽略签名变化（只看方法增删）")
    ap.add_argument("--list", action="store_true", help="列出清单里全部条目（key/状态/命令或原因）")
    ap.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    ap.add_argument("--quiet", action="store_true", help="无漂移时不打印（错误仍打印）")
    args = ap.parse_args(argv)

    result: dict = {"ok": False, "source": None, "new": [], "removed": [], "changed": [], "errors": []}

    try:
        manifest = load_manifest(args.manifest)
    except (OSError, ValueError) as exc:
        result["errors"].append(f"清单错误：{exc}")
        return _fail_json_or_text(args, result)

    upstream = manifest["upstream"]
    repo = args.repo or upstream.get("repo") or DEFAULT_REPO
    ref = args.ref or upstream.get("tracked_ref") or "master"

    try:
        if args.fetch:
            pkg, source = fetch_sdk(repo, ref, args.timeout)
            source_desc = f"{repo}@{ref}（{source}）"
        else:
            pkg = find_package_dir(args.sdk)
            source_desc = pkg
    except (OSError, RuntimeError, ValueError) as exc:
        result["errors"].append(str(exc))
        return _fail_json_or_text(args, result)

    try:
        sdk = extract_methods(pkg)
    except ValueError as exc:
        result["errors"].append(str(exc))
        return _fail_json_or_text(args, result)

    result["source"] = source_desc
    result["sdk_methods"] = len(sdk)

    manifest_map = {m["key"]: m for m in manifest["methods"]}
    new = sorted(k for k in sdk if k not in manifest_map)
    removed = sorted(k for k in manifest_map if k not in sdk)

    changed = []
    if not args.no_signature_check:
        for k in sorted(set(sdk) & set(manifest_map)):
            old, new_m = manifest_map[k], sdk[k]
            diffs = {}
            if old.get("signature") and old["signature"] != new_m["signature"]:
                diffs["signature"] = {"old": old["signature"], "new": new_m["signature"]}
            if old.get("kind") and old["kind"] != new_m["kind"]:
                diffs["kind"] = {"old": old["kind"], "new": new_m["kind"]}
            if diffs:
                changed.append({"key": k, **diffs})

    implemented = sum(1 for m in manifest["methods"] if m["status"] == "implemented")
    not_planned = sum(1 for m in manifest["methods"] if m["status"] == "not-planned")

    result.update(
        ok=not (new or removed or changed),
        new=new,
        removed=removed,
        changed=changed,
        counts={
            "sdk_methods": len(sdk),
            "manifest_total": len(manifest_map),
            "implemented": implemented,
            "not_planned": not_planned,
        },
    )

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result["ok"] else 1

    if result["ok"] and args.quiet:
        return 0

    shown_manifest = args.manifest if os.path.isabs(args.manifest) else os.path.relpath(args.manifest)
    print("cube-cli × CubeSandbox Python SDK 漂移检查 ｜ 清单 " + shown_manifest)
    print(f"SDK: {source_desc}（{len(sdk)} 个公开方法/属性）")
    print(f"清单同步自: {upstream.get('synced_version', '?')} @ {upstream.get('synced_at', '?')}"
          f"（tracked_ref={ref}）")
    print()
    _section("① 新增方法（SDK 有、清单无）→ 需要跟进", new)
    _section("② 消失方法（清单有、SDK 无）→ 复核清单/上游改名", removed)
    if args.no_signature_check:
        print("③ 签名变化: 已跳过（--no-signature-check）")
    elif not changed:
        print("③ 签名变化: 无")
    else:
        print(f"③ 签名变化 → 复核: {len(changed)} 个")
        for c in changed:
            bits = []
            for field, d in c.items():
                if field == "key":
                    continue
                bits.append(f"{field}: {d['old']!r} → {d['new']!r}")
            print(f"  ~ {c['key']}   {'; '.join(bits)}")
    print(f"④ 覆盖统计: {len(sdk)} 个方法中 implemented {implemented}、not-planned {not_planned}"
          f"（清单共 {len(manifest_map)} 条）")
    if args.list:
        print()
        print("—— 清单条目 ——")
        for m in manifest["methods"]:
            tail = m.get("command") if m["status"] == "implemented" else m.get("reason")
            print(f"  [{'✓' if m['status'] == 'implemented' else '—'}] {m['key']}  ← {tail}")
    print()
    if result["ok"]:
        print("✅ 无漂移：SDK 面与清单一致。")
        return 0
    print(f"❌ 发现漂移：新增 {len(new)}、消失 {len(removed)}、签名变化 {len(changed)} —— 清单需更新。")
    return 1


def _section(title: str, items: list) -> None:
    if not items:
        print(f"{title}: 无")
        return
    print(f"{title}: {len(items)} 个")
    for it in items:
        print(f"  + {it}" if isinstance(it, str) else f"  + {it}")


def _fail_json_or_text(args: argparse.Namespace, result: dict) -> int:
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for e in result["errors"]:
            print(f"错误: {e}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
