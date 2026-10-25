#!/usr/bin/env python3
"""Drives real battles headless (the agent protocol) to look at every fighter,
assist and musou mook as the runtime draws them.

Per fighter (each select entry of fighter.json, alternate forms included): a
battle against a standing opponent with full energy; the fighter idles, walks,
attacks, uses its skills, 招, ultimates, the J+K transformation and its
assist, and a frame is captured at fixed ticks of each move. Per assist: a
battle where player 1 calls it. Per mook: it fights as player 2.

Writes under OUT/<kind> (OUT defaults to the engine's build/bvn-audit/battle):
  <id>.png       a contact sheet of the captured frames
  report.json    per id: the form after the select entry's start (main_mc
                 frame), the frames' sprites, engine and script errors from the
                 diagnostics, missing images, and frames whose fighter drew
                 nothing
Usage: tools/battle_audit.py [game] [--only ids...] [--out DIR] [--kind fighters|assists|mooks]
"""
import argparse
import base64
import io
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "external" / "BleachVsNaruto" / "shared" / "assets" / "assets" / "config"


def find_engine():
    if os.environ.get("POCKET2D_ENGINE"):
        return Path(os.environ["POCKET2D_ENGINE"])
    for candidate in (ROOT.parent / "pocket2d", ROOT.parent.parent / "pocket2d"):
        if candidate.is_dir():
            return candidate
    return ROOT.parent / "pocket2d"


ENGINE = find_engine()


def default_game():
    """The engine's runtime when none is given: POCKET_GAME, else its newest preset
    build, Release first (pocket2d.cli.find_game)."""
    sys.path.insert(0, str(ENGINE / "clients/python"))
    from pocket2d.cli import find_game
    return find_game(None)
W, H = 640, 360

# (label, held actions per step, ticks to hold, ticks to wait after, capture ticks after the press)
MOVES = [
    ("idle", {}, 1, 30, [1, 29]),
    ("walk", {"p1_move": 1}, 20, 10, [10]),
    ("J", {"p1_attack": True}, 1, 40, [4, 10, 18]),
    ("J chain", {"p1_attack": True}, 1, 8, [4]),
    ("J chain", {"p1_attack": True}, 1, 40, [6, 14]),
    ("S+J", {"p1_down": True, "p1_attack": True}, 1, 50, [6, 16, 30]),
    ("W+J", {"p1_up": True, "p1_attack": True}, 1, 50, [6, 16, 30]),
    ("U", {"p1_skill": True}, 1, 60, [6, 16, 30, 45]),
    ("S+U", {"p1_down": True, "p1_skill": True}, 1, 60, [6, 16, 30, 45]),
    ("W+U", {"p1_up": True, "p1_skill": True}, 1, 60, [6, 16, 30, 45]),
    ("I", {"p1_super": True}, 1, 120, [10, 30, 60, 90]),
    ("W+I", {"p1_up": True, "p1_super": True}, 1, 140, [10, 40, 80, 120]),
    ("S+I", {"p1_down": True, "p1_super": True}, 1, 160, [10, 40, 80, 120, 150]),
    ("jump J", {"p1_jump": True}, 1, 4, []),
    ("air J", {"p1_attack": True}, 1, 40, [4, 12]),
    ("dash", {"p1_dash": True}, 1, 30, [4]),
    ("J+K", {"p1_attack": True, "p1_jump": True}, 1, 160, [20, 60, 120]),
    ("after J+K", {"p1_attack": True}, 1, 40, [6, 16]),
    ("O", {"p1_assist": True}, 1, 120, [20, 50, 90]),
]


