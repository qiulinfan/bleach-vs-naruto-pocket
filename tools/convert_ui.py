#!/usr/bin/env python3
"""Export 5DPLAY's interface symbols (fight HUD, ...) from the FlashSrc XFL as
part trees the game composes at run time.

A tree is a list of parts in drawing order: a static image {img, x, y}, or a
named child {name, m = {a, b, c, d, tx, ty}, parts | frames}. Named children
are what the original FightUI code drives (bar scale, digits, faces), so they
stay separate. Writes images/bvn/ui/<doc>/*.png and generated/BVNUIData.lua.
"""
import hashlib
import math
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_bvn import ROOT, lua_val  # noqa: E402
from xfl import NS, Library, composite, lerp_m, matrix, mul, write_dat_sound  # noqa: E402

UI = ROOT / "external" / "FlashSrc" / "SRC_XFL" / "ui"
FACES = ROOT / "images" / "bvn" / "face"
# Symbols exported per document, at a frame number, a frame label, or every frame ("all").
EXPORTS = {
    "fight": {"$fight$MC_hpBar": "fadin_fin", "$fight$MC_qiBar": "fadin_fin", "$fight$MC_hits": 0, "$fight$MC_timeNumber": "all",
              "$fight$MC_hitsNumer": "all", "$fight$MC_scoreNumber": "all", "$fight$MC_win": 0, "$fight$MC_fightUI": 0,
              "$fight$SP_playerPos1": 0, "$fight$SP_playerPos2": 0},
}
# Timelines the HUD plays itself (fadin / fadout, the hit counter): per frame the
# top-level named children's matrices and the static images, plus labels and stops.
TRACKS = {"fight": ["$fight$MC_hpBar", "$fight$MC_qiBar", "$fight$MC_hits"]}
# Whole symbols exported as flattened animations with their frame labels.
ANIMS = {"fight": ["game_start_mc"]}
# Named instances left out of the flattened animations.
ANIM_SKIP = {"winnermc"}
# Named children whose every frame is exported (digits, per-state art).
MULTI = {"#链接/MC_timeNumber", "#链接/MC_hitsNumer", "#链接/MC_scoreNumber", "#链接/MC_qiBarNumber", "winmc_bleach",
         "winmc_naruto"}


class Exporter:
    def __init__(self, doc):
        self.doc = doc
        if (UI / doc).exists():
            self.lib = Library(UI / doc)
        self.out = ROOT / "images" / "bvn" / "ui" / doc
        shutil.rmtree(self.out, ignore_errors=True)
        self.out.mkdir(parents=True)
        self.seen = {}
        self.shapes = {}
        self.baked = {}

    def save(self, im):
        key = hashlib.sha1(im.tobytes() + bytes(str(im.size), "ascii")).hexdigest()
        if key not in self.seen:
            name = "p%d.png" % (len(self.seen) + 1)
            im.save(self.out / name, optimize=True)
            self.seen[key] = name
        return "bvn/ui/%s/%s" % (self.doc, self.seen[key])

    def tree(self, sym, t, depth=0, shallow=False):
        """Parts of frame t. shallow: named children carry only their matrix (tracks)."""
        lib = self.lib
        parts, batch = [], []

        def flush():
            if batch:
                im, x0, y0 = composite(self.baked_items(batch))
                if im is not None and im.getbbox():
                    bb = im.getbbox()
                    parts.append({"img": self.save(im.crop(bb)), "x": x0 + bb[0], "y": y0 + bb[1]})
                batch.clear()

        for frames in reversed(lib.layers(sym)):
            for k, (idx, dur, fr) in enumerate(frames):
                if not (idx <= t < idx + dur):
                    continue
                nxt = frames[k + 1] if k + 1 < len(frames) else None
                tween = fr.get("tweenType") == "motion" and nxt is not None and dur > 0
                els = lib.elements(fr)
                nels = lib.elements(nxt[2]) if tween else []
                for i, el in enumerate(els):
                    em, ect = matrix(el), color_of(el)
                    if tween and i < len(nels):
                        f = (t - idx) / dur
                        em = lerp_m(em, matrix(nels[i]), f)
                        ect = ct_lerp(ect, color_of(nels[i]), f)
                    name = el.get("name")
                    child = el.get("libraryItemName")
                    if name and el.tag == NS + "DOMSymbolInstance" and child in lib.symbols and depth < 6:
                        flush()
                        node = {"name": name, "m": [round(v, 4) for v in em], "alpha": round(ect[3], 3)}
                        if not shallow:
                            n = lib.length(child)
                            settled = self.label(child, "fadin_fin")
                            if child in MULTI or (settled is None and 1 < n <= 12):
                                node["frames"] = [self.tree(child, f, depth + 1) for f in range(n)]
                            else:
                                node["parts"] = self.tree(child, settled or 0, depth + 1)
                        parts.append(node)
                    else:
                        # Static content: flatten into the current image batch.
                        batch.extend(self.element(el, em, ect, t - idx))
                break
        flush()
        return parts

    def label(self, sym, name):
        for layer in layers_all(self.lib, sym):
            for idx, _, fr in layer:
                if fr.get("name") == name:
                    return idx
        return None

    def baked_items(self, items):
        """(image, matrix, colour transform) -> (image with its RGB transform baked, matrix, alpha)."""
        out = []
        for img, m, ct in items:
            if not ct_rgb_identity(ct):
                key = (id(img), tuple(round(v, 3) for v in ct[:3] + ct[4:7]))
                if key not in self.baked:
                    self.baked[key] = bake_color(img, ct)
                img = self.baked[key]
            out.append((img, m, max(0.0, min(1.0, ct[3] + ct[7] / 255))))
        return out

    def element(self, el, m, ct, rel, depth=0):
        """Draw items (image, matrix, colour transform) of one element: bitmaps,
        bitmap-filled and solid / gradient vector shapes, nested symbols."""
        lib = self.lib
        tag = el.tag[len(NS):]
        if tag == "DOMBitmapInstance":
            img = lib.image(el.get("libraryItemName"))
            return [(img, m, ct)] if img is not None else []
        if tag == "DOMShape":
            fill = el.find(".//" + NS + "BitmapFill")
            if fill is not None:
                img = lib.image(fill.get("bitmapPath"))
                fm = matrix(fill)
                fm = (fm[0] / 20, fm[1] / 20, fm[2] / 20, fm[3] / 20, fm[4], fm[5])
                return [(img, mul(m, fm), ct)] if img is not None else []
            if id(el) not in self.shapes:
                self.shapes[id(el)] = raster_shape(el)
            r = self.shapes[id(el)]
            if r is None:
                return []
            img, x0, y0 = r
            return [(img, mul(m, (1, 0, 0, 1, x0, y0)), ct)]
        child = el.get("libraryItemName")
        if tag != "DOMSymbolInstance" or child not in lib.symbols or depth > 12:
            return []
        n = lib.length(child)
        first = int(el.get("firstFrame", 0))
        loop = el.get("loop", "loop")
        if el.get("symbolType") == "graphic":
            t = first if loop == "single frame" else (min(n - 1, first + rel) if loop == "play once" else (first + rel) % n)
        else:
            t = 0
        out = []
        for frames in reversed(lib.layers(child)):
            for k, (idx, dur, fr) in enumerate(frames):
                if not (idx <= t < idx + dur):
                    continue
                nxt = frames[k + 1] if k + 1 < len(frames) else None
                tween = fr.get("tweenType") == "motion" and nxt is not None and dur > 0
                nels = lib.elements(nxt[2]) if tween else []
                for i, e in enumerate(lib.elements(fr)):
                    em, ect = matrix(e), color_of(e)
                    if tween and i < len(nels):
                        f = (t - idx) / dur
                        em = lerp_m(em, matrix(nels[i]), f)
                        ect = ct_lerp(ect, color_of(nels[i]), f)
                    out += self.element(e, mul(m, em), ct_mul(ect, ct), t - idx, depth + 1)
                break
        return out

    def track(self, sym):
        """Every frame of sym, named children shallow, with labels, stop() frames
        and gotoAndStop(n) jumps (frame numbers 1-based)."""
        n = self.lib.length(sym)
        frames = [self.tree(sym, t, shallow=True) for t in range(n)]
        labels, stops, gotos = {}, [], {}
        for layer in layers_all(self.lib, sym):
            for idx, _, fr in layer:
                nm = fr.get("name")
                if nm and fr.get("labelType", "name") == "name":
                    labels.setdefault(nm, idx + 1)
                sc = fr.find(NS + "Actionscript")
                src = "".join(sc.itertext()) if sc is not None else ""
                if "stop()" in src:
                    stops.append(idx + 1)
                g = re.search(r"gotoAndStop\((\d+)\)", src)
                if g:
                    gotos[idx + 1] = int(g.group(1))
        return {"frames": frames, "labels": labels, "stops": sorted(set(stops)), "gotos": gotos}

    def mask_of(self, sym):
        """The first mask layer's shape of sym as (alpha image, x0, y0)."""
        tl = self.lib.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
        for layer in tl.find(NS + "layers").findall(NS + "DOMLayer"):
            if layer.get("layerType") == "mask":
                for sh in layer.iter(NS + "DOMShape"):
                    r = raster_shape(sh)
                    if r:
                        return r
        return None


