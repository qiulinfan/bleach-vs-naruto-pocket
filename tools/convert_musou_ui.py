#!/usr/bin/env python3
"""Export the MUSOU (无双) mode's data and interface art.

- component_types/generated/BVNMusouConfig.lua: the world map and its areas'
  missions (config/musou/map1/*.json), the big map's layout (area points,
  revealed map pieces, clouds) and circle / rectangle masked fighter faces.
- data/bvn/ui/musou_*.lua: interface movies (the musou HUD, the start / boss /
  KO animation, the team and fighter dialogs, the map point) in BVNScreen's
  movie format, exported with tools/convert_ui.py's Screens walker. Bitmaps go
  to images/bvn/ui/musou/<doc>/, frame sounds to audio/bvn/ui/musou_<doc>/.

Masks are not composited by the movie walker, so the masked pieces are
pre-rendered here: the big map shows the bright map through soft circles
(mask_mc) over the dark one, and the faces in the HUD and the team dialog are
cut by their mask layers.

Run with a Python that has Pillow:
    ~/.local/share/bvn-venv/bin/python tools/convert_musou_ui.py
"""
import json
import math
import shutil
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import convert_ui as cu  # noqa: E402
from convert_bvn import ROOT, lua_val  # noqa: E402
from xfl import NS, Library, composite, matrix, mul  # noqa: E402

UI = ROOT / "external" / "FlashSrc" / "SRC_XFL" / "ui"
CFG = ROOT / "external" / "BleachVsNaruto" / "shared" / "assets" / "assets" / "config"
IMG = ROOT / "images" / "bvn" / "ui" / "musou"
FACES = ROOT / "images" / "bvn" / "face"
GEN = ROOT / "component_types" / "generated"

# name -> (document, symbol or linkage class, options); see convert_ui.SCREENS.
MOVIES = {
    # The fight HUD (MusouUI): bars, faces and texts are drawn by BVNMusouHud at their slots.
    "musou_ui": ("musou", "$musou$MC_ui", {"hide": {"startKOmc", "hitsmc"}}),
    "musou_start_ko": ("musou", "game_start_mc", {}),
    "musou_hits": ("musou", "$musou$MC_hits", {}),
    "musou_hits_digits": ("fight", "$fight$MC_hitsNumer", {}),
    "musou_hpbar": ("musou", "hpbar_bar", {}),
    "musou_hpbar_red": ("musou", "hpbar_bar 副本", {}),
    "musou_qibar_seg": ("musou", "qibar", {}),
    "musou_qibar_max": ("musou", "元件 42", {}),
    "musou_energy_bar": ("musou", "energybar_bar", {}),
    "musou_energy_txt": ("musou", "energybar_txt_mc", {"override": {"mc": 0}}),
    "musou_energy_txt_red": ("musou", "energybar_txt_mc", {"override": {"mc": 1}}),
    "musou_mini_bar": ("musou", "元件 38", {}),
    "musou_boss_bar": ("musou", "元件 39", {}),
    "musou_enemy_hp": ("musou", "$musou$MC_enemyHpBar", {}),
    "musou_enemy_hp_bar": ("musou", "enemyhpbar", {}),
    "musou_enemy_follow": ("musou", "$musou$MC_enemyHpBarFollow", {}),
    "musou_enemy_follow_bar": ("musou", "元件 43", {}),
    # Dialogs (MusouStateDialog, MusouSelectDialog, MusouConfrimUI / AlertUI).
    "musou_team_panel": ("dialog", "$dialog$MC_musouTeamPanel", {"hide": {"p0", "p1", "p2"}}),
    "musou_bigface": ("dialog", "big_face_head", {"hide": {"isLeaderMc"}}),
    "musou_leader_mark": ("dialog", "元件 1", {}),
    "musou_exp_fill": ("dialog", "元件 8", {}),
    "musou_select_panel": ("dialog", "$dialog$MC_selectFighterPanel", {}),
    "musou_faceui": ("dialog", "$dialog$SP_faceUI", {"hide": {"seltmc"}}),
    "musou_faceui_sel": ("dialog", "元件 3", {}),
    "musou_dot": ("dialog", "$dialog$MC_dot", {}),
    "musou_coin_ico": ("dialog", "$dialog$MC_coinIco", {}),
    "musou_coin_ui": ("dialog", "$dialog$MC_coinUI", {}),
    "musou_confirm": ("dialog", "$dialog$MC_confirm", {}),
    "musou_btn_back": ("dialog", "$dialog$BTN_back", {}),
    # Big map (WorldMapStage): the point's colours (pmc), the leader's face, clouds.
    "musou_map_pmc": ("big_map", "元件 3", {}),
    "musou_map_face": ("big_map", "元件 4", {}),
    "musou_map_cloud": ("big_map", "$big_map$MC_cloud", {}),
}

