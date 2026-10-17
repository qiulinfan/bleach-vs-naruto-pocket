#!/usr/bin/env python3
"""Convert 5DPLAY's Bleach vs Naruto character SWFs into Pocket2D assets.

Reads external/TagAssets (git submodule) and writes, all ignored by Git:
  images/bvn/<id>/<sprite>_<n>.png     cropped, de-duplicated frames
  images/bvn/<id>/face_<n>.png         ultimate cut-in faces (bsface*)
  audio/bvn/<id>/<sound>.wav|mp3       timeline and script sounds
  component_types/generated/BVNF_<id>.lua   timelines, areas, translated scripts

Needs FFDec (JPEXS) and Java: --ffdec defaults to ~/.local/share/ffdec/ffdec-run.
Run with a Python that has Pillow, e.g.
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
FFDEC = Path.home() / ".local/share/ffdec/ffdec-run"
HIT_RANGES = ["zh_range", "sh_range", "kj_range", "kj2_range", "zh2_range", "sk_range", "sk2_range", "bs_range", "sbs_range",
              "cbs_range", "zh3_range", "kjup_range", "kjdown_range"]
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
        self.swf = swfxml.Swf(str(xml_path))
        swf = self.swf
        self.class_src = {}
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
        for sid in form_ids:
            for dl, _, _ in swf.timeline(sid):
                for obj in dl.values():
                    nm = obj.get("name") or ""
                    if nm in SPECIAL_NAMES or "atm" in nm or nm in detached:
                        continue
                    if obj["cid"] in swf.sprites and swf.frame_count(obj["cid"]) >= 2:
                        self.dynamic.add(obj["cid"])
        self.hide_names = set(detached)
        render_ids = sorted(form_ids | self.dynamic | {c for cs in detached.values() for c in cs}, key=int)
        render_root = self.work / "render2"
        meta_path = self.work / "sprites.json"
        if LUA_ONLY and meta_path.exists():
            self.form_ids = form_ids
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            for sid, d in meta["sprites"].items():
                cls = swf.id_class.get(sid)
                d["script"] = self.translate(cls) if cls else None
            meta["main"] = self.translate(swf.id_class.get(main_id)) if not self.assist else None
            self.write_lua(meta)
            self.log("lua rewritten")
            return
        if not render_root.exists():
            swf2 = self.strip_children(xml_path, form_ids)
            tmp = self.work / "render_tmp"
            shutil.rmtree(tmp, ignore_errors=True)
            ffdec("-selectid", ",".join(render_ids), "-format", "sprite:png", "-export", "sprite", str(tmp), str(swf2))
            tmp.rename(render_root)
        shutil.rmtree(self.img_dir, ignore_errors=True)
        self.img_dir.mkdir(parents=True)
        self.form_ids = form_ids
        out = {"id": self.id, "assist": self.assist, "sprites": {}, "forms": [], "attackers": {}}
        for sid in render_ids:
            out["sprites"][sid] = self.sprite_data(sid, render_root)
        for frame, sid, m in forms:
            out["forms"].append({"sprite": sid, "form_frame": frame, "x": round(m[4], 2), "y": round(m[5], 2)})
        for name, cids in detached.items():
            out["attackers"][name] = sorted(cids, key=int)
        out["main"] = self.translate(swf.id_class.get(main_id)) if not self.assist else None
        out["faces"] = self.export_faces()
        out["sounds"] = self.export_sounds()
        meta = dict(out)
        meta["sprites"] = {sid: {k: v for k, v in d.items() if k != "script"} for sid, d in out["sprites"].items()}
        meta.pop("main", None)
        meta_path.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
        self.write_lua(out)
        self.log("forms", len(forms), "sprites", len(render_ids), "images", len(list(self.img_dir.iterdir())))

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
        for t in tags:
            if t.get("type") == "DefineSpriteTag" and t.get("spriteId") in sprite_ids:
                sub = t.find("subTags")
                hidden_depths = set()
                for item in list(sub):
                    ty = item.get("type")
                    if ty in swfxml.PLACE_TAGS:
                        depth = item.get("depth")
                        if item.get("placeFlagHasCharacter") == "true":
                            if item.get("name") in self.hide_names or item.get("characterId") in self.dynamic:
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
            return stripped and (obj.get("name") in self.hide_names or obj["cid"] in self.dynamic)

        # Canvas origin: FFDec renders a sprite on its full bounds.
        rect = None
        for dl, _, _ in tl:
            for obj in dl.values():
                if not hidden(obj):
                    rect = swfxml.union(rect, swfxml.transform_rect(obj["m"], swf.bounds(obj["cid"])))
        ox, oy = (-rect[0], -rect[1]) if rect else (0, 0)
        folder = next(render_root.glob("DefineSprite_%s_*" % sid), None) or next(render_root.glob("DefineSprite_%s" % sid))
        frames, labels, seen = [], {}, {}
        hit_ranges = None
        for i, (dl, label, sounds) in enumerate(tl):
            n = i + 1
            if label:
                labels.setdefault(label, n)
            f = {}
            png = folder / ("%d.png" % n)
            im = Image.open(png).convert("RGBA") if png.exists() and rect else None
            bb = im.getbbox() if im else None
            if bb:
                crop = im.crop(bb)
                key = hashlib.sha1(crop.tobytes() + bytes(str(crop.size), "ascii")).hexdigest()
                if key not in seen:
                    name = "%s_%d.png" % (sid, len(seen) + 1)
                    crop.save(self.img_dir / name, optimize=True)
                    seen[key] = name
                f["img"] = "bvn/%s/%s" % (self.id, seen[key])
                f["x"] = round(bb[0] - ox, 2)
                f["y"] = round(bb[1] - oy, 2)
            hits, kids = {}, []
            for depth in sorted(dl):
                obj = dl[depth]
                nm = obj.get("name")
                if stripped and obj["cid"] in self.dynamic and obj.get("name") not in self.hide_names:
                    a, b, c, d, tx, ty = obj["m"]
                    kids.append([obj["cid"], obj["serial"], round(a, 4), round(b, 4), round(c, 4), round(d, 4), round(tx, 2), round(ty, 2)])
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
                elif obj["cid"] in swf.sprites:
                    # Named children: bullet spawn points and setHitTarget checkers.
                    m = obj["m"]
                    hits.setdefault("@" + nm, [round(m[4], 1), round(m[5], 1)])
            if hits:
                f["hits"] = hits
            if kids:
                f["kids"] = kids
            if sounds:
                f["snd"] = ["bvn/%s/%s" % (self.id, s) for s in sounds]
            frames.append(f)
        cls = swf.id_class.get(sid)
        return {"frames": frames, "labels": labels, "ranges": hit_ranges or {}, "script": self.translate(cls) if cls else None,
                "bounds": [round(x, 1) for x in rect] if rect else None}

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
        gen = ROOT / "component_types" / "generated"
        gen.mkdir(parents=True, exist_ok=True)
        var = "BVNF_" + re.sub(r"\W", "_", self.id)
        lines = ["-- Generated by tools/convert_bvn.py from 5DPLAY's %s.swf. Do not edit." % self.id,
                 "%s = {id = %s, assist = %s, faces = %s, sounds = %s, sprites = {}}" % (
                     var, lua_str(self.id), lua_val(self.assist), lua_val(out["faces"]), lua_val(out["sounds"])),
                 "local S = %s.sprites" % var]
        for sid, d in out["sprites"].items():
            fr = ",\n".join("{" + ",".join("%s=%s" % (k, lua_val(v)) for k, v in f.items()) + "}" for f in d["frames"])
            lines.append("S[%s] = {id=%s, labels=%s, ranges=%s, bounds=%s,\nframes={\n%s},\nscript=%s}" % (
                lua_str(sid), lua_str(sid), lua_val(d["labels"]), lua_val(d["ranges"]), lua_val(d["bounds"]), fr, d["script"] or "nil"))
        lines.append("%s.forms = %s" % (var, lua_val(out["forms"])))
        lines.append("%s.attackers = %s" % (var, lua_val(out["attackers"])))
        lines.append("%s.main = %s" % (var, out["main"] or "nil"))
        text = re.sub(r"\bBVN_(\w+)\(", r"BVNRuntime.\1(", "\n".join(lines) + "\n")
        (gen / (var + ".lua")).write_text(text, encoding="utf-8")


def roster():
    out = []
    for f in sorted((ASSETS / "fighter").glob("*.swf")):
        out.append((f.stem, f, False))
    for f in sorted((ASSETS / "fighter" / "fz").glob("*.swf")):
        out.append(("fz_" + f.stem, f, True))
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
        gen = ROOT / "component_types" / "generated"
        items = [r for r in items if not (gen / ("BVNF_" + re.sub(r"\W", "_", r[0]) + ".lua")).exists()]
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