def masked_faces(ex):
    """Fighter faces as the fight HUD shows them: AssetManager sizes (face bar
    102x64, assist face 50x50) cut by the face holders' mask layers, which the
    engine cannot apply at run time. Returns {face file: image}."""
    from PIL import Image as _I
    out_dir = ROOT / "images" / "bvn" / "ui" / "hudface"
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    faces = {}
    if not FACES.exists():
        print("[ui] no faces in %s; run tools/convert_maps.py first for masked HUD faces" % FACES)
        return faces
    specs = [("#链接/MC_hpBarFace", (102, 64), lambda n: n.endswith("_m.png")),
             ("#链接/MC_qiBarFace", (50, 50), lambda n: not re.search(r"_(b|m|w)\.png$", n))]
    for sym, size, pick in specs:
        r = ex.mask_of(sym)
        if r is None:
            continue
        mimg, mx, my = r
        mask = _I.new("L", size, 0)
        mask.paste(mimg.getchannel("A"), (mx, my))
        for f in sorted(FACES.glob("*.png")):
            if not pick(f.name):
                continue
            im = _I.open(f).convert("RGBA").resize(size, _I.BILINEAR)
            a = _I.composite(im.getchannel("A"), _I.new("L", size, 0), mask)
            im.putalpha(a)
            im.save(out_dir / f.name, optimize=True)
            faces[f.name] = "bvn/ui/hudface/" + f.name
    return faces


def fz_slices(ex):
    """QiBar's InsFzBar: barmc (qbar_bar.png, flipped twice) shown through a
    scrollRect of height process * 45 from the bottom. Slice k is the image's
    bottom k rows, drawn k rows above the bar's bottom."""
    img = ex.lib.image("qbar_bar.png")
    if img is None:
        return None
    w, h = img.size
    slices = []
    for k in range(1, h + 1):
        slices.append({"img": ex.save(img.crop((0, h - k, w, h))), "y": h - k})
    return {"h": h, "slices": slices}


