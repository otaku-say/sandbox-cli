#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-v2-drift.py —— aiod v2 API 漂移检查（aiod-cli 跟进纪律的自动化）。

长期纪律：aiod-cli 始终跟随 aiod 的 /v2 API。本脚本把「运行中的 aiod 网关
/ 本地 OpenAPI 快照」与签入清单 scripts/v2-coverage.json 比对，输出：

  ① 新增端点：API 有、清单无  → 需要跟进（补命令，或在清单标记 not-planned+原因）
  ② 消失端点：清单有、API 无  → 上游删除/改名，复核清单
  ③ 覆盖统计：/v2/ 范围内 implemented / not-planned 计数

有漂移时退出码非 0，可直接进 CI / 定时任务：
  退出码 0 = 无漂移；1 = 有漂移；2 = 输入/清单错误（拉取失败、清单不合法等）。

用法：
  python3 scripts/check-v2-drift.py                 # 默认 --base=http://127.0.0.1:8080（沙箱内自测）
  python3 scripts/check-v2-drift.py --base=https://<网关>/sandbox/<sid>/8080
  python3 scripts/check-v2-drift.py --openapi=/path/openapi.json    # 离线快照
  python3 scripts/check-v2-drift.py --base=... --json               # 机器可读

清单位置：--manifest=（默认与本脚本同目录的 v2-coverage.json）。
清单里的 "scope" 声明检查范围（当前 ["/v2/"]）；范围外的路由（/v1、/health、/mcp 等）
只统计数量、不参与漂移判定。

仅用 Python 3 标准库。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

DEFAULT_BASE = "http://127.0.0.1:8080"
HTTP_METHODS = ("get", "put", "post", "delete", "patch", "head", "options", "trace")
VALID_STATUS = ("implemented", "not-planned")
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MANIFEST = os.path.join(HERE, "v2-coverage.json")

_PARAM_RE = re.compile(r"\{[^}]*\}")


def route_key(method: str, path: str) -> str:
    """比较用键：方法大写 + 路径参数归一化（{command_id} → {}）。

    参数名重命名（如 {session_id} → {id}）不算漂移；路径段本身变化才算。
    """
    return method.upper() + " " + _PARAM_RE.sub("{}", path)


def fetch_openapi(base: str, timeout: float) -> tuple[dict, str]:
    url = base.rstrip("/") + "/openapi.json"
    req = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "sandbox-cli-drift-check"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8")), url


def load_openapi_file(path: str) -> tuple[dict, str]:
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8")), path


def extract_operations(spec: dict) -> list[tuple[str, str]]:
    """从 OpenAPI 提取全部 (METHOD, path)。"""
    ops = []
    paths = spec.get("paths") or {}
    if not isinstance(paths, dict):
        raise ValueError("openapi.json 缺少合法的 paths 对象")
    for path, item in paths.items():
        if not isinstance(item, dict):
            continue
        for method, op in item.items():
            if method.lower() in HTTP_METHODS and isinstance(op, dict):
                ops.append((method.upper(), path))
    return sorted(ops)


