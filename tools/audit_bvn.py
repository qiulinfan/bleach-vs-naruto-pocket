#!/usr/bin/env python3
"""Checks the converted characters against their SWFs (after tools/convert_bvn.py).

For every fighter, assist and musou mook of the original config:
  blank      rendered frames that came out empty although the SWF timeline
             shows something on them (shapes, bitmaps, text) that the
             converter did not move into a child of its own (kids)
  missing    frames whose image is not on disk
  nested     add / subtract / multiply blended placements inside a child that
             is flattened into its parent's frames: lost (stripped) or drawn on
             black (a black box)
  kids       placements of children drawn on their own (animated, blended)
             with an alpha below 1 (drawn translucent since kids carry alpha)
  forms      each select entry's start_frame (main_mc frame start_frame + 1)
             and the main_mc frames the form scripts jump to exist as forms
  canvas     sprites whose computed bounds are larger than the canvas FFDec rendered
             them on (their frames would be drawn shifted; a larger canvas is FFDec's
             filter padding, which the converter accounts for)
  dark       flattened frames mostly made of opaque near-black pixels (to look at)
  scripts    frame scripts the generated Lua defines but never registers on a
             frame (they would never run)

Writes JSON (--json) and prints a summary per character.
Usage: tools/audit_bvn.py [--only ids...] [--json out.json]
"""
import argparse
import json
import re
import sys
import zlib
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import convert_bvn as cb  # noqa: E402
import swfxml  # noqa: E402

CONFIG = cb.ROOT / "external" / "BleachVsNaruto" / "shared" / "assets" / "assets" / "config"


def entries():
    """(converted id, [select entries]) for every converted roster member."""
    fighters = json.loads((CONFIG / "fighter.json").read_text(encoding="utf-8"))["fighter"]["data"]
    by_file = {}
    for e in fighters:
        f = e["urls"].get("file")
        if not f:
            continue  # the random cells
        fid = ("xb/" + Path(f).stem) if f.startswith("xb/") else Path(f).stem
        by_file.setdefault(fid, []).append(e)
    out = []
    for fid, path, assist in cb.roster():
        out.append((fid, path, assist, by_file.get(fid, [])))
    return out