# MusouFighterModel.initFighters: the fighters the dialogs sell.
SELL = ["ichigo", "ichigo_zero", "rukia", "renji", "naruto", "sakura", "uryuu", "lee", "neji", "temari", "chad", "karin",
        "gaara", "sasuke", "orihime", "ikkaku", "gin", "juggo", "suigetsu", "kakashi", "sakura_sr", "hinata", "kimimaro",
        "killerbee", "toushirou", "byakuya", "jiraiya", "orochimaru", "deidara", "soifon", "konan", "grimmjow", "mayuri",
        "yoruichi", "kenpachi", "itachi", "pain", "ichigo_bankai", "naruto_oneTail", "sasuke_susanoo", "ichigo_vizored_half",
        "naruto_hermit", "starrk", "ulquiorra", "obito", "aizen", "madara", "kenshin"]

# Masked faces: kind -> (document, symbol, content instance, face url key, face size (AssetManager)).
MASKED = {
    "bar": ("musou", "#链接/MC_hpBarFace", "ct", "face_bar", (102, 64)),
    "mini": ("musou", "#链接/MC_miniFace", "ct", "face", (50, 50)),
    "boss": ("musou", "bosshpmc", "ct_face", "face", (37, 37)),
    "enemy": ("musou", "#链接/MC_enemyHpBar", "ct_face", "face", (50, 50)),
    "big": ("dialog", "big_face_head", "ct", "face_win", (300, 250)),
}


class MusouScreens(cu.Screens):
    """convert_ui.Screens writing to the musou image / sound folders."""

    def lib(self, doc):
        if doc not in self.libs:
            lib = Library(UI / doc)
            import xml.etree.ElementTree as ET
            dom = ET.parse(UI / doc / "DOMDocument.xml").getroot()
            lib.all_sounds = {it.get("name"): it for it in dom.iter(NS + "DOMSoundItem")}
            out = IMG / doc
            shutil.rmtree(out, ignore_errors=True)
            out.mkdir(parents=True)
            self.libs[doc] = lib
        return self.libs[doc]

    def image(self, doc, key, make):
        k = (doc, key)
        if k not in self.images:
            im = make()
            if im is None:
                self.images[k] = None
            else:
                n = sum(1 for d, _ in self.images if d == doc) + 1
                name = "i%d.png" % n
                im.save(IMG / doc / name, optimize=True)
                self.images[k] = ("bvn/ui/musou/%s/%s" % (doc, name), im.size[0], im.size[1])
        return self.images[k]

    def sound(self, doc, name):
        k = (doc, name)
        if k in self.sounds:
            return self.sounds[k]
        lib = self.lib(doc)
        it = lib.all_sounds.get(name)
        clip = None
        if it is not None:
            out = ROOT / "audio" / "bvn" / "ui" / ("musou_" + doc)
            out.mkdir(parents=True, exist_ok=True)
            base = "s%d" % (len([1 for d, _ in self.sounds if d == doc]) + 1)
            src = UI / doc / "LIBRARY" / (it.get("href") or name)
            dat = UI / doc / "bin" / it.get("soundDataHRef", "") if it.get("soundDataHRef") else None
            if src.exists() and src.suffix.lower() in (".wav", ".mp3"):
                shutil.copy(src, out / (base + src.suffix.lower()))
                clip = "bvn/ui/musou_%s/%s" % (doc, base)
            elif dat is not None and dat.exists():
                head = dat.read_bytes()[:3]
                if head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xfa") or head == b"ID3":
                    shutil.copy(dat, out / (base + ".mp3"))
                else:
                    import xfl as _x
                    _x.XFL = UI / doc
                    cu.write_dat_sound(it, out / (base + ".wav"))
                clip = "bvn/ui/musou_%s/%s" % (doc, base)
        self.sounds[k] = clip
        return clip

    def movie(self, name, doc, sym, opts):
        super().movie(name, doc, sym, opts)
        path = cu.DATA_UI / (name + ".lua")
        text = path.read_text(encoding="utf-8").split("\n", 1)[1]
        path.write_text("-- Generated by tools/convert_musou_ui.py from 5DPLAY's interface XFL. Do not edit.\n" + text,
                        encoding="utf-8")


# Config --------------------------------------------------------------------------------

def musou_config():
    """MusouModel.loadMapData: map1.json's way / parts and every area's missions."""
    maps = {}
    for map_dir in sorted((CFG / "musou").iterdir()):
        if not map_dir.is_dir():
            continue
        mid = map_dir.name
        root = json.loads((map_dir / (mid + ".json")).read_text(encoding="utf-8"))
        areas = {}
        for part in root["parts"]:
            f = map_dir / (part + ".json")
            if f.exists():
                areas[part] = json.loads(f.read_text(encoding="utf-8"))
        maps[root["id"]] = {"id": root["id"], "name": root.get("name"), "way": root["way"], "parts": root["parts"], "areas": areas}
    return maps