def main():
    data = {}
    for doc, symbols in EXPORTS.items():
        ex = Exporter(doc)
        for cls, frame in symbols.items():
            sym = ex.lib.linkage.get(cls)
            if not sym:
                print("[ui] %s: no symbol %s" % (doc, cls))
                continue
            n = ex.lib.length(sym)
            if frame == "all":
                data[cls] = {"frames": [ex.tree(sym, f) for f in range(n)]}
            else:
                if isinstance(frame, str):
                    frame = ex.label(sym, frame) or 0
                data[cls] = {"parts": ex.tree(sym, n - 1 if frame == -1 else frame)}
            print("[ui] %s %s: %d frames" % (doc, cls, n), flush=True)
        tracks = data.setdefault("tracks", {})
        for cls in TRACKS.get(doc, []):
            sym = ex.lib.linkage.get(cls)
            if sym:
                tracks[cls] = ex.track(sym)
                print("[ui] %s track %s: %d frames" % (doc, cls, len(tracks[cls]["frames"])), flush=True)
        if doc == "fight":
            data["fzbar"] = fz_slices(ex)
            data["hudfaces"] = masked_faces(ex)
            print("[ui] fight: %d masked HUD faces" % len(data["hudfaces"]), flush=True)
    anims = {}
    for doc, syms in ANIMS.items():
        ex = Exporter(doc + "_anim")
        ex.lib = Library(UI / doc)
        # The winner banner's `winnermc` is positioned per winning side by FightUI,
        # so it is exported separately (anims.winnermc) and left out of the banner.
        plain = ex.lib.elements
        ex.lib.elements = lambda fr: [e for e in plain(fr) if e.get("name") not in ANIM_SKIP]
        for sym in syms:
            n = ex.lib.length(sym)

            def render_all():
                frames = []
                for t in range(n):
                    if digit:
                        ex.lib.frame_override = {"nummc": digit(t)}
                    im, x0, y0 = composite(ex.lib.draw_list(sym, t, (1, 0, 0, 1, 0, 0), 1.0))
                    if im is None or not im.getbbox():
                        frames.append({})
                        continue
                    bb = im.getbbox()
                    frames.append({"img": ex.save(im.crop(bb)), "x": x0 + bb[0], "y": y0 + bb[1]})
                return frames
            # The round banner's digit: frames 26 and 27 call nummc.gotoAndPlay("r" + $round);
            # the clip then plays at the 60 fps stage rate (two of its frames per
            # banner frame, which renderAnimate steps at 30 fps) up to its next stop().
            digit = None
            rounds = []
            marks = {}
            if "round_num_mc" in ex.lib.symbols:
                for layer in layers_all(ex.lib, "round_num_mc"):
                    for idx, _, fr in layer:
                        if fr.get("name"):
                            marks[fr.get("name")] = idx
                        sc = fr.find(NS + "Actionscript")
                        if sc is not None and "stop()" in "".join(sc.itertext()):
                            marks.setdefault("stops", []).append(idx)
            for r in range(1, 6):
                lab = marks.get("r%d" % r)
                if lab is None:
                    digit = None
                    ex.lib.frame_override = {"nummc": r - 1}
                else:
                    stop = min([i for i in marks.get("stops", []) if i > lab] or [lab])
                    digit = (lambda lab, stop: lambda t: min(stop, lab + max(0, t - 27) * 2))(lab, stop)
                rounds.append(render_all())
            digit = None
            ex.lib.frame_override = {}
            frames = rounds[0]
            labels = {}
            for layer in layers_all(ex.lib, sym):
                for idx, _, fr in layer:
                    nm = fr.get("name")
                    if nm and fr.get("labelType", "name") == "name" and nm not in labels:
                        labels[nm] = idx + 1
            anims[sym] = {"frames": frames, "labels": labels, "rounds": rounds}
            print("[ui] anim %s: %d frames" % (sym, n), flush=True)
        if doc == "fight":
            anims["winnermc"] = winner_anim(ex)
    data["anims"] = anims
    export_screens(data)
    gen = ROOT / "component_types" / "generated"
    (gen / "BVNUIData.lua").write_text("-- Generated by tools/convert_ui.py from 5DPLAY's interface XFL. Do not edit.\nBVNUIData = %s\n"
                                       % lua_val(data), encoding="utf-8")


def winner_anim(ex):
    """game_start_mc's winnermc ("元件 25"): frames relative to its origin. The
    first frames end with `if(!isPerfect) stop()`; a perfect win plays on."""
    lib = ex.lib
    sym = "元件 25"
    n = lib.length(sym)
    frames = []
    for t in range(n):
        im, x0, y0 = composite(lib.draw_list(sym, t, (1, 0, 0, 1, 0, 0), 1.0))
        if im is None or not im.getbbox():
            frames.append({})
            continue
        bb = im.getbbox()
        frames.append({"img": ex.save(im.crop(bb)), "x": x0 + bb[0], "y": y0 + bb[1]})
    labels, stop = {}, n
    for layer in layers_all(lib, sym):
        for idx, _, fr in layer:
            nm = fr.get("name")
            if nm and fr.get("labelType", "name") == "name":
                labels.setdefault(nm, idx + 1)
            sc = fr.find(NS + "Actionscript")
            if sc is not None and "isPerfect" in "".join(sc.itertext()) and "stop()" in "".join(sc.itertext()):
                stop = min(stop, idx + 1)
    print("[ui] anim winnermc: %d frames, non-perfect stop at %d" % (n, stop), flush=True)
    return {"frames": frames, "labels": labels, "stopFrame": stop}


# Out-of-battle screens ------------------------------------------------------------------
#
# A screen is exported as a movie: per timeline frame, a draw list of library
# bitmaps (and rasterized vector shapes) with their full matrices (flat runs of
# image index, a, b, c, d, tx, ty, alpha), plus tables marking
# for named instances (`slot`, where the game adds faces, buttons, text) and
# static text runs. Movies are written to data/bvn/ui/<name>.lua and loaded on
# demand by BVNScreen; their bitmaps go to images/bvn/ui/m/<doc>/.

DATA_UI = ROOT / "data" / "bvn" / "ui"
FONT_DIR = ROOT / "external" / "TagAssets" / "shared" / "assets" / "assets" / "font"
CORE_ASSETS = ROOT / "external" / "BleachVsNaruto" / "CORE_KernelLogic" / "assets"
SELECT_XML = ROOT / "external" / "BleachVsNaruto" / "shared" / "assets" / "assets" / "config" / "select.xml"

