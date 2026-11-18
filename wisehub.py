#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6"]
# ///
"""wisehub —— Wise Compute 最小复现用的编排器。

只做设计规范 §4 中 wisehub 的职责：配置解析、兼容性检查、锁定、生成 devcontainer.json、
调用 Dev Container CLI 构建、验证。依赖展开和安装顺序交给 Dev Container CLI 自己处理；
这里展开依赖闭包只是为了做 ABI 检查和复制本地 Feature。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent
CATALOG = ROOT / "features"
DEVCONTAINER = os.environ.get("DEVCONTAINER_CLI", "devcontainer")
DOCKER = os.environ.get("DOCKER", "docker")


class ConflictError(Exception):
    pass


# ---------------------------------------------------------------- 配置解析
def load_profile(args) -> dict:
    if args.file:
        prof = yaml.safe_load(Path(args.file).read_text())
    else:
        prof = {"features": {f: {} for f in args.with_.split(",") if f}}
    prof.setdefault("base", "docker.io/library/ubuntu:24.04")
    prof.setdefault("platform", "linux/amd64")
    prof["features"] = {k: (v or {}) for k, v in prof.get("features", {}).items()}
    if args.tag:
        prof["tag"] = args.tag
    prof.setdefault("tag", "wise/compute:dev")
    return prof


def feature_meta(fid: str) -> dict:
    p = CATALOG / fid / "devcontainer-feature.json"
    if not p.exists():
        raise ConflictError(f"unknown feature '{fid}' (not in {CATALOG})")
    return json.loads(p.read_text())


def local_id(ref: str) -> str:
    return ref.rstrip("/").split("/")[-1]


def closure(requested: list[str]) -> list[str]:
    """按 dependsOn 展开闭包（只用于检查，安装顺序由 Dev Container CLI 决定）。"""
    seen: list[str] = []
    stack = list(requested)
    while stack:
        f = stack.pop()
        if f in seen:
            continue
        seen.append(f)
        stack += [local_id(d) for d in feature_meta(f).get("dependsOn", {})]
    return sorted(seen)


# ---------------------------------------------------------------- 兼容性检查（§3.3）
def check_compat(features: list[str]) -> dict:
    providers: dict[str, list[tuple[str, str]]] = {}
    requires: dict[str, list[str]] = {}
    for f in features:
        w = feature_meta(f).get("customizations", {}).get("wisehub", {})
        for cap, val in w.get("provides", {}).items():
            providers.setdefault(cap, []).append((f, val))
        for cap in w.get("requires", []):
            requires.setdefault(cap, []).append(f)
    errors = []
    for cap, ps in providers.items():
        if len({v for _, v in ps}) > 1:
            errors.append(f"capability '{cap}' provided by multiple incompatible features: "
                          + ", ".join(f"{f}={v}" for f, v in ps))
    for cap, users in requires.items():
        if cap not in providers:
            errors.append(f"capability '{cap}' required by {', '.join(users)} but no selected feature provides it")
    if errors:
        # 明确报告，不静默修改用户配置
        raise ConflictError("\n  - " + "\n  - ".join(errors))
    return {cap: ps[0][1] for cap, ps in providers.items()}


# ---------------------------------------------------------------- 锁定（§6.2）
def dir_digest(path: Path) -> str:
    h = hashlib.sha256()
    for p in sorted(path.rglob("*")):
        if p.is_file():
            h.update(p.relative_to(path).as_posix().encode() + b"\0")
            h.update(p.read_bytes() + b"\0")
    return "sha256:" + h.hexdigest()


def resolve_image_digest(ref: str, retries: int = 3) -> str:
    for i in range(retries):
        try:
            return _resolve_image_digest(ref)
        except (OSError, KeyError) as e:
            if i == retries - 1:
                raise SystemExit(f"[wisehub] cannot resolve digest for {ref}: {e}")
            print(f"[wisehub] digest lookup failed ({e}), retrying…", file=sys.stderr)


def _resolve_image_digest(ref: str) -> str:
    """不依赖 docker，直接问 registry 要 manifest digest（支持匿名 bearer token）。"""
    if "@sha256:" in ref:
        return ref.split("@", 1)[1]
    name, tag = ref.rsplit(":", 1)
    host, repo = name.split("/", 1)
    if host == "docker.io":
        host = "registry-1.docker.io"
    url = f"https://{host}/v2/{repo}/manifests/{tag}"
    accept = ", ".join([
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ])
    req = urllib.request.Request(url, method="HEAD", headers={"Accept": accept})
    try:
        resp = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        if e.code != 401:
            raise
        params = dict(kv.split("=", 1) for kv in
                      e.headers["WWW-Authenticate"].split(" ", 1)[1].replace('"', "").split(","))
        tok_url = f"{params['realm']}?service={params['service']}&scope={params.get('scope', f'repository:{repo}:pull')}"
        token = json.load(urllib.request.urlopen(tok_url, timeout=30))["token"]
        req.add_header("Authorization", f"Bearer {token}")
        resp = urllib.request.urlopen(req, timeout=30)
    return resp.headers["Docker-Content-Digest"]


def make_lock(prof: dict, features: list[str], caps: dict, prior: dict | None) -> dict:
    # 已锁定的 base digest 直接复用；只有 --update 才重新解析 tag（锁的意义）
    if prior and prior.get("base", {}).get("ref") == prof["base"]:
        base_digest = prior["base"]["digest"]
    else:
        base_digest = resolve_image_digest(prof["base"])
    lock = {
        "base": {"ref": prof["base"], "digest": base_digest},
        "platform": prof["platform"],
        "features": {},
        "capabilities": caps,
    }
    for f in features:
        m = feature_meta(f)
        opts = {k: v.get("default") for k, v in m.get("options", {}).items()}
        opts.update(prof["features"].get(f, {}))
        lock["features"][f] = {
            "version": m["version"],
            "digest": dir_digest(CATALOG / f),  # 本地 Feature 不在原生 lockfile 覆盖范围内，这里补充
            "options": opts,
            "requested": f in prof["features"],
        }
    lock["compose_key"] = "sha256:" + hashlib.sha256(
        json.dumps(lock, sort_keys=True).encode()).hexdigest()
    return lock


# ---------------------------------------------------------------- 生成标准 devcontainer.json
def generate(prof: dict, lock: dict, out: Path) -> Path:
    dc = out / ".devcontainer"
    if dc.exists():
        shutil.rmtree(dc)
    (dc / "features").mkdir(parents=True)
    for f in lock["features"]:
        shutil.copytree(CATALOG / f, dc / "features" / f)
    base = lock["base"]["ref"].rsplit(":", 1)[0] + "@" + lock["base"]["digest"]
    cfg = {
        "name": prof["tag"],
        "image": base,
        # 只写用户请求的 Feature；dependsOn 的展开交给 Dev Container CLI
        "features": {f"./features/{f}": prof["features"][f] for f in sorted(prof["features"])},
    }
    (dc / "devcontainer.json").write_text(json.dumps(cfg, indent=2) + "\n")
    (out / "wisehub.lock.json").write_text(json.dumps(lock, indent=2) + "\n")
    return dc / "devcontainer.json"


# ---------------------------------------------------------------- 构建 / 验证
def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.run(cmd, **kw)


def image_exists(ref: str) -> bool:
    return sh([DOCKER, "image", "inspect", ref], capture_output=True).returncode == 0


def verify(tag: str, features: list[str]) -> None:
    for f in features:
        smoke = feature_meta(f).get("customizations", {}).get("wisehub", {}).get("smoke")
        if not smoke:
            continue
        r = sh([DOCKER, "run", "--rm", tag, "bash", "-lc", smoke], capture_output=True, text=True)
        status = "ok" if r.returncode == 0 else "FAIL"
        print(f"  verify {f:8s} {status}  {(r.stdout or r.stderr).strip().splitlines()[-1:]}")
        if r.returncode:
            raise SystemExit(f"verification failed for feature '{f}'")


def cmd_build(prof, lock, out: Path, args) -> None:
    generate(prof, lock, out)
    key = lock["compose_key"].split(":")[1][:16]
    cache_ref = f"wisehub-cache/compose:{key}"
    if image_exists(cache_ref) and not args.no_cache:
        print(f"[compose-cache] HIT {cache_ref} -> {prof['tag']} (skip build)")
        sh([DOCKER, "tag", cache_ref, prof["tag"]], check=True)
    else:
        print(f"[compose-cache] MISS {cache_ref}")
        sh([DEVCONTAINER, "build", "--workspace-folder", str(out),
            "--platform", prof["platform"],
            "--image-name", prof["tag"], "--image-name", cache_ref,
            "--label", f"io.wisehub.compose-key={lock['compose_key']}",
            "--label", f"io.wisehub.capabilities={json.dumps(lock['capabilities'], sort_keys=True)}"],
           check=True)
    verify(prof["tag"], list(lock["features"]))
    image_id = sh([DOCKER, "image", "inspect", "-f", "{{.Id}}", prof["tag"]],
                  capture_output=True, text=True, check=True).stdout.strip()
    result = {"tag": prof["tag"], "image_id": image_id, "compose_key": lock["compose_key"]}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def main() -> None:
    ap = argparse.ArgumentParser(prog="wisehub")
    sub = ap.add_subparsers(dest="group", required=True)
    comp = sub.add_parser("compute").add_subparsers(dest="cmd", required=True)
    for name in ("plan", "generate", "build"):
        p = comp.add_parser(name)
        src = p.add_mutually_exclusive_group(required=True)
        src.add_argument("-f", "--file", help="compute.yaml")
        src.add_argument("--with", dest="with_", help="comma separated features")
        p.add_argument("--tag")
        p.add_argument("--out", default=None, help="output dir (default build/<tag>)")
        p.add_argument("--no-cache", action="store_true")
        p.add_argument("--update", action="store_true", help="re-resolve base image tag instead of reusing lock")
    args = ap.parse_args()

    prof = load_profile(args)
    out = Path(args.out or ROOT / "build" / prof["tag"].replace("/", "_").replace(":", "_"))
    try:
        feats = closure(list(prof["features"]))
        caps = check_compat(feats)
    except ConflictError as e:
        print(f"[wisehub] incompatible feature set {sorted(prof['features'])}:{e}", file=sys.stderr)
        raise SystemExit(2)
    print(f"[wisehub] requested={sorted(prof['features'])} closure={feats} capabilities={caps}")
    if args.cmd == "plan":
        return
    lock_path = out / "wisehub.lock.json"
    prior = None if args.update or not lock_path.exists() else json.loads(lock_path.read_text())
    lock = make_lock(prof, feats, caps, prior)
    if args.cmd == "generate":
        print(f"[wisehub] wrote {generate(prof, lock, out)}  compose_key={lock['compose_key'][:23]}…")
        return
    cmd_build(prof, lock, out, args)


if __name__ == "__main__":
    main()