def fighter_faces():
    data = json.loads((CFG / "fighter.json").read_text(encoding="utf-8"))["fighter"]["data"]
    return {d["id"]: d.get("urls", {}) for d in data}


# Masks ------------------------------------------------------------------------------------

def mask_alpha(lib, sym):
    """The mask layer of `sym` (frame 0) rasterized: (alpha image, x0, y0) in symbol coordinates."""
    tl = lib.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
    items = []
    for layer in tl.find(NS + "layers").findall(NS + "DOMLayer"):
        if layer.get("layerType") != "mask":
            continue
        fr = layer.find(NS + "frames").find(NS + "DOMFrame")

        def add(container, m):
            for el in container:
                tag = el.tag[len(NS):]
                if tag == "DOMGroup":
                    mem = el.find(NS + "members")
                    if mem is not None:
                        add(mem, m)
                elif tag == "DOMShape":
                    r = cu.raster_shape(el)
                    if r is not None:
                        im, x0, y0 = r
                        items.append((im, mul(mul(m, matrix(el)), (1, 0, 0, 1, x0, y0)), 1.0))
        els = fr.find(NS + "elements")
        if els is not None:
            add(els, (1, 0, 0, 1, 0, 0))
    if not items:
        return None
    im, x0, y0 = composite(items)
    return im.split()[3], x0, y0


def instance_matrix(lib, sym, name):
    tl = lib.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
    for layer in tl.find(NS + "layers").findall(NS + "DOMLayer"):
        fr = layer.find(NS + "frames")
        if fr is None:
            continue
        for el in fr.iter(NS + "DOMSymbolInstance"):
            if el.get("name") == name:
                return matrix(el)
    return None


def masked_faces(sell_and_bosses, urls):
    out = {}
    libs = {}
    for kind, (doc, sym, inst, key, size) in MASKED.items():
        lib = libs.setdefault(doc, Library(UI / doc))
        sym = lib.linkage.get(sym, sym)
        mask = mask_alpha(lib, sym)
        ct = instance_matrix(lib, sym, inst)
        dst = IMG / "face" / kind
        shutil.rmtree(dst, ignore_errors=True)
        dst.mkdir(parents=True)
        faces = {}
        for fid in sell_and_bosses:
            u = urls.get(fid, {})
            f = u.get(key)
            src = FACES / f if f else None
            if not src or not src.exists():
                continue
            face = Image.open(src).convert("RGBA")
            fm = mul(ct, (size[0] / face.size[0], 0, 0, size[1] / face.size[1], 0, 0))
            if mask is None:
                im, x0, y0 = composite([(face, fm, 1.0)])
            else:
                malpha, mx0, my0 = mask
                fimg, fx0, fy0 = composite([(face, fm, 1.0)])
                canvas = Image.new("RGBA", malpha.size, (0, 0, 0, 0))
                canvas.alpha_composite(fimg, (max(0, fx0 - mx0), max(0, fy0 - my0)),
                                       (max(0, mx0 - fx0), max(0, my0 - fy0)))
                a = canvas.split()[3]
                from PIL import ImageChops
                canvas.putalpha(ImageChops.multiply(a, malpha))
                im, x0, y0 = canvas, mx0, my0
            bb = im.getbbox()
            if not bb:
                continue
            im = im.crop(bb)
            x0, y0 = x0 + bb[0], y0 + bb[1]
            name = "%s.png" % fid
            im.save(dst / name, optimize=True)
            # Drawn at the content instance's slot: undo its matrix (translate + uniform scale).
            s = ct[0] if abs(ct[0]) > 1e-6 else 1
            faces[fid] = {"img": "bvn/ui/musou/face/%s/%s" % (kind, name), "x": round((x0 - ct[4]) / s, 2),
                          "y": round((y0 - ct[5]) / s, 2), "s": round(1 / s, 4)}
        out[kind] = faces
        print("[musou] masked faces %s: %d" % (kind, len(faces)), flush=True)
    return out


# Big map ----------------------------------------------------------------------------------