# name -> (document, symbol or linkage class, options). Options: hide = named
# instances whose content is left out (their slot marker stays), override =
# {instance name: fixed frame}, frames = (first, last) range to export.
SCREENS = {
    # MC_logo carries a developer's note as static text; it is not part of the logo.
    "logo": ("common", "$common$MC_logo", {"notext": True}),
    "menubtn_bg": ("common", "wzimg_bgimg", {}),
    "slt_arrow": ("common", "$common$MC_sltArrow", {}),
    "transition": ("common", "$common$MC_transition", {}),
    "congratulations": ("common", "$common$MC_congratulations", {}),
    "win_text": ("common", "$common$MC_winText", {}),
    "title": ("title", "$title$MC_stgTitle", {"hide": {"logo_mc"}, "hold": 120}),
    "how2play": ("how2play", "$how2play$MC_movieHow2Play", {}),
    "select_bg": ("select", "$select$MC_stgSelect", {"hold": 105}),
    "select_cursor_p1": ("select", "$select$MC_selectItemMc", {"override": {"mc": 0}}),
    "select_cursor_p2": ("select", "$select$MC_selectItemMc", {"override": {"mc": 1}}),
    "select_item": ("select", "$select$SP_selectItem", {"hide": {"warning", "more_bg"}}),
    "select_warning": ("select", "元件 13", {}),
    "select_more_bg": ("select", "元件 11", {"color": (1, 1, 1, 255, 0, -255)}),
    "select_bar_p1": ("select", "$select$SP_selectBarItemP1", {}),
    "select_bar_p2": ("select", "$select$SP_selectBarItemP2", {}),
    "select_map": ("select", "$select$SP_selectMap", {}),
    "select_map_text": ("select", "$select$SP_selectMapText", {}),
    "loading_fight": ("loading", "$loading$MC_loadingFight", {"hide": {"sltui"}, "hold": 30}),
    "loading_bar": ("loading", "$loading$MC_loadingBar", {"hide": {"bar"}}),
    "loading_bar_fill": ("loading", "barmc", {}),
    "loading_cover": ("loading", "$loading$MC_loadingCover", {"hide": {"bar"}}),
    "select_text": ("loading", "$loading$MC_selectText", {}),
    "select_arrow1": ("loading", "$loading$SP_selectArrow1", {}),
    "select_arrow2": ("loading", "$loading$SP_selectArrow2", {}),
    "winner": ("loading", "$loading$MC_stageWinner", {"hide": {"txtmc", "btn_more"}, "hold": 30}),
    "winner_txt": ("loading", "元件 8", {}),
    "game_over": ("game_over", "$game_over$MC_stgGameOver", {}),
    "setting": ("setting", "$setting$MC_stgSetUI", {"hold": 15, "hold_once": True}),
    "text_arrow": ("setting", "$setting$SP_textArrow", {}),
}

def layers_all(lib, sym):
    """xfl.Library.layers_all, skipping folder layers (they have no frames)."""
    tl = lib.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
    out = []
    for layer in tl.find(NS + "layers").findall(NS + "DOMLayer"):
        fr = layer.find(NS + "frames")
        if fr is not None:
            out.append([(int(f.get("index")), int(f.get("duration", 1)), f) for f in fr.findall(NS + "DOMFrame")])
    return out


IDENT_CT = (1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0)


def color_of(el):
    """An element's colour transform (rm, gm, bm, am, ro, go, bo, ao); offsets in 0..255."""
    col = el.find(NS + "color")
    col = col.find(NS + "Color") if col is not None else None
    if col is None:
        return IDENT_CT
    g = lambda k, d: float(col.get(k, d))
    rm, gm, bm, am = g("redMultiplier", 1), g("greenMultiplier", 1), g("blueMultiplier", 1), g("alphaMultiplier", 1)
    ro, go, bo, ao = g("redOffset", 0), g("greenOffset", 0), g("blueOffset", 0), g("alphaOffset", 0)
    if col.get("tintMultiplier") is not None:
        t = g("tintMultiplier", 0)
        c = col.get("tintColor", "#000000").lstrip("#")
        r, gg, b = int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)
        rm = gm = bm = 1 - t
        ro, go, bo = r * t, gg * t, b * t
    if col.get("brightness") is not None:
        br = g("brightness", 0)
        if br > 0:
            rm = gm = bm = 1 - br
            ro = go = bo = 255 * br
        else:
            rm = gm = bm = 1 + br
    return (rm, gm, bm, am, ro, go, bo, ao)


def ct_mul(child, parent):
    """Apply child's transform, then parent's."""
    out = []
    for i in range(4):
        out.append(child[i] * parent[i])
    for i in range(4):
        out.append(child[4 + i] * parent[i] + parent[4 + i])
    return tuple(out)


def ct_lerp(a, b, f):
    return tuple(x + (y - x) * f for x, y in zip(a, b))


def ct_rgb_identity(ct):
    return all(abs(ct[i] - 1) < 0.01 for i in range(3)) and all(abs(ct[4 + i]) < 1 for i in range(3))


def bake_color(im, ct):
    r, g, b, a = im.split()
    r = r.point(lambda v: max(0, min(255, int(v * ct[0] + ct[4]))))
    g = g.point(lambda v: max(0, min(255, int(v * ct[1] + ct[5]))))
    b = b.point(lambda v: max(0, min(255, int(v * ct[2] + ct[6]))))
    from PIL import Image as _I
    return _I.merge("RGBA", (r, g, b, a))


# XFL edge strings: "!x y" moveTo, "|x y" or "/x y" lineTo, "[cx cy x y" quadTo,
# coordinates in twips, decimal or "#hex.frac"; "S<n>" selects styles.
EDGE_TOKEN = re.compile(r"[!|/\[\]]|S\d+|#[0-9A-Fa-f]+(?:\.[0-9A-Fa-f]+)?|-?\d+(?:\.\d+)?")