def load_manifest(path: str) -> dict:
    with open(path, "rb") as f:
        manifest = json.loads(f.read().decode("utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("清单根必须是对象")

    scope = manifest.get("scope", ["/v2/"])
    if not isinstance(scope, list) or not scope:
        raise ValueError("清单 scope 必须是非空数组，如 [\"/v2/\"]")
    endpoints = manifest.get("endpoints")
    if not isinstance(endpoints, list):
        raise ValueError("清单缺少 endpoints 数组")

    seen: dict[str, str] = {}
    for i, ep in enumerate(endpoints):
        where = f"endpoints[{i}]"
        if not isinstance(ep, dict):
            raise ValueError(f"{where}: 必须是对象")
        method = ep.get("method")
        mpath = ep.get("path")
        status = ep.get("status")
        if not isinstance(method, str) or not isinstance(mpath, str) or not mpath.startswith("/"):
            raise ValueError(f"{where}: method/path 缺失或非法")
        if status not in VALID_STATUS:
            raise ValueError(f"{where}: status 必须是 {VALID_STATUS} 之一（得到 {status!r}）")
        if status == "implemented" and not ep.get("command"):
            raise ValueError(f"{where}: status=implemented 必须给 command")
        if status == "not-planned" and not ep.get("reason"):
            raise ValueError(f"{where}: status=not-planned 必须给 reason")
        k = route_key(method, mpath)
        if k in seen:
            raise ValueError(f"{where}: 与前面的条目重复：{k}")
        seen[k] = str(status)
    return manifest


def in_scope(path: str, scope: list[str]) -> bool:
    return any(path.startswith(prefix) for prefix in scope)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="aiod v2 API 漂移检查（对照 scripts/v2-coverage.json）"
    )
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--base", default=DEFAULT_BASE, help=f"aiod 网关地址（默认 {DEFAULT_BASE}）")
    src.add_argument("--openapi", metavar="FILE", help="本地 OpenAPI JSON 快照（离线模式）")
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST, help="覆盖清单路径")
    ap.add_argument("--timeout", type=float, default=20.0, help="拉取超时秒数（默认 20）")
    ap.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    ap.add_argument("--quiet", action="store_true", help="无漂移时不打印（错误仍打印）")
    args = ap.parse_args(argv)

    result: dict = {"ok": False, "source": None, "new": [], "removed": [], "errors": []}

    try:
        manifest = load_manifest(args.manifest)
    except (OSError, ValueError) as exc:
        result["errors"].append(f"清单错误：{exc}")
        return _fail_json_or_text(args, result)

    try:
        if args.openapi:
            spec, source = load_openapi_file(args.openapi)
        else:
            spec, source = fetch_openapi(args.base, args.timeout)
    except urllib.error.URLError as exc:
        result["errors"].append(f"拉取 {args.base}/openapi.json 失败：{exc}")
        return _fail_json_or_text(args, result)
    except (OSError, ValueError) as exc:
        result["errors"].append(f"读取 OpenAPI 失败：{exc}")
        return _fail_json_or_text(args, result)

    try:
        api_ops = extract_operations(spec)
    except ValueError as exc:
        result["errors"].append(str(exc))
        return _fail_json_or_text(args, result)

    result["source"] = source
    spec_version = ((spec.get("info") or {}).get("version")) or "?"
    scope = manifest.get("scope", ["/v2/"])
    result["spec_version"] = spec_version
    result["scope"] = scope

    api_in_scope = {route_key(m, p): (m, p) for (m, p) in api_ops if in_scope(p, scope)}
    api_out = [o for o in api_ops if not in_scope(o[1], scope)]
    manifest_eps = {route_key(e["method"], e["path"]): e for e in manifest["endpoints"]}

    new = sorted(k for k in api_in_scope if k not in manifest_eps)
    removed = sorted(k for k in manifest_eps if k not in api_in_scope)

    implemented = sum(1 for e in manifest["endpoints"] if e["status"] == "implemented")
    not_planned = sum(1 for e in manifest["endpoints"] if e["status"] == "not-planned")

    result.update(
        ok=not (new or removed),
        new=[{"key": k, "method": api_in_scope[k][0], "path": api_in_scope[k][1]} for k in new],
        removed=[{"key": k, "method": manifest_eps[k]["method"], "path": manifest_eps[k]["path"]} for k in removed],
        counts={
            "api_total": len(api_ops),
            "api_in_scope": len(api_in_scope),
            "api_out_of_scope": len(api_out),
            "manifest_total": len(manifest_eps),
            "implemented": implemented,
            "not_planned": not_planned,
        },
    )

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result["ok"] else 1

    if result["ok"] and args.quiet:
        return 0

    # ---- 人类可读输出 ----
    shown_manifest = args.manifest if os.path.isabs(args.manifest) else os.path.relpath(args.manifest)
    print("aiod v2 漂移检查 ｜ 清单 " + shown_manifest)
    print(f"来源: {source}  （版本 {spec_version}）")
    c = result["counts"]
    print(
        f"提取: 全 API {c['api_total']} 个操作 ｜ 检查范围 {'/'.join(scope)}（in-scope {c['api_in_scope']}，"
        f"范围外 {c['api_out_of_scope']} 个仅计数）"
    )
    print()
    _section("① 新增端点（API 有、清单无）→ 需要跟进", result["new"], "+")
    _section("② 消失端点（清单有、API 无）→ 复核清单/上游改名", result["removed"], "-")
    print(f"③ 覆盖统计: in-scope {c['api_in_scope']} 个端点中 implemented {c['implemented']}、"
          f"not-planned {not_planned}（清单共 {c['manifest_total']} 条）")
    print()
    if result["ok"]:
        print(f"✅ 无漂移：清单与上游一致（{c['api_in_scope']}/{c['api_in_scope']}）。")
        return 0
    print(f"❌ 发现漂移：新增 {len(new)} 个、消失 {len(removed)} 个 —— 清单需更新。")
    return 1


def _section(title: str, items: list, sign: str) -> None:
    if not items:
        print(f"{title}: 无")
        return
    print(f"{title}: {len(items)} 个")
    for it in items:
        print(f"  {sign} {it['key']}")


def _fail_json_or_text(args: argparse.Namespace, result: dict) -> int:
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for e in result["errors"]:
            print(f"错误: {e}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
