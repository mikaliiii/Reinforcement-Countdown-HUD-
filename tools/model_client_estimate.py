#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把客机估计器的算法逐字翻译成 Python，直接看它在实机节奏下卡在哪一步。

参数取自 v1.2.2 实机日志：总时长 77.4 秒、rate=2.842378、fraction 分辨率
1/255、主机约 2.1 Hz 下发、模组约 20 Hz 采样。
"""
from __future__ import annotations

RATE_WINDOW = 2.0
MIN_SPAN = 0.02
MIN_INTERVAL = 0.4
MIN_MOVE = 0.0002
JITTER = 0.008
STALL_LIMIT = 1.5
MAX_RATE_AGE = 8.0
MAX_DOWNWARD_RATE = 0.05
HISTORY = 256
LEVEL_SCALE = 4096

TOTAL = 77.4
LEVELS = 255
UPDATE_HZ = 2.1
SAMPLE_DT = 0.05


def level_of(f):
    return int(f * LEVEL_SCALE + 0.5)


class Est:
    def __init__(self):
        self.rate = None
        self.at = None
        self.prev_at = None
        self.prev = None
        self.envelope = None
        self.envelope_at = None
        self.history = []
        self.last_level = None
        self.saw_positive = False
        self.fit_fraction = None
        self.stall_at = None
        self.precise = None


def reset(e):
    e.rate = e.at = e.prev_at = e.prev = None
    e.envelope = e.envelope_at = None
    e.history = []
    e.last_level = None
    e.saw_positive = False
    e.fit_fraction = None
    e.stall_at = None


def push_history(e, clock, fraction):
    level = level_of(fraction)
    if level == e.last_level:
        return
    e.last_level = level
    if len(e.history) >= HISTORY:
        e.history.pop(0)
    e.history.append({"clock": clock, "fraction": fraction, "level": level})


def envelope_expected(e, clock):
    if e.envelope is None:
        return None
    decay = (e.rate or 0) * (clock - e.envelope_at)
    return e.envelope - decay


def client_estimate(e, clock, fraction):
    if fraction <= 0:
        finished = e.saw_positive
        reset(e)
        return "ready" if finished else "unknown"
    e.saw_positive = True
    push_history(e, clock, fraction)

    if e.prev_at is None:
        e.prev_at, e.prev = clock, fraction
        e.envelope, e.envelope_at = fraction, clock
        return "measuring"

    expected = envelope_expected(e, clock)
    elapsed = clock - e.prev_at
    previous = e.prev
    e.prev_at, e.prev = clock, fraction

    if expected is not None and fraction > expected + JITTER:
        e.rate = e.at = None
        e.envelope, e.envelope_at = fraction, clock
        e.history = []
        e.stall_at = None
        return "measuring"

    moved = True
    if elapsed >= MIN_INTERVAL and previous - fraction < MIN_MOVE:
        moved = False
        if e.stall_at and clock - e.stall_at > STALL_LIMIT:
            return "paused"
        if not e.stall_at:
            e.stall_at = clock
    if moved:
        e.stall_at = None

    anchor = None
    span = None
    for entry in e.history:
        if clock - entry["clock"] >= RATE_WINDOW:
            anchor = entry
            span = entry["fraction"] - fraction
        else:
            break

    diag = {"history": len(e.history), "anchor": anchor is not None, "span": span}
    if anchor is None or span is None or span < MIN_SPAN:
        return "measuring", diag

    if e.rate is not None and fraction >= (e.fit_fraction or 1) - 1e-9:
        if expected is None or fraction < expected:
            e.envelope, e.envelope_at = fraction, clock
        return "locked", diag

    count = len(e.history)
    sx = sum(x["clock"] for x in e.history)
    sy = sum(x["fraction"] for x in e.history)
    sxx = sum(x["clock"] ** 2 for x in e.history)
    sxy = sum(x["clock"] * x["fraction"] for x in e.history)
    den = count * sxx - sx * sx
    if den == 0:
        return "measuring", diag
    rate = -(count * sxy - sx * sy) / den

    widths = []
    for i in range(1, len(e.history)):
        d = e.history[i - 1]["fraction"] - e.history[i]["fraction"]
        if d > 1e-9:
            widths.append(d)
    level_width = None
    if widths:
        widths.sort()
        level_width = widths[(len(widths) - 1) // 2]
    if level_width is None or level_width < 1e-5:
        level_width = span / max(count - 1, 1)
    tol = max(6 * level_width, 1e-4)
    levels_spanned = span / level_width

    b = (sy - rate * sx) / count
    res = sum((x["fraction"] - (rate * x["clock"] + b)) ** 2 for x in e.history)
    rms = (res / count) ** 0.5
    diag["rate"] = rate
    diag["rms"] = rms
    diag["tol"] = 2 * level_width
    diag["levels"] = levels_spanned
    if levels_spanned >= 8 and rms > 2 * level_width:
        e.rate = e.at = None
        return "measuring", diag
    if rate <= 0 or rate > MAX_DOWNWARD_RATE:
        e.rate = e.at = None
        return "measuring", diag

    e.at, e.rate = clock, rate
    e.fit_fraction = fraction
    if expected is None or fraction < expected:
        e.envelope, e.envelope_at = fraction, clock
    return "locked", diag


def main() -> int:
    e = Est()
    next_update = -1e9
    update_dt = 1 / UPDATE_HZ
    counts = {}
    first_locked = None
    shown = []
    last_diag = None
    t = 0.0
    fraction = 1.0
    while t <= TOTAL + 2:
        if t >= next_update:
            next_update += update_dt
            raw = 1 - t / TOTAL
            q = int(raw * LEVELS + 0.5) / LEVELS
            fraction = q if q > 0 else 0.0
        outcome = client_estimate(e, t, fraction)
        if isinstance(outcome, tuple):
            state, diag = outcome
            last_diag = diag
        else:
            state = outcome
        counts[state] = counts.get(state, 0) + 1
        if state == "locked" and first_locked is None:
            first_locked = t
        if state == "locked" and e.rate:
            shown.append((round(t, 1), fraction, round(1 / e.rate, 2),
                          int(fraction / e.rate + 0.999)))
        t += SAMPLE_DT

    print("client_state 分布：%s" % counts)
    print("首次 locked：%s" % ("从未" if first_locked is None else "t=%.1f" % first_locked))
    if shown:
        print("\n锁定后给出的秒数（时刻, 比例, 推算总时长, 显示秒数）：")
        for row in shown[:18]:
            print("   t=%-6s fraction=%-9s T=%-7s seconds=%s" % row)
        deltas = [shown[i + 1][3] - shown[i][3] for i in range(min(17, len(shown) - 1))]
        print("\n   相邻差值：%s" % deltas)
    else:
        print("\n从未给出秒数。最后一次内部状态：%s" % last_diag)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
