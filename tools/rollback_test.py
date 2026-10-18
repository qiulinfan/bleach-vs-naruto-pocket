#!/usr/bin/env python3
"""Rollback sync test: every tick the engine restores the state of six ticks
ago and simulates them again (Net.SyncTest); any difference in the Lua state
means NET PLAY's rollback would desync. Runs CPU vs CPU battles over fighter
pairs (skills, assists, transformations, summons) and a VS PEOPLE session with
random input from the fighter select through a whole match.

Usage: tools/rollback_test.py [game] [--pairs N] [--frames N]
"""
import json
import os
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT.parent.parent / "pocket2d"


class Game:
    def __init__(self, exe, saves):
        # Snapshots keep up to eight states alive: above the agent's default 64 MiB Lua budget.
        self.p = subprocess.Popen([exe, "--headless", "--agent", "--lua-heap-budget", str(256 << 20), "--project", str(ROOT)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                  env=dict(os.environ, POCKET_SAVE_ROOT=saves))

    def req(self, c):
        self.p.stdin.write(json.dumps(c) + "\n")
        self.p.stdin.flush()
        r = json.loads(self.p.stdout.readline())
        if not r.get("ok"):
            raise AssertionError(str(r)[:500])
        return r

    def call(self, name, args=None):
        r = self.req({"cmd": "call", "name": name, "args": args or {}})
        return next((x["value"] for x in r["call"]["results"] if x.get("value") is not None), None)

    def close(self):
        self.p.stdin.write('{"cmd":"quit"}\n')
        self.p.stdin.flush()
        self.p.wait(timeout=30)


def fighters():
    cfg = (ROOT / "component_types/generated/BVNConfig.lua").read_text(encoding="utf-8")
    have = {f[5:-4] for f in os.listdir(ROOT / "data/bvn") if f.startswith("BVNF_")}
    ids = []
    for m in re.finditer(r'\["id"\]="([^"]+)",.*?\["file"\]="([^"]+)\.swf"', cfg):
        if m.group(2) in have and m.group(1) not in ids and not m.group(1).startswith(("random", "fz")):
            ids.append(m.group(1))
    return ids


def session(exe, saves, label, setup, frames, inputs):
    g = Game(exe, saves)
    try:
        g.req({"cmd": "step", "frames": 3})
        setup(g)
        check = g.call("net_synctest", {"frames": 6})
        assert check and check["ok"], "sync test starts"
        rng = random.Random(1)
        phases = []
        for i in range(frames // 10):
            g.req({"cmd": "step", "frames": 10, "actions": inputs(rng, i)})
            s = g.call("net_state")
            if not phases or phases[-1] != s["phase"]:
                phases.append(s["phase"])
            if s["status"]["desync"]:
                break
        st = s["status"]
        ok = not st["desync"]
        print("%-44s %s  %d ticks  %s" % (label, "ok" if ok else "DESYNC at tick %d" % st["desync_frame"], st["frame"],
                                         " > ".join(phases)), flush=True)
        return ok
    finally:
        g.close()


KEYS = ["attack", "jump", "dash", "skill", "super", "assist", "up", "down"]


def random_input(rng, i):
    a = {}
    for p in ("p1_", "p2_"):
        a[p + "move"] = rng.choice([-1, 0, 0, 1])
        for k in KEYS:
            if rng.random() < 0.12:
                a[p + k] = True
    if rng.random() < 0.05:
        a["confirm"] = True
    return a


def main():
    given = len(sys.argv) > 1 and not sys.argv[1].startswith("--")
    exe = sys.argv[1] if given else str(ENGINE / "build/sdl3-release/game")
    def opt(name, default):
        return int(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default
    pairs, frames = opt("--pairs", 6), opt("--frames", 600)
    ids = fighters()
    step = max(1, len(ids) // pairs)
    failures = 0
    with tempfile.TemporaryDirectory(prefix="bvn-rollback-") as saves:
        for i in range(0, len(ids), step)[:pairs]:
            a, b = ids[i], ids[(i + 7) % len(ids)]
            setup = lambda g, a=a, b=b: g.call("start_battle", {"mode": "watch", "level": 5, "skip_intro": True,
                                                                  "map": "xianshi", "p1": a, "p2": b})
            failures += not session(exe, saves, "%s vs %s (CPU)" % (a, b), setup, frames, lambda r, i: {})
        team = lambda g: g.call("start_battle", {"mode": "watch", "level": 6, "skip_intro": True, "p1_assist": "kon",
                                                 "p2_assist": "kyuubi", "p1_team": ["ichigo", "gaara", "itachi"],
                                                 "p2_team": ["naruto", "aizen_gz", "byakuya_bankai"]})
        failures += not session(exe, saves, "team battle with assists (CPU)", team, frames * 2, lambda r, i: {})
        flow = lambda g: g.call("goto", {"stage": "select", "mode": "pvp", "team": False})
        ok = session(exe, saves, "VS PEOPLE from the select, random input", flow, 9000, random_input)
        failures += not ok
    if failures:
        raise SystemExit("%d rollback sync test(s) failed" % failures)
    print("rollback_test passed")


if __name__ == "__main__":
    main()