class Audit:
    def __init__(self, fid, path, assist, select):
        self.fid, self.select = fid, select
        self.conv = cb.Converter(path, fid, assist)
        self.conv.analyze()
        self.swf = self.conv.swf
        self.meta = json.loads((self.conv.work / "sprites.json").read_text(encoding="utf-8"))
        self.render_root = self.conv.work / "render2"
        self.strip_v = 2 if (self.render_root / "STRIP_RULE").exists() else 1
        self._visible = {}
        self.shape_tags = {t.get("shapeId"): t for t in self.swf.tags if t.get("type") in swfxml.SHAPE_TAGS}

    def bitmap_ok(self, bid):
        """Whether a bitmap decodes (obfuscated SWFs carry truncated junk bitmaps Flash cannot show)."""
        t = self.swf.bitmaps.get(bid)
        if t is None:
            return False
        data = t.get("zlibBitmapData")
        if data is None:
            return True  # JPEG kinds: trust them
        try:
            raw = zlib.decompress(bytes.fromhex(data))
        except (zlib.error, ValueError):
            return False
        if t.get("type") != "DefineBitsLossless2Tag":
            return True
        # Lossless2 has alpha: a bitmap of fully transparent pixels shows nothing.
        if t.get("bitmapFormat") == "3":
            n = int(t.get("bitmapColorTableSize", "0")) + 1
            alphas = {i for i in range(n) if raw[i * 4 + 3] > 0}
            return any(b in alphas for b in raw[n * 4:])
        return any(raw[i] > 0 for i in range(0, len(raw), 4))

    def shape_visible(self, cid):
        tag = self.shape_tags.get(cid)
        if tag is None:
            return True
        for st in tag.iter("item"):
            ty = st.get("type")
            if ty == "FILLSTYLE":
                kind = int(st.get("fillStyleType", "0"))
                if kind == 0:
                    c = st.find("color")
                    if c is None or int(c.get("alpha", "255")) > 0:
                        return True
                elif kind in (0x10, 0x12, 0x13):
                    if any(int(c.get("alpha", "255")) > 0 for c in st.iter("color")):
                        return True
                elif kind >= 0x40:
                    if st.get("bitmapId") != "65535" and self.bitmap_ok(st.get("bitmapId")):
                        return True
            elif ty and ty.startswith("LINESTYLE") and ty != "LINESTYLEARRAY":
                c = st.find("color")
                if int(st.get("width", "0")) > 0 and (c is None or int(c.get("alpha", "255")) > 0):
                    return True
        return False

    def visible(self, cid, depth=0):
        """Whether a character draws anything (some frame of a sprite)."""
        if cid in self._visible:
            return self._visible[cid]
        swf = self.swf
        v = False
        if cid in swf.shapes:
            r = swf.bounds(cid)
            v = r is not None and r[2] - r[0] > 0.5 and r[3] - r[1] > 0.5 and self.shape_visible(cid)
        elif cid in swf.other_bounds:
            r = swf.bounds(cid)
            v = r is not None and r[2] - r[0] > 0.5 and r[3] - r[1] > 0.5
        elif cid in swf.sprites and depth < 12:
            self._visible[cid] = False
            v = any(o.get("alpha", 1) > 0 and not o.get("clip") and self.visible(o["cid"], depth + 1)
                    for dl, _, _ in swf.timeline(cid) for o in dl.values())
        self._visible[cid] = v
        return v

    def hidden(self, sid, obj):
        """sprite_data's rule: children the render leaves out of a sprite's frames."""
        c = self.conv
        nm = obj.get("name") or ""
        data_only = self.strip_v >= 2 and (nm in cb.SPECIAL_NAMES or "atm" in nm)
        if (obj.get("lit") and obj["cid"] in c.blended) or obj["cid"] in c.split:
            return True
        stripped = sid in c.form_ids
        hide = stripped and (nm in c.hide_names or data_only or obj["cid"] in c.dynamic or obj["cid"] in c.giant)
        # The render also leaves out the named data children of every sprite (strip_children
        # removes them only from the forms, but they are invisible boxes everywhere).
        return hide or nm in cb.SPECIAL_NAMES or "atm" in nm

    def blank_frames(self):
        out = {}
        for sid, d in self.meta["sprites"].items():
            if sid not in self.swf.sprites:
                continue
            tl = self.swf.timeline(sid)
            bad = []
            for n, (f, (dl, _, _)) in enumerate(zip(d["frames"], tl), 1):
                if f.get("img"):
                    continue
                # Masks draw nothing themselves, and an empty mask hides what it covers.
                empty_masks = [(d, o["clip"]) for d, o in dl.items() if o.get("clip") and not self.visible(o["cid"])]
                shown = [o for d, o in dl.items() if not self.hidden(sid, o) and o.get("alpha", 1) > 0.01
                         and not o.get("clip") and not any(m < d <= c for m, c in empty_masks) and self.visible(o["cid"])]
                if shown:
                    bad.append(n)
            if bad:
                out[sid] = bad
        return out

    def canvas_mismatch(self):
        """Sprites whose frame offsets assume another canvas than the one FFDec rendered on
        (the converter places each image from the sprite's bounds): drawn shifted."""
        out = {}
        for sid, d in self.meta["sprites"].items():
            b = d.get("bounds")
            folder = next(self.render_root.glob("DefineSprite_%s_*" % sid), None) or next(self.render_root.glob("DefineSprite_%s" % sid), None)
            png = folder / "1.png" if folder else None
            if not b or not png or not png.exists():
                continue
            w, h = Image.open(png).size
            # A larger canvas is FFDec's filter padding, which the converter takes off.
            if (b[2] - b[0]) - w > 2.5 or (b[3] - b[1]) - h > 2.5:
                out[sid] = [round(b[2] - b[0], 1), round(b[3] - b[1], 1), w, h]
        return out

    def missing_images(self):
        root = cb.ROOT / "images"
        return sorted({f["img"] for d in self.meta["sprites"].values() for f in d["frames"]
                       if f.get("img") and not (root / f["img"]).exists()})

    def nested_additive(self):
        """Blended placements below a flattened child of a rendered sprite."""
        rendered = set(self.meta["sprites"])
        found = {}

        def walk(cid, path, depth):
            if depth > 10 or cid not in self.swf.sprites:
                return
            for dl, _, _ in self.swf.timeline(cid):
                for o in dl.values():
                    if o["cid"] not in self.swf.sprites:
                        continue
                    if swfxml.blend_kind(o) and depth > 0:
                        fate = "stripped" if o["cid"] in self.conv.blended else "flattened"
                        found.setdefault(o["cid"], (path + [o["cid"]], fate))
                    elif o["cid"] not in rendered and not swfxml.blend_kind(o):
                        walk(o["cid"], path + [o["cid"]], depth + 1)

        for sid in rendered:
            walk(sid, [sid], 0)
        return {cid: {"path": p, "fate": fate} for cid, (p, fate) in found.items()}

    def kid_alpha(self):
        n = 0
        for sid in self.meta["sprites"]:
            if sid not in self.swf.sprites:
                continue
            for dl, _, _ in self.swf.timeline(sid):
                for o in dl.values():
                    lit = swfxml.blend_kind(o) and o["cid"] in self.conv.blended
                    if (lit or o["cid"] in self.conv.dynamic) and o.get("alpha", 1) < 0.99:
                        n += 1
        return n

    def forms(self):
        frames = [f["form_frame"] for f in self.meta["forms"]]
        problems = []
        for e in self.select:
            want = int(e.get("start_frame") or 1) + 1
            if self.meta.get("assist"):
                continue
            if want not in frames:
                problems.append("%s (%s): start_frame %s -> main frame %d, forms at %s" % (
                    e["id"], e["name"], e.get("start_frame"), want, frames))
        # Jumps the form scripts make on main_mc.
        jumps = set()
        for sid in self.conv.form_ids:
            src = self.conv.class_src.get(self.swf.id_class.get(sid, ""), "")
            jumps |= {int(x) for x in re.findall(r"parent\.gotoAnd(?:Stop|Play)\((\d+)\)", src)}
            jumps |= {int(x) for x in re.findall(r"doWanKai\((\d+)\)", src)}
        for j in sorted(jumps):
            if j not in frames:
                problems.append("a form script jumps to main frame %d, forms at %s" % (j, frames))
        return frames, sorted(jumps), problems

    def dark_images(self):
        """Flattened frames whose content is mostly opaque near-black: black boxes to look at."""
        out = []
        seen = set()
        for sid, d in self.meta["sprites"].items():
            if d.get("blend") == "add":
                continue
            for f in d["frames"]:
                img = f.get("img")
                if not img or img in seen:
                    continue
                seen.add(img)
                im = Image.open(cb.ROOT / "images" / img).convert("RGBA")
                w, h = im.size
                if w * h < 40 * 40:
                    continue
                small = im.resize((max(1, w // 4), max(1, h // 4)))
                px = list(small.get_flattened_data()) if hasattr(small, "get_flattened_data") else list(small.getdata())
                opaque = [p for p in px if p[3] > 200]
                dark = [p for p in opaque if max(p[:3]) < 24]
                if len(px) and len(dark) > 0.35 * len(px) and len(dark) > 0.6 * max(1, len(opaque)):
                    out.append(img)
        return out

    def unregistered_scripts(self):
        lua = cb.DATA / ("BVNF_" + re.sub(r"\W", "_", self.fid) + ".lua")
        if not lua.exists():
            return []
        src = lua.read_text(encoding="utf-8")
        defined = set(re.findall(r"^\s+(frame\d+) = function", src, re.M))
        return sorted(defined - set(re.findall(r'\] = "(frame\d+)"', src)))

    def run(self):
        frames, jumps, form_problems = self.forms()
        blank = self.blank_frames()
        return {
            "id": self.fid,
            "select": [e["id"] for e in self.select],
            "forms": frames,
            "form_jumps": jumps,
            "form_problems": form_problems,
            "sprites": len(self.meta["sprites"]),
            "frames": sum(len(d["frames"]) for d in self.meta["sprites"].values()),
            "blank": blank,
            "blank_count": sum(len(v) for v in blank.values()),
            "missing": self.missing_images(),
            "canvas": self.canvas_mismatch(),
            "nested_additive": self.nested_additive(),
            "kid_alpha": self.kid_alpha(),
            "dark": self.dark_images(),
            "scripts": self.unregistered_scripts(),
        }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--only", nargs="*")
    p.add_argument("--json")
    args = p.parse_args()
    results = []
    for fid, path, assist, select in entries():
        if args.only and fid not in args.only:
            continue
        if not (cb.CACHE / fid / "sprites.json").exists():
            results.append({"id": fid, "error": "not converted"})
            print("%-22s not converted" % fid)
            continue
        try:
            r = Audit(fid, path, assist, select).run()
        except Exception as e:  # report and go on
            results.append({"id": fid, "error": "%s: %s" % (type(e).__name__, e)})
            print("%-22s ERROR %s" % (fid, e))
            continue
        results.append(r)
        flags = []
        if r["blank_count"]:
            flags.append("blank %d" % r["blank_count"])
        if r["missing"]:
            flags.append("missing %d" % len(r["missing"]))
        if r["nested_additive"]:
            flags.append("nested-additive %d" % len(r["nested_additive"]))
        if r["kid_alpha"]:
            flags.append("translucent kids %d" % r["kid_alpha"])
        if r["form_problems"]:
            flags.append("forms: " + "; ".join(r["form_problems"]))
        if r["canvas"]:
            flags.append("canvas %d: %s" % (len(r["canvas"]), " ".join("%s%s" % (k, v) for k, v in list(r["canvas"].items())[:3])))
        if r["dark"]:
            flags.append("dark %d" % len(r["dark"]))
        if r["scripts"]:
            flags.append("unregistered scripts %s" % " ".join(r["scripts"][:4]))
        print("%-22s forms %-14s %s" % (fid, r["forms"], ", ".join(flags) or "ok"))
    if args.json:
        Path(args.json).write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
