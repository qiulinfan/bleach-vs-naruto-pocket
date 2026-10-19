#!/usr/bin/env python3
"""Turns tools/audit_bvn.py's JSON and tools/battle_audit.py's report into the
per-character table of docs/character-audit.md (printed; the hand-written parts
of that document stay as they are).

Usage: tools/audit_report.py STATIC.json BATTLE_DIR [NOTES.json]
NOTES.json maps an id to the note of the visual review.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "external" / "BleachVsNaruto" / "shared" / "assets" / "assets" / "config"


def main():
    static = {x["id"]: x for x in json.load(open(sys.argv[1], encoding="utf-8"))}
    battle = {}
    for kind in ("fighters", "assists", "mooks"):
        p = Path(sys.argv[2]) / kind / "report.json"
        if p.exists():
            for k, v in json.load(open(p, encoding="utf-8")).items():
                battle[(kind, k)] = v
    notes = json.load(open(sys.argv[3], encoding="utf-8")) if len(sys.argv) > 3 else {}
    fighters = json.loads((CONFIG / "fighter.json").read_text(encoding="utf-8"))["fighter"]["data"]
    assists = json.loads((CONFIG / "assist.json").read_text(encoding="utf-8"))["fighter"]["data"]

    def static_cells(cid):
        s = static.get(cid, {})
        if "error" in s or not s:
            return ["(%s)" % s.get("error", "no data")] * 3
        blank = s.get("blank_count", 0)
        nested = len(s.get("nested_additive", {}))
        forms = "/".join(str(x) for x in s.get("forms", []))
        return [forms, str(blank) if blank else "0", str(nested) if nested else "0"]

    def battle_cells(kind, eid):
        b = battle.get((kind, eid))
        if not b:
            return ["not run", ""]
        if "error" in b:
            return ["crashed", b["error"][:80]]
        start = b.get("start", {})
        problems = b.get("problems", [])
        # The fighter's main_mc frame at the start and after the moves (the forms it went through).
        shown = "%s→%s" % (start.get("form", "?"), b.get("end", {}).get("form", "?")) if kind == "fighters" else \
            "%d shots" % b.get("shots", 0)
        return [shown,
                "; ".join(p[:90] for p in problems[:2]) + (" (+%d)" % (len(problems) - 2) if len(problems) > 2 else "")]

    print("### Fighters\n")
    print("| id | name | SWF | forms (main frames) | blank | nested blends | battle form start→end | errors | visual review |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for e in fighters:
        f = e["urls"].get("file")
        if not f or f.startswith("xb/"):
            continue
        cid = Path(f).stem
        cells = [e["id"], e["name"], "%s @%d" % (cid, int(e.get("start_frame") or 1) + 1)] + static_cells(cid) + \
            battle_cells("fighters", e["id"]) + [notes.get(e["id"], "")]
        print("| " + " | ".join(cells) + " |")
    print("\n### Assists\n")
    print("| id | name | SWF | forms | blank | nested blends | battle | errors | visual review |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for e in assists:
        f = e["urls"].get("file")
        if not f:
            continue
        cid = "fz_" + Path(f).stem
        print("| %s | %s | %s | %s | %s | %s |" % (e["id"], e["name"], cid, " | ".join(static_cells(cid)),
                                                  " | ".join(battle_cells("assists", e["id"])), notes.get("fz:" + e["id"], "")))
    print("\n### Musou mooks\n")
    print("| id | name | SWF | forms | blank | nested blends | battle | errors | visual review |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for e in fighters:
        f = e["urls"].get("file", "")
        if not f.startswith("xb/"):
            continue
        cid = "xb/" + Path(f).stem
        print("| %s | %s | %s | %s | %s | %s |" % (e["id"], e["name"], cid, " | ".join(static_cells(cid)),
                                                  " | ".join(battle_cells("mooks", e["id"])), notes.get(e["id"], "")))


if __name__ == "__main__":
    main()