def edge_num(tok):
    if tok.startswith("#"):
        whole, _, frac = tok[1:].partition(".")
        v = int(whole, 16)
        if v >= 0x800000:
            v -= 0x1000000
        return (v + (int(frac, 16) / 256 if frac else 0)) / 20
    return float(tok) / 20


def edge_segments(edges):
    segs = []
    toks = EDGE_TOKEN.findall(edges)
    i, pen, cmd = 0, (0.0, 0.0), None
    while i < len(toks):
        t = toks[i]
        if t in "!|/[]":
            cmd = t
            i += 1
            continue
        if t.startswith("S"):
            i += 1
            continue
        if cmd == "!":
            pen = (edge_num(toks[i]), edge_num(toks[i + 1]))
            i += 2
        elif cmd in ("|", "/"):
            p = (edge_num(toks[i]), edge_num(toks[i + 1]))
            segs.append((pen, p))
            pen = p
            i += 2
        elif cmd in ("[", "]"):
            c = (edge_num(toks[i]), edge_num(toks[i + 1]))
            p = (edge_num(toks[i + 2]), edge_num(toks[i + 3]))
            prev = pen
            for k in range(1, 9):
                u = k / 8
                q = ((1 - u) ** 2 * pen[0] + 2 * (1 - u) * u * c[0] + u * u * p[0],
                     (1 - u) ** 2 * pen[1] + 2 * (1 - u) * u * c[1] + u * u * p[1])
                segs.append((prev, q))
                prev = q
            pen = p
            i += 4
        else:
            i += 1
    return segs


def parse_rgba(el):
    c = el.get("color", "#000000").lstrip("#")
    return (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16), int(round(float(el.get("alpha", 1)) * 255)))


def fill_painter(fill):
    """A function (x, y) -> RGBA for a FillStyle, or None for unsupported fills."""
    sc = fill.find(NS + "SolidColor")
    if sc is not None:
        c = parse_rgba(sc)
        return lambda x, y: c
    for tag in ("LinearGradient", "RadialGradient"):
        gr = fill.find(NS + tag)
        if gr is None:
            continue
        stops = [(float(e.get("ratio", 0)), parse_rgba(e)) for e in gr.findall(NS + "GradientEntry")]
        a, b, c, d, tx, ty = matrix(gr)
        det = a * d - b * c
        if abs(det) < 1e-12 or not stops:
            return None
        ia, ib, ic, id_ = d / det, -b / det, -c / det, a / det

        def color_at(r):
            r = max(0.0, min(1.0, r))
            if r <= stops[0][0]:
                return stops[0][1]
            for (r0, c0), (r1, c1) in zip(stops, stops[1:]):
                if r <= r1:
                    f = (r - r0) / (r1 - r0) if r1 > r0 else 0
                    return tuple(int(c0[k] + (c1[k] - c0[k]) * f) for k in range(4))
            return stops[-1][1]
        radial = tag == "RadialGradient"

        def paint(x, y):
            u = ia * (x - tx) + ic * (y - ty)
            v = ib * (x - tx) + id_ * (y - ty)
            if radial:
                return color_at(math.hypot(u, v) / 819.2)
            return color_at((u + 819.2) / 1638.4)
        return paint
    return None


def raster_shape(shape):
    """Rasterize a DOMShape's fills (even-odd scanlines, 2x supersampled). Returns (image, x0, y0) or None."""
    from PIL import Image as _I
    fills = {}
    for fs in shape.iter(NS + "FillStyle"):
        p = fill_painter(fs)
        if p is not None:
            fills[fs.get("index")] = p
    if not fills:
        return None
    per = {k: [] for k in fills}
    for e in shape.iter(NS + "Edge"):
        if not e.get("edges"):
            continue
        segs = edge_segments(e.get("edges"))
        for key in (e.get("fillStyle0"), e.get("fillStyle1")):
            if key in per:
                per[key].extend(segs)
    pts = [p for segs in per.values() for s in segs for p in s]
    if not pts:
        return None
    x0, y0 = math.floor(min(p[0] for p in pts)), math.floor(min(p[1] for p in pts))
    x1, y1 = math.ceil(max(p[0] for p in pts)), math.ceil(max(p[1] for p in pts))
    W, H = max(1, x1 - x0), max(1, y1 - y0)
    if W * H > 2000 * 2000:
        return None
    S = 2
    big = _I.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    px = big.load()
    for key, segs in per.items():
        paint = fills[key]
        solid = paint(0, 0) if key in fills and fills[key](0, 0) == fills[key](1e6, 1e6) else None
        for row in range(H * S):
            y = y0 + (row + 0.5) / S
            xs = []
            for (ax, ay), (bx, by) in segs:
                if (ay <= y < by) or (by <= y < ay):
                    xs.append(ax + (y - ay) * (bx - ax) / (by - ay))
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                c0 = max(0, int(round((xs[k] - x0) * S)))
                c1 = min(W * S, int(round((xs[k + 1] - x0) * S)))
                for col in range(c0, c1):
                    px[col, row] = solid or paint(x0 + (col + 0.5) / S, y)
    return big.resize((W, H), _I.LANCZOS), x0, y0


def text_attrs(el):
    run = el.find(".//" + NS + "DOMTextAttrs")
    size = float(run.get("size", 12)) if run is not None else 12
    color = (run.get("fillColor", "#000000") if run is not None else "#000000").lstrip("#")
    align = run.get("alignment", "left") if run is not None else "left"
    return {"size": size, "color": [int(color[0:2], 16), int(color[2:4], 16), int(color[4:6], 16)], "align": align,
            "w": float(el.get("width", 0)), "left": float(el.get("left", 0))}