class Game:
    def __init__(self, exe, saves):
        self.p = subprocess.Popen([exe, "--headless", "--agent", "--lua-heap-budget", str(256 << 20), "--project", str(ROOT)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                  env=dict(os.environ, POCKET_SAVE_ROOT=saves))
        self.diagnostics = []

    def req(self, c):
        self.p.stdin.write(json.dumps(c) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("game exited")
        r = json.loads(line)
        self.diagnostics += r.get("diagnostics", [])
        if not r.get("ok"):
            raise RuntimeError(str(r)[:500])
        return r

    def call(self, name, args=None):
        r = self.req({"cmd": "call", "name": name, "args": args or {}})
        return next((x["value"] for x in r["call"]["results"] if x.get("value") is not None), None)

    def step(self, frames=1, actions=None, image=False):
        c = {"cmd": "step", "frames": frames, "actions": actions or {}}
        if image:
            c["image"] = {"width": W, "height": H}
        r = self.req(c)
        if image:
            return Image.open(io.BytesIO(base64.b64decode(r["image"]["data"]))).convert("RGB")
        return None

    def close(self):
        try:
            self.p.stdin.write('{"cmd":"quit"}\n')
            self.p.stdin.flush()
            self.p.wait(timeout=20)
        except Exception:
            self.p.kill()


def play_moves(g, moves, top_up):
    shots = []
    for label, actions, hold, wait, caps in moves:
        top_up()
        g.step(1, actions)
        held = dict(actions)
        t = 1
        for c in sorted(caps):
            while t < c:
                g.step(1, held if t < hold else {})
                t += 1
            shots.append(("%s +%d" % (label, c), g.step(1, held if t < hold else {}, image=True)))
            t += 1
        if t < hold + wait:
            g.step(hold + wait - t, {})
    return shots


def sheet(shots, out, title):
    cols = 6
    rows = (len(shots) + cols - 1) // cols
    cw, ch = W // 2, H // 2
    im = Image.new("RGB", (cols * cw, rows * (ch + 12) + 16), (30, 30, 30))
    d = ImageDraw.Draw(im)
    d.text((4, 2), title, fill=(255, 255, 0))
    for i, (label, frame) in enumerate(shots):
        x, y = (i % cols) * cw, 16 + (i // cols) * (ch + 12)
        im.paste(frame.resize((cw, ch)), (x, y))
        d.text((x + 2, y + ch), label, fill=(220, 220, 220))
    im.save(out)


def interesting(diags):
    keep = []
    for d in diags:
        m = d.get("message", "")
        if d.get("level") in ("warning", "error") or "error" in m.lower() or "missing" in m.lower():
            keep.append("%s/%s: %s" % (d.get("level"), d.get("category"), m[:300]))
    return keep


def fighter_state(g):
    return g.call("audit_state") or {}


def run_fighter(g, fid, out, kind):
    g.diagnostics = []
    if kind == "assists":
        g.call("start_battle", {"p1": "ichigo", "p2": "naruto", "p1_assist": fid, "mode": "pvp", "skip_intro": True})
        moves = [("idle", {}, 1, 10, [1]), ("O", {"p1_assist": True}, 1, 150, [10, 25, 40, 60, 80, 100, 130]),
                 ("O again", {"p1_assist": True}, 1, 150, [10, 30, 60, 100])]
        top_up = lambda: g.call("audit_fill", {"reset": True})
    elif kind == "mooks":
        g.call("start_battle", {"p1": "naruto", "p2": fid, "mode": "cpu", "level": 3, "skip_intro": True})
        moves = [("cpu", {}, 1, 300, [10, 40, 80, 120, 160, 200, 240, 280])]
        top_up = lambda: None
    else:
        g.call("start_battle", {"p1": fid, "p2": "naruto", "p1_assist": "kon", "mode": "pvp", "skip_intro": True})
        moves = MOVES
        top_up = lambda: g.call("audit_fill", {"reset": True})
    before = fighter_state(g)
    shots = play_moves(g, moves, top_up)
    after = fighter_state(g)
    sheet(shots, out / ("%s.png" % fid.replace("/", "_")), "%s (%s)" % (fid, kind))
    blank = [label for label, im in shots if im.getbbox() is None]
    return {"id": fid, "kind": kind, "start": before, "end": after, "problems": interesting(g.diagnostics),
            "shots": len(shots), "blank_shots": blank}


def ids(kind):
    if kind == "assists":
        data = json.loads((CONFIG / "assist.json").read_text(encoding="utf-8"))["fighter"]["data"]
        return [e["id"] for e in data if e["urls"].get("file")]
    data = json.loads((CONFIG / "fighter.json").read_text(encoding="utf-8"))["fighter"]["data"]
    mooks = [e["id"] for e in data if e["urls"].get("file", "").startswith("xb/")]
    if kind == "mooks":
        return mooks
    return [e["id"] for e in data if e["urls"].get("file") and e["id"] not in mooks]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("game", nargs="?", help="runtime (default: the engine's newest build, see default_game)")
    p.add_argument("--only", nargs="*")
    p.add_argument("--kind", default="fighters", choices=["fighters", "assists", "mooks"])
    p.add_argument("--out", default=str(ENGINE / "build/bvn-audit/battle"))
    args = p.parse_args()
    args.game = args.game or default_game()
    out = Path(args.out) / args.kind
    out.mkdir(parents=True, exist_ok=True)
    report_path = out / "report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    saves = tempfile.mkdtemp(prefix="bvn-audit-saves-")
    g = Game(args.game, saves)
    try:
        g.step(5)
        for fid in ids(args.kind):
            if args.only and fid not in args.only:
                continue
            try:
                r = run_fighter(g, fid, out, args.kind)
            except Exception as e:  # a crashed game: note it and start another
                r = {"id": fid, "kind": args.kind, "error": str(e)[:500]}
                g.close()
                g = Game(args.game, saves)
                g.step(5)
            report[fid] = r
            print("%-26s %s" % (fid, "ERROR " + r["error"] if "error" in r else
                                "form %s -> %s, problems %d, blank %d" % (r["start"].get("form"), r["end"].get("form"),
                                                                       len(r["problems"]), len(r["blank_shots"]))),
                  flush=True)
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    finally:
        g.close()


if __name__ == "__main__":
    main()