def big_map():
    lib = Library(UI / "big_map")
    out = IMG / "map"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    root = lib.linkage["$big_map$MC_bigMap"]
    bright = lib.image("bvnmap.png")
    dark = lib.image("bvnmap_mask.png")
    dark.save(out / "bg.png", optimize=True)
    points, reveals = {}, {}
    point_sym = instance_symbol(lib, root, "point_mc")
    mask_sym = instance_symbol(lib, root, "mask_mc")
    for name, m in children(lib, point_sym):
        points[name] = [round(m[4], 2), round(m[5], 2)]
    for name, m, el in children(lib, mask_sym, with_el=True):
        items = lib.draw_list(el.get("libraryItemName"), 0, m, 1.0)
        if not items:
            continue
        im, x0, y0 = composite(items)
        alpha = im.split()[3]
        piece = Image.new("RGBA", im.size, (0, 0, 0, 0))
        box = (max(0, x0), max(0, y0), min(bright.size[0], x0 + im.size[0]), min(bright.size[1], y0 + im.size[1]))
        if box[2] <= box[0] or box[3] <= box[1]:
            continue
        piece.paste(bright.crop(box), (box[0] - x0, box[1] - y0))
        from PIL import ImageChops
        piece.putalpha(ImageChops.multiply(piece.split()[3], alpha))
        bb = piece.getbbox()
        piece = piece.crop(bb)
        piece.save(out / ("area_%s.png" % name), optimize=True)
        reveals[name] = {"img": "bvn/ui/musou/map/area_%s.png" % name, "x": x0 + bb[0], "y": y0 + bb[1]}
    # The wave counter's ring (KyoDrawUtils.drawRing(10, 29, angle, [YELLOW, RED])): every 5 degrees.
    ring = IMG / "ring"
    shutil.rmtree(ring, ignore_errors=True)
    ring.mkdir(parents=True)
    for k in range(73):
        draw_ring(k * 5).save(ring / ("r%d.png" % k), optimize=True)
    print("[musou] big map: %d points, %d revealed pieces" % (len(points), len(reveals)), flush=True)
    return {"bg": "bvn/ui/musou/map/bg.png", "w": dark.size[0], "h": dark.size[1], "points": points, "reveals": reveals,
            "ring": "bvn/ui/musou/ring/r%d.png"}


def draw_ring(angle, thick=10, radius=29):
    S = 4
    size = radius * 2
    big = Image.new("RGBA", (size * S, size * S), (0, 0, 0, 0))
    px = big.load()
    r0, r1 = (radius - thick) * S, radius * S
    c = size * S / 2
    for y in range(size * S):
        for x in range(size * S):
            dx, dy = x + 0.5 - c, y + 0.5 - c
            d = math.hypot(dx, dy)
            if d < r0 or d > r1:
                continue
            # Clockwise from the top.
            a = (math.degrees(math.atan2(dx, -dy)) + 360) % 360
            if a > angle or angle <= 0:
                continue
            t = a / 360
            px[x, y] = (255, int(255 * (1 - t)), 0, 255)
    return big.resize((size, size), Image.LANCZOS)


def instance_symbol(lib, sym, name):
    tl = lib.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
    for layer in tl.find(NS + "layers").findall(NS + "DOMLayer"):
        fr = layer.find(NS + "frames")
        if fr is None:
            continue
        for el in fr.iter(NS + "DOMSymbolInstance"):
            if el.get("name") == name:
                return el.get("libraryItemName")
    return None


def children(lib, sym, with_el=False):
    tl = lib.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
    out = []
    for layer in tl.find(NS + "layers").findall(NS + "DOMLayer"):
        fr = layer.find(NS + "frames")
        if fr is None:
            continue
        f0 = fr.find(NS + "DOMFrame")
        els = f0.find(NS + "elements") if f0 is not None else None
        for el in (els if els is not None else []):
            if el.tag == NS + "DOMSymbolInstance" and el.get("name"):
                out.append((el.get("name"), matrix(el), el) if with_el else (el.get("name"), matrix(el)))
    return out


def main():
    maps = musou_config()
    urls = fighter_faces()
    bosses = []
    for mp in maps.values():
        for area in mp["areas"].values():
            for ms in area.get("missions", []):
                for w in ms["waves"]:
                    for e in w["enemies"] + ((w.get("repeat") or {}).get("enemies") or []):
                        if e.get("isBoss") and e["id"] not in bosses:
                            bosses.append(e["id"])
    ids = SELL + [b for b in bosses if b not in SELL]
    sc = MusouScreens()
    for name, (doc, sym, opts) in MOVIES.items():
        sc.movie(name, doc, sym, opts)
    cfg = {"maps": maps, "sell": SELL, "bigmap": big_map(), "faces": masked_faces(ids, urls)}
    GEN.mkdir(parents=True, exist_ok=True)
    (GEN / "BVNMusouConfig.lua").write_text(
        "-- Generated by tools/convert_musou_ui.py from 5DPLAY's musou config and interface XFL. Do not edit.\n"
        "BVNMusouConfig = %s\n" % lua_val(cfg), encoding="utf-8")
    print("[musou] screens: %d skewed draws, %d unsupported shapes, masks ignored in %s"
          % (sc.stats["skew"], sc.stats["shapes_skipped"], ", ".join(sorted(sc.stats["masks"])) or "none"), flush=True)


if __name__ == "__main__":
    main()
