#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""分析 v1.2.1 客机段：为什么 client_state 一直是 measuring。

关键怀疑：HISTORY=16 固定长度，而客机的 fraction 更新很快，
16 条记录覆盖的时间跨度够不到 RATE_WINDOW=4 秒，于是永远找不到 anchor。
"""
from __future__ import annotations

import os
import re

LOG = os.path.join(os.environ.get("LOCALAPPDATA", ""),
                   "CowboyBingus", "Helldivers2", "Logs", "ReinforcementRadar.log")

LINE = re.compile(
    r"^\[(?P<ts>[\d\- :]+)\]\s+DIAG\s+authoritative=(?P<auth>\w+)\s+"
    r"fraction=(?P<frac>[\d.]+)\s+rate=(?P<rate>[\d.]+)\s+"
    r"raw_field=(?P<raw>[\d.]+).*?client_state=(?P<cs>\w+)"
)


def sec(stamp: str) -> float:
    """'2026-10-13 23:22:56' 或 '23:22:56' -> 当天的秒数。"""
    stamp = stamp.strip().split(" ")[-1]
    h, m, s = (float(x) for x in stamp.split(":"))
    return h * 3600 + m * 60 + s


def main() -> int:
    with open(LOG, "rb") as fh:
        raw = fh.read().decode("utf-8", "replace")

    # 只看 v1.2.1 之后的行
    idx = raw.rfind("=== Reinforcement Radar v1.2.1")
    if idx < 0:
        print("日志里没有 v1.2.1 段")
        return 1
    text = raw[idx:]

    rows = []
    for line in text.split("\n"):
        m = LINE.match(line.strip())
        if m:
            rows.append((sec(m.group("ts")), m.group("auth"), float(m.group("frac")),
                         float(m.group("rate")), float(m.group("raw")), m.group("cs")))

    clients = [r for r in rows if r[1] == "false"]
    print("v1.2.1 段：DIAG 共 %d 条，其中客机 %d 条" % (len(rows), len(clients)))
    if not clients:
        print("客机段没有 DIAG 行")
        return 1

    print()
    print("=" * 76)
    print("A. 客机的 fraction 更新节奏（相邻 DIAG 行的间隔）")
    print("=" * 76)
    gaps = []
    changed = []
    prev = None
    for t, _auth, frac, rate, raw, cs in clients:
        if prev:
            dt = t - prev[0]
            if dt >= 0:
                gaps.append(dt)
            if abs(frac - prev[2]) > 1e-6 and dt > 0:
                changed.append(dt)
        prev = (t, frac, rate)
    if gaps:
        print("  相邻 DIAG 行间隔：中位数 %.3f 秒，最大 %.3f 秒，共 %d 个"
              % (sorted(gaps)[len(gaps) // 2], max(gaps), len(gaps)))
    if changed:
        print("  fraction 真正变化的间隔：中位数 %.3f 秒，最大 %.3f 秒，共 %d 个"
              % (sorted(changed)[len(changed) // 2], max(changed), len(changed)))
        print()
        print("  => 每格约 %.2f 秒。" % (sum(changed) / len(changed)))
        print("     HISTORY=16 条记录覆盖的时间跨度 ≈ 16 × %.2f = %.1f 秒"
              % (sum(changed) / len(changed),
                 16 * sum(changed) / len(changed)))
        print("     RATE_WINDOW = 4.0 秒 —— 若跨度 < 4 秒，就永远找不到 anchor！")

    print()
    print("=" * 76)
    print("B. client_state 的分布")
    print("=" * 76)
    from collections import Counter
    c = Counter(r[5] for r in clients)
    for k, v in c.most_common():
        print("  %-12s %d 条" % (k, v))
    print()
    print("  => 全程 measuring 说明「窗口没满」，从来没锁定过速率。")

    print()
    print("=" * 76)
    print("C. 反推 K：客机 rate 与 fraction 斜率")
    print("=" * 76)
    # 用连续同 rate 的一段算斜率
    seg = [r for r in clients if r[3] == clients[0][3]]
    if len(seg) > 5:
        t0, f0 = seg[0][0], seg[0][2]
        t1, f1 = seg[-1][0], seg[-1][2]
        slope = (f0 - f1) / (t1 - t0)
        rate = seg[0][3]
        print("  取一段：rate=%.6f  Δt=%.1f 秒  Δfraction=%.6f  slope=%.6f/秒"
              % (rate, t1 - t0, f0 - f1, slope))
        if slope > 0:
            print("  若 K 是常数且 fraction = raw/(K/rate)：")
            print("     K = rate^2 / slope = %.1f" % (rate * rate / slope))
            print("     总时长 T = K/rate = %.1f 秒" % (rate / slope))
            print("  对照权威端实测 K=220（rate=0.9 时 T=244.4 秒）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
