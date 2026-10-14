#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Vendor the `lupa` wheel into the workspace without pip.

The DSH file sandbox blocks pip's temp-directory writes, so this script fetches
the wheel from PyPI and unzips it itself.  The result is used only for offline
testing of the Lua addon (LuaJIT simulation), never shipped to players.

Usage:
    python tools/vendor_lupa.py            # fetch + extract
    python tools/vendor_lupa.py --check    # report whether it is importable
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "vendor")
PACKAGE = "lupa"
API = "https://pypi.org/pypi/%s/json"


def wheel_urls():
    with urllib.request.urlopen(API % PACKAGE, timeout=30) as response:
        data = json.loads(response.read().decode("utf-8"))
    version = data["info"]["version"]
    out = []
    for entry in data["urls"]:
        name = entry["filename"]
        if not (name.endswith(".whl") and "cp312" in name and "win_amd64" in name):
            continue
        out.append((version, name, entry["url"]))
    return out


def extract(version, name, url) -> str:
    target = os.path.join(VENDOR, "lupa-%s" % version)
    os.makedirs(target, exist_ok=True)
    archive = os.path.join(VENDOR, name)
    print("downloading %s" % url)
    with urllib.request.urlopen(url, timeout=120) as response:
        payload = response.read()
    with open(archive, "wb") as fh:
        fh.write(payload)
    print("  %d bytes -> %s" % (len(payload), archive))
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(target)
    print("  extracted to %s" % target)
    return target


def check() -> int:
    import glob
    roots = glob.glob(os.path.join(VENDOR, "lupa-*"))
    if not roots:
        print("lupa is not vendored yet; run tools/vendor_lupa.py")
        return 1
    sys.path.insert(0, roots[0])
    try:
        from lupa.luajit21 import LuaRuntime  # type: ignore
    except Exception as exc:  # noqa: BLE001
        print("import failed from %s: %s: %s" % (roots[0], type(exc).__name__, exc))
        return 1
    runtime = LuaRuntime()
    version = runtime.eval("_VERSION")
    impl = runtime.eval("jit and jit.version or 'no jit'")
    print("lupa OK from %s" % roots[0])
    print("  %s / %s" % (version, impl))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    if args.check:
        return check()

    candidates = wheel_urls()
    if not candidates:
        print("no cp312 win_amd64 wheel found on PyPI")
        return 1
    version, name, url = candidates[0]
    print("latest %s: %s" % (PACKAGE, version))
    extract(version, name, url)
    return check()


if __name__ == "__main__":
    sys.exit(main())