class Screens:
    def __init__(self):
        self.libs = {}
        self.images = {}   # (doc, key) -> index entry
        self.sounds = {}   # (doc, sound name) -> clip
        self.stats = {"skew": 0, "shapes_skipped": 0, "masks": set()}
        self.chars = set()

    def lib(self, doc):
        if doc not in self.libs:
            lib = Library(UI / doc)
            # Every sound item with its data file (Library keeps only linked ones).
            import xml.etree.ElementTree as ET
            dom = ET.parse(UI / doc / "DOMDocument.xml").getroot()
            lib.all_sounds = {it.get("name"): it for it in dom.iter(NS + "DOMSoundItem")}
            out = ROOT / "images" / "bvn" / "ui" / "m" / doc
            shutil.rmtree(out, ignore_errors=True)
            out.mkdir(parents=True)
            self.libs[doc] = lib
        return self.libs[doc]

    # Images ---------------------------------------------------------------------------
    def image(self, doc, key, make):
        k = (doc, key)
        if k not in self.images:
            im = make()
            if im is None:
                self.images[k] = None
            else:
                n = sum(1 for d, _ in self.images if d == doc) + 1
                name = "i%d.png" % n
                im.save(ROOT / "images" / "bvn" / "ui" / "m" / doc / name, optimize=True)
                self.images[k] = ("bvn/ui/m/%s/%s" % (doc, name), im.size[0], im.size[1])
        return self.images[k]

    def sound(self, doc, name):
        k = (doc, name)
        if k in self.sounds:
            return self.sounds[k]
        lib = self.lib(doc)
        it = lib.all_sounds.get(name)
        clip = None
        if it is not None:
            out = ROOT / "audio" / "bvn" / "ui" / doc
            out.mkdir(parents=True, exist_ok=True)
            base = "s%d" % (len([1 for d, _ in self.sounds if d == doc]) + 1)
            src = UI / doc / "LIBRARY" / (it.get("href") or name)
            dat = UI / doc / "bin" / it.get("soundDataHRef", "") if it.get("soundDataHRef") else None
            if src.exists() and src.suffix.lower() in (".wav", ".mp3"):
                shutil.copy(src, out / (base + src.suffix.lower()))
                clip = "bvn/ui/%s/%s" % (doc, base)
            elif dat is not None and dat.exists():
                head = dat.read_bytes()[:3]
                if head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xfa") or head == b"ID3":
                    shutil.copy(dat, out / (base + ".mp3"))
                else:
                    import xfl as _x
                    _x.XFL = UI / doc
                    write_dat_sound(it, out / (base + ".wav"))
                clip = "bvn/ui/%s/%s" % (doc, base)
        self.sounds[k] = clip
        return clip

    # Timeline walk ----------------------------------------------------------------------
    def elements(self, fr):
        els = fr.find(NS + "elements")
        out = []
        if els is None:
            return out

        def add(container):
            for el in container:
                tag = el.tag[len(NS):]
                if tag == "DOMGroup":
                    m = el.find(NS + "members")
                    if m is not None:
                        add(m)
                elif tag in ("DOMBitmapInstance", "DOMSymbolInstance", "DOMShape", "DOMStaticText", "DOMDynamicText"):
                    out.append(el)
        add(els)
        return out

    def stop_frame(self, lib, sym):
        """First frame whose script stops the clip unconditionally, or None."""
        cache = lib.__dict__.setdefault("_stops", {})
        if sym not in cache:
            best = None
            for layer in layers_all(lib, sym):
                for idx, _, fr in layer:
                    sc = fr.find(NS + "Actionscript")
                    if sc is None:
                        continue
                    src = "".join(sc.itertext())
                    if "stop()" in src and "if(" not in src.replace(" ", ""):
                        best = idx if best is None else min(best, idx)
            cache[sym] = best
        return cache[sym]

    def walk(self, doc, sym, t, m, ct, path, opts, out, depth=0, tt=None):
        """Draw list of frame t. tt: this instance's clock (ticks since it was
        placed), which movie clips inside play by, so they keep animating while
        their parent holds a frame (Flash clips play independently)."""
        lib = self.lib(doc)
        if depth > 14 or sym not in lib.symbols:
            return
        tl = lib.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
        layers = tl.find(NS + "layers").findall(NS + "DOMLayer")
        for li in range(len(layers) - 1, -1, -1):
            layer = layers[li]
            lt = layer.get("layerType")
            if lt in ("guide", "folder"):
                continue
            if lt == "mask":
                self.stats["masks"].add("%s/%s" % (doc, sym))
                continue
            fnode = layer.find(NS + "frames")
            if fnode is None:
                continue
            frames = [(int(f.get("index")), int(f.get("duration", 1)), f) for f in fnode.findall(NS + "DOMFrame")]
            for k, (idx, dur, fr) in enumerate(frames):
                if not (idx <= t < idx + dur):
                    continue
                els = self.elements(fr)
                nxt = frames[k + 1] if k + 1 < len(frames) else None
                tween = fr.get("tweenType") == "motion" and nxt is not None and dur > 0
                nels = self.elements(nxt[2]) if tween else []
                for i, el in enumerate(els):
                    em, ec = matrix(el), color_of(el)
                    if tween and i < len(nels):
                        f = (t - idx) / dur
                        em = lerp_m(em, matrix(nels[i]), f)
                        ec = ct_lerp(ec, color_of(nels[i]), f)
                    self.element(doc, el, mul(m, em), ct_mul(ec, ct), path, opts, out, depth, frames, k,
                                 t - idx, (t if tt is None else tt))
                break

    def run_start(self, frames, k, el):
        """Frames since the start of the run of keyframes that keep this instance."""
        name, item = el.get("name"), el.get("libraryItemName")
        start = frames[k][0]
        j = k - 1
        while j >= 0:
            prev = [e for e in self.elements(frames[j][2]) if e.get("libraryItemName") == item and e.get("name") == name]
            if not prev:
                break
            start = frames[j][0]
            j -= 1
        return start

    def element(self, doc, el, mm, ct, path, opts, out, depth, frames, k, rel, clock):
        lib = self.lib(doc)
        tag = el.tag[len(NS):]
        if tag == "DOMBitmapInstance":
            self.leaf(doc, "b:" + el.get("libraryItemName"), lambda: lib.image(el.get("libraryItemName")), mm, ct, out)
            return
        if tag == "DOMShape":
            fill = el.find(".//" + NS + "BitmapFill")
            if fill is not None:
                fm = matrix(fill)
                fm = (fm[0] / 20, fm[1] / 20, fm[2] / 20, fm[3] / 20, fm[4], fm[5])
                self.leaf(doc, "b:" + fill.get("bitmapPath"), lambda: lib.image(fill.get("bitmapPath")), mul(mm, fm), ct, out)
                return
            import xml.etree.ElementTree as ET
            key = "s:" + hashlib.sha1(ET.tostring(el)).hexdigest()
            r = self.shape_cache.get(key) if hasattr(self, "shape_cache") else None
            if not hasattr(self, "shape_cache"):
                self.shape_cache = {}
            if key not in self.shape_cache:
                self.shape_cache[key] = raster_shape(el)
            r = self.shape_cache[key]
            if r is None:
                self.stats["shapes_skipped"] += 1
                return
            im, x0, y0 = r
            self.leaf(doc, key, lambda: im, mul(mm, (1, 0, 0, 1, x0, y0)), ct, out)
            return
        if tag in ("DOMStaticText", "DOMDynamicText"):
            name = el.get("name")
            attrs = text_attrs(el)
            text = "".join("".join(c.itertext()) for c in el.iter(NS + "characters")).replace("\r", "\n")
            entry = {"m": [round(v, 4) for v in mm], "a": round(ct[3], 3), "size": attrs["size"], "color": attrs["color"],
                     "align": attrs["align"], "w": attrs["w"], "left": attrs["left"]}
            self.chars.update(text)
            if name:
                entry["slot"] = path + name
                entry["text"] = text
                out.append(entry)
            elif text.strip() and not opts.get("notext"):
                entry["text"] = text
                out.append(entry)
            return
        # Symbol instance.
        name = el.get("name")
        child = el.get("libraryItemName")
        if name:
            out.append({"slot": path + name, "m": [round(v, 4) for v in mm], "a": round(ct[3], 3)})
        if child in lib.symbols and name not in opts.get("hide", ()):
            n = lib.length(child)
            first = int(el.get("firstFrame", 0))
            loop = el.get("loop", "loop")
            sub_clock = clock - frames[k][0]
            if el.get("symbolType") == "button":
                ctf = 0
            elif name in opts.get("override", {}):
                ctf = min(n - 1, opts["override"][name])
            elif el.get("symbolType") == "graphic":
                ctf = first if loop == "single frame" else (min(n - 1, first + rel) if loop == "play once" else (first + rel) % n)
            else:
                sub_clock = clock - self.run_start(frames, k, el)
                stop = self.stop_frame(lib, child)
                ctf = min(sub_clock, stop) if stop is not None and sub_clock >= stop else sub_clock % n
            self.walk(doc, child, ctf, mm, ct, path + (name + "/" if name else ""), opts, out, depth + 1, sub_clock)
        if name:
            # Closes the named instance's content, so the game can hide it (visible = false).
            out.append({"slotEnd": path + name})

    def leaf(self, doc, key, make, mm, ct, out):
        a = ct[3]
        if a <= 0.004:
            return
        if not ct_rgb_identity(ct):
            q = tuple(round(v, 2) if i < 4 else int(round(v / 8) * 8) for i, v in enumerate(ct))
            base = make

            def make():
                im = base()
                return bake_color(im, q) if im is not None else None
            key = key + "|" + ",".join(str(v) for v in q[:3] + q[4:7])
        entry = self.image(doc, key, make)
        if entry is None:
            return
        a_, b_, c_, d_ = mm[:4]
        if abs(a_ * c_ + b_ * d_) > 1e-3 * max(1e-6, math.hypot(a_, b_) * math.hypot(c_, d_)):
            self.stats["skew"] += 1
        out.append([entry, [round(v, 4) for v in mm], round(a, 3)])

    def movie(self, name, doc, sym, opts):
        lib = self.lib(doc)
        sym = lib.linkage.get(sym, sym)
        n = lib.length(sym)
        base = (1, 0, 0, 1, 0, 0)
        ct0 = IDENT_CT
        if "color" in opts:
            rm, gm, bm, ro, go, bo = opts["color"]
            ct0 = (rm, gm, bm, 1, ro, go, bo, 0)
        imgs, img_index = [], {}
        uniq, uniq_index, seq = [], {}, []
        # Frames the root holds (stop() frames and the last one): movie clips
        # inside keep playing there, so `hold` extra frames are exported per hold.
        holds_at = sorted(set([n - 1] + [idx for layer in layers_all(lib, sym) for idx, _, fr in layer
                                          if fr.find(NS + "Actionscript") is not None
                                          and "stop()" in "".join(fr.find(NS + "Actionscript").itertext())
                                          and "if(" not in "".join(fr.find(NS + "Actionscript").itertext()).replace(" ", "")]))
        K = opts.get("hold", 0)
        plan = [(t, None) for t in range(n)]
        holds = {}
        if K:
            for hs in holds_at:
                holds[hs] = {"start": len(plan) + 1, "k": K, "once": bool(opts.get("hold_once"))}
                plan += [(hs, hs + 1 + h) for h in range(K)]
        for t, tt in plan:
            out = []
            self.walk(doc, sym, t, base, ct0, "", opts, out, 0, tt)
            frame = []
            for it in out:
                if isinstance(it, list):
                    entry, mm, a = it
                    if entry[0] not in img_index:
                        img_index[entry[0]] = len(imgs) + 1
                        imgs.append(list(entry))
                    frame.extend([img_index[entry[0]]] + mm + [a])
                else:
                    frame.append(it)
            key = repr(frame)
            if key not in uniq_index:
                uniq_index[key] = len(uniq) + 1
                uniq.append(frame)
            seq.append(uniq_index[key])
        labels, stops, complete, sounds = {}, {}, {}, {}
        for layer in layers_all(lib, sym):
            for idx, _, fr in layer:
                nm = fr.get("name")
                if nm and fr.get("labelType", "name") == "name" and nm != "stop":
                    labels.setdefault(nm, idx)
                sc = fr.find(NS + "Actionscript")
                if sc is not None:
                    src = "".join(sc.itertext())
                    if "stop()" in src and "if(" not in src.replace(" ", ""):
                        stops[idx] = True
                    if "Event.COMPLETE" in src:
                        complete[idx] = True
                if fr.get("soundName"):
                    clip = self.sound(doc, fr.get("soundName"))
                    if clip:
                        sounds[idx] = clip
        data = {"n": n, "holds": holds, "imgs": imgs, "frames": uniq, "seq": seq, "labels": labels, "stops": stops, "complete": complete,
                "sounds": sounds}
        DATA_UI.mkdir(parents=True, exist_ok=True)
        (DATA_UI / (name + ".lua")).write_text("-- Generated by tools/convert_ui.py from 5DPLAY's interface XFL. Do not edit.\nreturn %s\n"
                                               % lua_val4(data), encoding="utf-8")
        print("[ui] screen %s: %d frames, %d unique, %d images" % (name, n, len(uniq), len(imgs)), flush=True)


