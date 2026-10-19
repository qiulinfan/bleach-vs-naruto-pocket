#!/usr/bin/env python3
"""Convert 5DPLAY's Bleach vs Naruto character SWFs into Pocket2D assets.

Reads external/TagAssets (git submodule) and writes, all ignored by Git:
  images/bvn/<id>/<sprite>_<n>.png     cropped, de-duplicated frames
  images/bvn/<id>/face_<n>.png         ultimate cut-in faces (bsface*)
  audio/bvn/<id>/<sound>.wav|mp3       timeline and script sounds
  data/bvn/BVNF_<id>.lua   timelines, areas, translated scripts (loaded on demand)

Needs FFDec (JPEXS) and Java: --ffdec defaults to ~/.local/share/ffdec/ffdec-run.
Run with a Python that has Pillow (and NumPy for colour matrix filters), e.g.
  ~/.local/share/bvn-venv/bin/python tools/convert_bvn.py --only ichigo naruto
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import as3lua  # noqa: E402
import swfxml  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LUA_ONLY = False
ASSETS = ROOT / "external" / "TagAssets" / "shared" / "assets" / "assets"
CACHE = ROOT / ".cache" / "convert"
DATA = ROOT / "data" / "bvn"
FFDEC = Path.home() / ".local/share/ffdec/ffdec-run"
# FighterHitRange.ALL_HIT_RANGES: the CPU's attack ranges, children of AImain frame 2.
HIT_RANGES = ["kanmian", "tkanmian", "kj1mian", "kj2mian", "zh1mian", "zh2mian", "zh3mian", "tzmian", "bsmian", "sbsmian",
              "cbsmian", "kbsmian"]
SPECIAL_NAMES = ("AImain", "bdmn")


def ffdec(*args):
    subprocess.run([str(FFDEC), "-config", "autoDeobfuscate=1,simplifyExpressions=1", *args],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def lua_str(s):
    return json.dumps(s, ensure_ascii=False)


def lua_val(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(round(v, 2)) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua_val(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("[%s]=%s" % (lua_val(k), lua_val(x)) for k, x in v.items()) + "}"
    raise TypeError(type(v))


def literal_names(src, fn):
    return set(re.findall(r"\b%s\(\s*\"([^\"]+)\"" % fn, src))


class Converter:
    def __init__(self, swf_path, fid, assist):
        self.swf_path = swf_path
        self.id = fid
        self.assist = assist
        self.work = CACHE / fid
        self.work.mkdir(parents=True, exist_ok=True)
        self.img_dir = ROOT / "images" / "bvn" / fid
        self.snd_dir = ROOT / "audio" / "bvn" / fid

    def log(self, *a):
        print("[%s]" % self.id, *a, flush=True)

    def run(self):
        xml_path = self.work / "swf.xml"
        if not xml_path.exists():
            ffdec("-swf2xml", str(self.swf_path), str(xml_path))
        scripts = self.work / "scripts"
        if not scripts.exists():
            ffdec("-export", "script", str(scripts), str(self.swf_path))
        self.analyze()
        swf, forms, form_ids, detached, render_ids, main_id = (
            self.swf, self.forms, self.form_ids, self.detached, self.render_ids, self.main_id)
        render_root = self.work / "render2"
        meta_path = self.work / "sprites.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else None
        if LUA_ONLY and meta and form_ids <= set(meta["sprites"]):
            self.form_ids = form_ids
            meta["forms"] = [self.form_entry(frame, sid, m) for frame, sid, m in forms]
            for sid, d in meta["sprites"].items():
                if sid in swf.sprites:
                    for f, (dl, _, _) in zip(d["frames"], swf.timeline(sid)):
                        pts = self.child_points(dl)
                        if pts:
                            f.setdefault("hits", {}).update(pts)
                    d["ranges"] = self.ranges_of(sid)
            for sid, d in meta["sprites"].items():
                cls = swf.id_class.get(sid)
                d["script"] = self.translate(cls) if cls else None
            meta["main"] = self.translate(swf.id_class.get(main_id)) if not self.assist else None
            self.write_lua(meta)
            self.log("lua rewritten")
            return
        # What the render left out of which sprites: a render made with other rules is made again.
        key = json.dumps([sorted(render_ids, key=int), sorted(self.dynamic), sorted(self.giant), sorted(self.blended),
                          sorted(self.split), sorted(self.hide_names)])
        key_path = render_root / "RENDER_KEY"
        if meta and not form_ids <= set(meta["sprites"]):
            shutil.rmtree(render_root, ignore_errors=True)
        if render_root.exists() and key_path.exists() and key_path.read_text() != key:
            shutil.rmtree(render_root, ignore_errors=True)
        if not render_root.exists():
            swf2 = self.strip_children(xml_path, form_ids)
            tmp = self.work / "render_tmp"
            shutil.rmtree(tmp, ignore_errors=True)
            ffdec("-selectid", ",".join(render_ids), "-format", "sprite:png", "-export", "sprite", str(tmp), str(swf2))
            (tmp / "STRIP_RULE").write_text("2")
            (tmp / "RENDER_KEY").write_text(key)
            tmp.rename(render_root)
        elif not key_path.exists():
            key_path.write_text(key)  # a render from before the key: made with these rules
        # Renders made before data-only children were stripped keep the old canvas rule.
        self.strip_v = 2 if (render_root / "STRIP_RULE").exists() else 1
        # Images already on disk with the same pixels are kept (a rerun only writes what changed);
        # the others are removed at the end.
        self.img_dir.mkdir(parents=True, exist_ok=True)
        self.written, self.changed = set(), set()
        self.form_ids = form_ids
        out = {"id": self.id, "assist": self.assist, "sprites": {}, "forms": [], "attackers": {}}
        for sid in render_ids:
            out["sprites"][sid] = self.sprite_data(sid, render_root)
        self.write_blend_variants(out["sprites"])
        self.write_cm_variants(out["sprites"])
        for frame, sid, m in forms:
            out["forms"].append(self.form_entry(frame, sid, m))
        for name, cids in detached.items():
            out["attackers"][name] = sorted(cids, key=int)
        out["main"] = self.translate(swf.id_class.get(main_id)) if not self.assist else None
        out["faces"] = self.export_faces()
        out["sounds"] = self.export_sounds()
        for f in self.img_dir.iterdir():
            if f.name not in self.written:  # no frame, variant or face uses it any more
                f.unlink()
        meta = dict(out)
        meta["sprites"] = {sid: {k: v for k, v in d.items() if k != "script"} for sid, d in out["sprites"].items()}
        meta.pop("main", None)
        meta_path.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
        self.write_lua(out)
        self.log("forms", len(forms), "sprites", len(render_ids), "images", len(list(self.img_dir.iterdir())))

    def analyze(self):
        """What the SWF holds and how it is split for rendering: the forms, detached
        (fired) children, animated, giant and blended children and the sprites to render."""
        self.swf = swfxml.Swf(str(self.work / "swf.xml"))
        swf = self.swf
        self.class_src = {}
        scripts = self.work / "scripts"
        for f in scripts.rglob("*.as"):
            rel = f.relative_to(scripts / "scripts").with_suffix("")
            self.class_src[".".join(rel.parts)] = f.read_text(encoding="utf-8", errors="replace")
        main_id = swf.classes.get("main_mc")
        if not main_id:
            raise RuntimeError("no main_mc")
        # Forms: the main timeline's frames that place an action sprite named "mc".
        forms = []
        if not self.assist:
            for i, (dl, label, _) in enumerate(swf.timeline(main_id)):
                for obj in dl.values():
                    if obj.get("name") == "mc" and obj["cid"] in swf.sprites:
                        if not forms or forms[-1][1] != obj["cid"]:
                            forms.append((i + 1, obj["cid"], obj["m"]))
        else:
            forms.append((1, main_id, swfxml.IDENTITY))
        form_ids = {sid for _, sid, _ in forms}
        # Detached children: names passed to fire() / addAttacker() by a form's scripts.
        detached = {}
        for sid in form_ids:
            src = self.class_src.get(swf.id_class.get(sid, ""), "")
            names = literal_names(src, "fire") | literal_names(src, "addAttacker") | literal_names(src, "addFollowEffect")
            for dl, _, _ in swf.timeline(sid):
                for obj in dl.values():
                    if obj.get("name") in names and obj["cid"] in swf.sprites:
                        detached.setdefault(obj["name"], set()).add(obj["cid"])
        # Animated children advance on their own clock (the idle breathing lives in one),
        # so they are rendered separately and placed at run time.
        self.dynamic = set()
        # Giant children (full-screen overlays scaled far beyond the stage) would make
        # FFDec render every frame on a canvas of thousands of pixels; the battle draws
        # its own dimming instead.
        self.giant = set()
        for sid in form_ids:
            for dl, _, _ in swf.timeline(sid):
                for obj in dl.values():
                    nm = obj.get("name") or ""
                    if nm in SPECIAL_NAMES or "atm" in nm:
                        continue
                    r = swfxml.transform_rect(obj["m"], swf.bounds(obj["cid"]))
                    if r and (r[2] - r[0] > 1500 or r[3] - r[1] > 1500):
                        self.giant.add(obj["cid"])
        # Children under a mask stay in their parent's frames, where FFDec applies the mask (a kid
        # would be drawn whole).
        masked = set()
        for sid in form_ids:
            for dl, _, _ in swf.timeline(sid):
                masks = [(d, o["clip"]) for d, o in dl.items() if o.get("clip")]
                for d, obj in dl.items():
                    if any(m < d <= c for m, c in masks):
                        masked.add(obj["cid"])
        self.masked = masked
        for sid in form_ids:
            for dl, _, _ in swf.timeline(sid):
                for obj in dl.values():
                    nm = obj.get("name") or ""
                    if nm in SPECIAL_NAMES or "atm" in nm or nm in detached or obj["cid"] in self.giant or obj["cid"] in masked:
                        continue
                    if obj["cid"] in swf.sprites and swf.frame_count(obj["cid"]) >= 2:
                        self.dynamic.add(obj["cid"])
        self.hide_names = set(detached)
        rendered = form_ids | self.dynamic | {c for cs in detached.values() for c in cs}
        # Children placed with a lighting blend (screen, lighten, add) are effects drawn on black, and
        # subtract / multiply / darken ones darken what is under them: FFDec would flatten either
        # onto the transparent canvas as a black box. They are rendered on their own and drawn
        # with their blend (a "kid" with blend "add", "sub" or "mul"), wherever they are placed.
        self.blended = set()
        placements = {}
        todo = list(rendered)
        while todo:
            sid = todo.pop()
            for dl, _, _ in swf.timeline(sid):
                for obj in dl.values():
                    if obj["cid"] not in swf.sprites:
                        continue
                    kind = swfxml.blend_kind(obj)
                    placements.setdefault(obj["cid"], set()).add(kind)
                    if kind and obj["cid"] not in self.blended and obj["cid"] not in self.giant:
                        self.blended.add(obj["cid"])
                        if obj["cid"] not in rendered:
                            rendered.add(obj["cid"])
                            todo.append(obj["cid"])
        # A plain child that holds a blended one deeper down would be flattened into its parent with
        # it: it is rendered on its own too (a kid without a blend), so the blended one can be a kid
        # of it.
        self.split = set()
        holds = {}

        def holds_blend(cid, depth=0):
            if cid in holds:
                return holds[cid]
            holds[cid] = False
            found = False
            for dl, _, _ in swf.timeline(cid):
                for obj in dl.values():
                    if obj["cid"] not in swf.sprites:
                        continue
                    if swfxml.blend_kind(obj) or (depth < 8 and holds_blend(obj["cid"], depth + 1)):
                        found = True
            holds[cid] = found
            return found
        todo = list(rendered)
        while todo:
            sid = todo.pop()
            for dl, _, _ in swf.timeline(sid):
                for obj in dl.values():
                    cid, nm = obj["cid"], obj.get("name") or ""
                    if cid not in swf.sprites or cid in rendered or swfxml.blend_kind(obj) or cid in self.giant \
                            or nm in SPECIAL_NAMES or "atm" in nm or nm in detached:
                        continue
                    if holds_blend(cid):
                        self.split.add(cid)
                        rendered.add(cid)
                        todo.append(cid)
                        for dl2, _, _ in swf.timeline(cid):
                            for o2 in dl2.values():
                                if o2["cid"] in swf.sprites:
                                    k2 = swfxml.blend_kind(o2)
                                    placements.setdefault(o2["cid"], set()).add(k2)
                                    if k2 and o2["cid"] not in self.giant:
                                        self.blended.add(o2["cid"])
                                        if o2["cid"] not in rendered:
                                            rendered.add(o2["cid"])
                                            todo.append(o2["cid"])
        # Always drawn with one blend, also when spawned on its own (an attacker or bullet).
        self.always_blend = {cid: next(iter(kinds)) for cid, kinds in placements.items()
                             if len(kinds) == 1 and None not in kinds}
        render_ids = sorted(rendered, key=int)

        def too_big(sid):
            r = swf.bounds(sid)
            return sid not in form_ids and r is not None and (r[2] - r[0] > 2500 or r[3] - r[1] > 2500)
        render_ids = [sid for sid in render_ids if not too_big(sid)]
        self.forms, self.form_ids, self.detached, self.render_ids, self.main_id = forms, form_ids, detached, render_ids, main_id

    def save_image(self, im, path):
        """Writes a frame image unless the file already holds the same pixels."""
        self.written.add(path.name)
        if path.exists():
            try:
                old = Image.open(path).convert("RGBA")
                if old.size == im.size and old.tobytes() == im.tobytes():
                    return
            except OSError:
                pass
        self.changed.add(path.name)
        im.save(path, optimize=True)

    def child_points(self, dl):
        """Registration points of named sprite children: bullet / attacker spawn points and checkers."""
        out = {}
        for obj in dl.values():
            nm = obj.get("name")
            if nm and nm not in SPECIAL_NAMES and obj["cid"] in self.swf.sprites:
                m = obj["m"]
                out["@" + nm] = [round(m[4], 1), round(m[5], 1)]
                # Its bounds too, for scripts that hitTest a named child (ulquiorra's sh20).
                r = swfxml.transform_rect(m, self.swf.frame1_bounds(obj["cid"]))
                if r:
                    out["#" + nm] = [round(r[0], 1), round(r[1], 1), round(r[2] - r[0], 1), round(r[3] - r[1], 1)]
        return out

    @staticmethod
    def form_entry(frame, sid, m):
        return {"sprite": sid, "form_frame": frame, "x": round(m[4], 2), "y": round(m[5], 2), "sx": round(m[0], 4), "sy": round(m[3], 4)}

    def strip_children(self, xml_path, sprite_ids):
        """A copy of the SWF whose form timelines lack detached and animated children."""
        out = self.work / "render.swf"
        tree = ET.parse(xml_path)
        tags = tree.getroot().find("tags")
        # Unknown tags (obfuscation junk) cannot be written back.
        for parent in tree.getroot().iter():
            for t in list(parent):
                if t.get("type") == "TagStub":
                    parent.remove(t)
        # Obfuscation junk the Flash player ignores but FFDec renders: a sprite placing
        # itself (frames after it came out blank) and sprite definitions nested in a timeline.
        for t in tags:
            if t.get("type") == "DefineSpriteTag" and t.find("subTags") is not None:
                sub = t.find("subTags")
                for item in list(sub):
                    if item.get("type") == "DefineSpriteTag" or (
                            item.get("type") in swfxml.PLACE_TAGS and item.get("characterId") == t.get("spriteId")):
                        sub.remove(item)
        for t in tags:
            if t.get("type") != "DefineSpriteTag" or t.find("subTags") is None:
                continue
            sub = t.find("subTags")
            blended_depths = set()
            for item in list(sub):
                ty = item.get("type")
                if ty in swfxml.PLACE_TAGS:
                    depth = item.get("depth")
                    if item.get("placeFlagHasCharacter") == "true":
                        lit = item.get("placeFlagHasBlendMode") == "true" and item.get("blendMode") in swfxml.BLEND_KINDS
                        if (lit and item.get("characterId") in self.blended) or item.get("characterId") in self.split:
                            blended_depths.add(depth)
                            sub.remove(item)
                            continue
                        blended_depths.discard(depth)
                    elif depth in blended_depths:
                        sub.remove(item)
                elif ty in ("RemoveObject2Tag", "RemoveObjectTag") and item.get("depth") in blended_depths:
                    blended_depths.discard(item.get("depth"))
                    sub.remove(item)
        for t in tags:
            if t.get("type") == "DefineSpriteTag" and t.get("spriteId") in sprite_ids:
                sub = t.find("subTags")
                hidden_depths = set()
                for item in list(sub):
                    ty = item.get("type")
                    if ty in swfxml.PLACE_TAGS:
                        depth = item.get("depth")
                        if item.get("placeFlagHasCharacter") == "true":
                            nm = item.get("name") or ""
                            # Data-only children (AI ranges, body and hit boxes) are invisible but
                            # would stretch the render canvas.
                            if nm in self.hide_names or nm in SPECIAL_NAMES or "atm" in nm \
                                    or item.get("characterId") in self.dynamic or item.get("characterId") in self.giant:
                                hidden_depths.add(depth)
                                sub.remove(item)
                                continue
                            hidden_depths.discard(depth)
                        elif depth in hidden_depths:
                            sub.remove(item)
                    elif ty in ("RemoveObject2Tag", "RemoveObjectTag") and item.get("depth") in hidden_depths:
                        hidden_depths.discard(item.get("depth"))
                        sub.remove(item)
        xml2 = self.work / "render.xml"
        tree.write(xml2, encoding="utf-8")
        ffdec("-xml2swf", str(xml2), str(out))
        return out

    def sprite_data(self, sid, render_root):
        swf = self.swf
        tl = swf.timeline(sid)
        stripped = sid in self.form_ids

        def hidden(obj):
            nm = obj.get("name") or ""
            data_only = self.strip_v >= 2 and (nm in SPECIAL_NAMES or "atm" in nm)
            if (obj.get("lit") and obj["cid"] in self.blended) or obj["cid"] in getattr(self, "split", ()):
                return True
            return stripped and (nm in self.hide_names or data_only or obj["cid"] in self.dynamic or obj["cid"] in self.giant)

        # Canvas origin: FFDec renders a sprite on its full bounds.
        rect = None
        for dl, _, _ in tl:
            for obj in dl.values():
                if not hidden(obj):
                    rect = swfxml.union(rect, swfxml.transform_rect(obj["m"], swf.bounds(obj["cid"])))
        ox, oy = (-rect[0], -rect[1]) if rect else (0, 0)
        folder = next(render_root.glob("DefineSprite_%s_*" % sid), None) or next(render_root.glob("DefineSprite_%s" % sid), None)
        # FFDec pads the canvas on every side by the filters' reach in the sprite
        # (Timeline.getDisplayRectWithFilters): the frames start that much further in.
        first = folder / "1.png" if folder else None
        if rect and first and first.exists():
            w, h = Image.open(first).size
            pad_x, pad_y = (w - (rect[2] - rect[0])) / 2, (h - (rect[3] - rect[1])) / 2
            ox += round(pad_x * 2) / 2 if pad_x > 0.75 else 0
            oy += round(pad_y * 2) / 2 if pad_y > 0.75 else 0
        frames, labels, seen = [], {}, {}
        hit_ranges = None
        for i, (dl, label, sounds) in enumerate(tl):
            n = i + 1
            if label:
                labels.setdefault(label, n)
            f = {}
            png = folder / ("%d.png" % n) if folder else Path("/nonexistent")
            im = Image.open(png).convert("RGBA") if png.exists() and rect else None
            bb = im.getbbox() if im else None
            if bb:
                crop = im.crop(bb)
                key = hashlib.sha1(crop.tobytes() + bytes(str(crop.size), "ascii")).hexdigest()
                if key not in seen:
                    name = "%s_%d.png" % (sid, len(seen) + 1)
                    self.save_image(crop, self.img_dir / name)
                    seen[key] = name
                f["img"] = "bvn/%s/%s" % (self.id, seen[key])
                f["x"] = round(bb[0] - ox, 2)
                f["y"] = round(bb[1] - oy, 2)
            hits, kids = {}, []
            for depth in sorted(dl):
                obj = dl[depth]
                nm = obj.get("name")
                placed_lit = obj.get("lit") and obj["cid"] in self.blended
                lit = swfxml.blend_kind(obj) if placed_lit else None
                split = obj["cid"] in getattr(self, "split", ())
                if placed_lit or split or (stripped and obj["cid"] in self.dynamic and obj.get("name") not in self.hide_names):
                    a, b, c, d, tx, ty = obj["m"]
                    kid = [obj["cid"], obj["serial"], round(a, 4), round(b, 4), round(c, 4), round(d, 4), round(tx, 2), round(ty, 2)]
                    # The placement's blend, alpha, colour transform (red, green, blue multipliers and
                    # offsets) and colour matrix filter (an image variant, see write_cm_variants).
                    alpha = round(obj.get("alpha", 1.0), 3)
                    ct = [round(v, 3) for v in obj["ct"]] if obj.get("ct") else None
                    cm = self.cm_variant(obj.get("cm"))
                    if ct and lit in ("sub", "mul"):
                        cm, ct = self.blend_variant(lit, ct), None
                    extra = [lit, max(alpha, 0) if alpha < 1 else None, ct, cm]
                    while extra and extra[-1] is None:
                        extra.pop()
                    kids.append(kid + extra)
                    continue
                if not nm:
                    continue
                if nm == "bdmn" or "atm" in nm or nm == "main":
                    r = swfxml.transform_rect(obj["m"], swf.frame1_bounds(obj["cid"]))
                    if r:
                        r = [round(r[0], 1), round(r[1], 1), round(r[2] - r[0], 1), round(r[3] - r[1], 1)]
                        if nm == "bdmn":
                            f["body"] = r
                        elif nm == "main":
                            f["main"] = r
                        else:
                            hits[nm] = r
                elif nm == "AImain" and hit_ranges is None:
                    hit_ranges = self.hit_ranges(obj, 0, 0)

            hits.update(self.child_points(dl))
            if hits:
                f["hits"] = hits
            if kids:
                f["kids"] = kids
            if sounds:
                f["snd"] = ["bvn/%s/%s" % (self.id, s) for s in sounds]
            frames.append(f)
        cls = swf.id_class.get(sid)
        return {"frames": frames, "labels": labels, "ranges": hit_ranges or {}, "script": self.translate(cls) if cls else None,
                "bounds": [round(x, 1) for x in rect] if rect else None,
                "blend": getattr(self, "always_blend", {}).get(sid)}

    def cm_variant(self, cm):
        """The name of a colour matrix's image variant ("cm1", ...), numbered per character."""
        if not cm:
            return None
        table = self.__dict__.setdefault("cms", {})
        if cm not in table:
            table[cm] = "cm%d" % (len(table) + 1)
        return table[cm]

    def write_cm_variants(self, sprites):
        """<image>_cmN.png: the frames of kids placed with a colour matrix filter (and of the kids
        they hold), with the matrix applied (Flash: out = M * (r, g, b, a, 1), offsets in 0..255)."""
        names = {v: k for k, v in getattr(self, "cms", {}).items()}
        if not names:
            return
        import numpy  # only the characters with colour matrices need it
        todo = [(k[0], k[11]) for d in sprites.values() for f in d["frames"] for k in f.get("kids", ()) if len(k) > 11 and k[11] in names]
        done = set()
        while todo:
            sid, var = todo.pop()
            if (sid, var) in done or sid not in sprites:
                continue
            done.add((sid, var))
            m = names[var]
            for f in sprites[sid]["frames"]:
                for k in f.get("kids", ()):
                    todo.append((k[0], var))
                if not f.get("img"):
                    continue
                path = ROOT / "images" / f["img"]
                variant = path.with_name(path.stem + "_" + var + ".png")
                self.written.add(variant.name)
                if variant.exists() and path.name not in self.changed:
                    continue
                px = numpy.asarray(Image.open(path).convert("RGBA"), dtype=numpy.float32)
                mat = numpy.array(m, dtype=numpy.float32).reshape(4, 5)
                res = px @ mat[:, :4].T + mat[:, 4]
                Image.fromarray(numpy.clip(res, 0, 255).astype(numpy.uint8), "RGBA").save(variant, optimize=True)

    def blend_variant(self, mode, ct):
        """A subtracted / multiplied kid's colour transform is baked into its images ("mulct1"):
        the multiply cannot take colour offsets at run time."""
        table = self.__dict__.setdefault("blend_cts", {})
        key = (mode, tuple(ct))
        if key not in table:
            table[key] = "%sct%d" % (mode, len(table) + 1)
        return table[key]

    def write_blend_variants(self, sprites):
        """Images for the engine's multiply blend (under * colour + under * (1 - alpha)), next to
        each frame image of the sprites drawn subtracted or multiplied (with the kids that inherit
        it): <image>_sub.png, the inverted colour premultiplied by alpha (under * (1 - colour *
        alpha) approximates Flash's SUBTRACT), <image>_mul.png, the colour premultiplied, and
        <image>_subctN / _mulctN.png the same after a colour transform."""
        cts = {v: k for k, v in getattr(self, "blend_cts", {}).items()}
        todo = [(sid, d["blend"]) for sid, d in sprites.items() if d.get("blend") in ("sub", "mul")]
        for d in sprites.values():
            for f in d["frames"]:
                for k in f.get("kids", ()):
                    if len(k) > 11 and k[11] in cts:
                        todo.append((k[0], k[11]))
                    elif len(k) > 8 and k[8] in ("sub", "mul"):
                        todo.append((k[0], k[8]))
        done = set()
        while todo:
            sid, var = todo.pop()
            if (sid, var) in done or sid not in sprites:
                continue
            done.add((sid, var))
            mode, ct = cts.get(var, (var, None))
            for f in sprites[sid]["frames"]:
                for k in f.get("kids", ()):
                    if len(k) <= 8 or not k[8]:
                        todo.append((k[0], var))
                if not f.get("img"):
                    continue
                path = ROOT / "images" / f["img"]
                variant = path.with_name(path.stem + "_" + var + ".png")
                self.written.add(variant.name)
                if variant.exists() and path.name not in self.changed:
                    continue
                im = Image.open(path).convert("RGBA")
                r, g, b, a = im.split()
                if ct:
                    r, g, b = (ch.point(lambda v, m=m, o=o: max(0, min(255, int(v * m + o))))
                               for ch, m, o in zip((r, g, b), ct[:3], ct[3:]))
                if mode == "sub":
                    r, g, b = (ch.point(lambda v: 255 - v) for ch in (r, g, b))
                rgb = Image.merge("RGB", (r, g, b))
                black = Image.new("RGB", im.size, (0, 0, 0))
                premultiplied = Image.composite(rgb, black, a)
                premultiplied.putalpha(a)
                premultiplied.save(variant, optimize=True)

    def ranges_of(self, sid):
        for dl, _, _ in self.swf.timeline(sid):
            for obj in dl.values():
                if obj.get("name") == "AImain":
                    return self.hit_ranges(obj, 0, 0)
        return {}

    def hit_ranges(self, obj, tx, ty):
        swf = self.swf
        tl = swf.timeline(obj["cid"]) if obj["cid"] in swf.sprites else []
        if len(tl) < 2:
            return {}
        out = {}
        for child in tl[1][0].values():
            if child.get("name") in HIT_RANGES:
                m = swfxml.mul(obj["m"], child["m"])
                r = swfxml.transform_rect(m, swf.frame1_bounds(child["cid"]))
                if r:
                    out[child["name"]] = [round(r[0] + tx, 1), round(r[1] + ty, 1), round(r[2] - r[0], 1), round(r[3] - r[1], 1)]
        return out

    def translate(self, cls):
        src = self.class_src.get(cls)
        if not src:
            return None
        try:
            lua, failures = as3lua.translate_class(src)
        except as3lua.Unsupported as e:
            self.log("script", cls, "not translated:", e)
            return None
        for f in failures:
            self.log("script", f)
        return lua

    def export_faces(self):
        faces = {}
        ids = {cid: name for name, cid in self.swf.classes.items() if re.match(r"^bsface\d+$", name)}
        if not ids:
            return faces
        tmp = self.work / "faces"
        if not tmp.exists():
            ffdec("-selectid", ",".join(ids), "-format", "image:png", "-export", "image", str(tmp), str(self.swf_path))
        for f in tmp.rglob("*.png"):
            cid = f.stem.split("_")[0]
            if cid in ids:
                name = "face_%s.png" % ids[cid][6:]
                shutil.copy(f, self.img_dir / name)
                self.written.add(name)
                faces[ids[cid]] = "bvn/%s/%s" % (self.id, name)
        return faces

    def export_sounds(self):
        tmp = self.work / "sounds"
        if not tmp.exists():
            ffdec("-format", "sound:mp3_wav", "-export", "sound", str(tmp), str(self.swf_path))
        shutil.rmtree(self.snd_dir, ignore_errors=True)
        self.snd_dir.mkdir(parents=True)
        names = {}
        for f in tmp.rglob("*"):
            if f.suffix.lower() not in (".mp3", ".wav"):
                continue
            sid = f.stem.split("_")[0]
            cls = self.swf.id_class.get(sid)
            shutil.copy(f, self.snd_dir / (sid + f.suffix.lower()))
            if cls:
                names[cls] = "bvn/%s/%s" % (self.id, sid)
        return names

    def write_lua(self, out):
        gen = DATA
        gen.mkdir(parents=True, exist_ok=True)
        var = "BVNF_" + re.sub(r"\W", "_", self.id)
        lines = ["-- Generated by tools/convert_bvn.py from 5DPLAY's %s.swf. Do not edit." % self.id,
                 "-- Loaded on demand by BVNRuntime.Character.",
                 "local C = {id = %s, assist = %s, faces = %s, sounds = %s, sprites = {}}" % (
                     lua_str(self.id), lua_val(self.assist), lua_val(out["faces"]), lua_val(out["sounds"])),
                 "local S = C.sprites"]
        for sid, d in out["sprites"].items():
            fr = ",\n".join("{" + ",".join("%s=%s" % (k, lua_val(v)) for k, v in f.items()) + "}" for f in d["frames"])
            lines.append("S[%s] = {id=%s, labels=%s, ranges=%s, bounds=%s, blend=%s,\nframes={\n%s},\nscript=%s}" % (
                lua_str(sid), lua_str(sid), lua_val(d["labels"]), lua_val(d["ranges"]), lua_val(d["bounds"]),
                lua_val(d.get("blend")), fr, d["script"] or "nil"))
        lines.append("C.forms = %s" % lua_val(out["forms"]))
        lines.append("C.attackers = %s" % lua_val(out["attackers"]))
        lines.append("C.main = %s" % (out["main"] or "nil"))
        lines.append("return C")
        text = re.sub(r"\bBVN_(\w+)\(", r"BVNRuntime.\1(", "\n".join(lines) + "\n")
        # new <a sound class of this SWF>(): the converted sound (new dashSnd().play()).
        sounds = out.get("sounds") or {}
        text = re.sub(r'BVNRuntime\.NEW\("([\w.$]+)"\)', lambda m: 'BVNRuntime.SOUND(C.sounds[%s])' % lua_str(m.group(1))
                      if m.group(1) in sounds else m.group(0), text)
        (gen / (var + ".lua")).write_text(text, encoding="utf-8")