def lua_val4(v):
    """lua_val with 4-decimal numbers (matrices) and integer keys for sparse maps."""
    if isinstance(v, bool) or v is None or isinstance(v, str):
        return lua_val(v)
    if isinstance(v, float):
        r = round(v, 4)
        return str(int(r)) if r == int(r) else repr(r)
    if isinstance(v, int):
        return str(v)
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua_val4(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("[%s]=%s" % (lua_val4(k), lua_val4(x)) for k, x in v.items()) + "}"
    raise TypeError(type(v))


def export_font():
    """font1 (BitmapFontText): one image per glyph plus its metrics."""
    import xml.etree.ElementTree as ET
    from PIL import Image as _I
    out = ROOT / "images" / "bvn" / "ui" / "font1"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    root = ET.parse(FONT_DIR / "font1.xml").getroot()
    sheet = _I.open(FONT_DIR / "font1.png").convert("RGBA")
    chars = {}
    for c in root.iter("char"):
        cid, x, y, w, h = (int(c.get(k)) for k in ("id", "x", "y", "width", "height"))
        img = None
        if w > 0 and h > 0:
            sheet.crop((x, y, x + w, y + h)).save(out / ("c%d.png" % cid), optimize=True)
            img = "bvn/ui/font1/c%d.png" % cid
        chars[cid] = {"img": img, "xo": int(c.get("xoffset")), "yo": int(c.get("yoffset")), "adv": int(c.get("xadvance")), "w": w, "h": h}
    common = root.find("common")
    return {"lineHeight": int(common.get("lineHeight")), "chars": chars}


def export_select_layout():
    """select.xml's stage layout and per-cell offsets (SelectStageConfigVO)."""
    import xml.etree.ElementTree as ET
    root = ET.parse(SELECT_XML).getroot()
    lay = root.find("stage_setting").find("layout")
    layout = {k: float(lay.get(k, 0)) for k in ("x", "y", "width", "height", "top", "bottom", "left", "right")}

    def pt(s):
        if not s:
            return None
        a, b = s.split(",")
        return [float(a), float(b)]

    def lst(tag):
        node = root.find(tag)
        items, hcount, rows = [], 0, list(node.iter("row"))
        for y, row in enumerate(rows):
            roff = pt(row.get("offset"))
            cells = list(row.iter("item"))
            hcount = max(hcount, len(cells))
            for x, it in enumerate(cells):
                fid = (it.text or "").strip()
                if not fid:
                    continue
                off = list(roff) if roff else None
                o = pt(it.get("offset"))
                if o:
                    off = [off[0] + o[0], off[1] + o[1]] if off else o
                more = [s for s in (it.get("moreFighter") or "").split(",") if s]
                items.append({"x": x, "y": y, "id": fid, "offset": off or [0, 0], "more": more})
        return {"list": items, "HCount": hcount, "VCount": len(rows)}
    return {"layout": layout, "charList": lst("char_list"), "assistList": lst("assist_list")}


def export_screens(data):
    sc = Screens()
    for name, (doc, sym, opts) in SCREENS.items():
        sc.movie(name, doc, sym, opts)
    # Bitmaps the stages create directly.
    lib = sc.lib("loading")
    bg = lib.image("#链接/BM_coverBackGround")
    misc = ROOT / "images" / "bvn" / "ui" / "misc"
    shutil.rmtree(misc, ignore_errors=True)
    misc.mkdir(parents=True)
    if bg is not None:
        bg.save(misc / "cover_bg.png", optimize=True)
    for f in ("movelist.jpg", "cancel.png"):
        if (CORE_ASSETS / f).exists():
            shutil.copy(CORE_ASSETS / f, misc / f)
    # Characters of the movies' text, kept here so tools/make_assets.py --font
    # (which subsets fonts/bvn.ttf from component_types) includes them.
    data["text_chars"] = "".join(sorted(c for c in sc.chars if ord(c) > 0x7F))
    data["font1"] = export_font()
    data["select"] = export_select_layout()
    print("[ui] screens: %d skewed draws, %d unsupported shapes, masks ignored in %s"
          % (sc.stats["skew"], sc.stats["shapes_skipped"], ", ".join(sorted(sc.stats["masks"])) or "none"), flush=True)


if __name__ == "__main__":
    main()