def roster():
    out = []
    for f in sorted((ASSETS / "fighter").glob("*.swf")):
        out.append((f.stem, f, False))
    for f in sorted((ASSETS / "fighter" / "fz").glob("*.swf")):
        out.append(("fz_" + f.stem, f, True))
    # Musou mooks (fighter.json urls.file "xb/<name>.swf" -> data/bvn/BVNF_xb_<name>.lua).
    for f in sorted((ASSETS / "fighter" / "xb").glob("*.swf")):
        out.append(("xb/" + f.stem, f, False))
    return out


def convert_one(item):
    global LUA_ONLY
    LUA_ONLY = os.environ.get("BVN_LUA_ONLY") == "1"
    fid, path, assist = item
    try:
        Converter(path, fid, assist).run()
        return fid, None
    except Exception as e:  # report and continue with the others
        return fid, "%s: %s" % (type(e).__name__, e)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--only", nargs="*", help="ids such as ichigo naruto fz_kon")
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--clean", action="store_true", help="discard cached FFDec output first")
    p.add_argument("--missing", action="store_true", help="only characters without generated Lua")
    p.add_argument("--lua-only", action="store_true", help="re-translate scripts using cached frame data")
    args = p.parse_args()
    global LUA_ONLY
    LUA_ONLY = args.lua_only
    os.environ["BVN_LUA_ONLY"] = "1" if args.lua_only else ""
    items = [r for r in roster() if not args.only or r[0] in args.only]
    if args.only:
        items.sort(key=lambda r: args.only.index(r[0]))
    if args.missing:
        items = [r for r in items if not (DATA / ("BVNF_" + re.sub(r"\W", "_", r[0]) + ".lua")).exists()
                 and not (ROOT / "component_types" / "generated" / ("BVNF_" + re.sub(r"\W", "_", r[0]) + ".lua")).exists()]
    if args.clean:
        for fid, _, _ in items:
            shutil.rmtree(CACHE / fid, ignore_errors=True)
    failed = []
    with concurrent.futures.ProcessPoolExecutor(args.jobs) as ex:
        for fid, err in ex.map(convert_one, items):
            if err:
                failed.append((fid, err))
                print("[%s] FAILED %s" % (fid, err), flush=True)
    print("converted %d, failed %d" % (len(items) - len(failed), len(failed)))


if __name__ == "__main__":
    main()
