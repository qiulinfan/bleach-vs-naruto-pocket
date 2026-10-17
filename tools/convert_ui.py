#!/usr/bin/env python3
"""Export 5DPLAY's interface symbols (fight HUD, ...) from the FlashSrc XFL as
part trees the game composes at run time.

A tree is a list of parts in drawing order: a static image {img, x, y}, or a
named child {name, m = {a, b, c, d, tx, ty}, parts | frames}. Named children
are what the original FightUI code drives (bar scale, digits, faces), so they
stay separate. Writes images/bvn/ui/<doc>/*.png and generated/BVNUIData.lua.
"""
import hashlib
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_bvn import ROOT, lua_val  # noqa: E402
from xfl import NS, Library, alpha_of, composite, lerp_m, matrix, mul  # noqa: E402

UI = ROOT / "external" / "FlashSrc" / "SRC_XFL" / "ui"
# Symbols exported per document, at a frame number, a frame label, or every frame ("all").
EXPORTS = {
    "fight": {"$fight$MC_hpBar": "fadin_fin", "$fight$MC_qiBar": "fadin_fin", "$fight$MC_hits": 0, "$fight$MC_timeNumber": "all",
              "$fight$MC_hitsNumer": "all", "$fight$MC_win": 0, "$fight$MC_fightUI": 0},
}
# Whole symbols exported as flattened animations with their frame labels.
ANIMS = {"fight": ["game_start_mc"]}
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

    def save(self, im):
        key = hashlib.sha1(im.tobytes() + bytes(str(im.size), "ascii")).hexdigest()
        if key not in self.seen:
            name = "p%d.png" % (len(self.seen) + 1)
            im.save(self.out / name, optimize=True)
            self.seen[key] = name
        return "bvn/ui/%s/%s" % (self.doc, self.seen[key])

    def tree(self, sym, t, depth=0):
        lib = self.lib
        parts, batch = [], []

        def flush():
            if batch:
                im, x0, y0 = composite(batch)
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
                for i, el in enumerate(els):
                    em = matrix(el)
                    if tween:
                        nels = lib.elements(nxt[2])
                        if i < len(nels):
                            em = lerp_m(em, matrix(nels[i]), (t - idx) / dur)
                    name = el.get("name")
                    child = el.get("libraryItemName")
                    if name and el.tag == NS + "DOMSymbolInstance" and child in lib.symbols and depth < 6:
                        flush()
                        node = {"name": name, "m": [round(v, 4) for v in em], "alpha": alpha_of(el)}
                        n = lib.length(child)
                        settled = self.label(child, "fadin_fin")
                        if child in MULTI or (settled is None and 1 < n <= 12):
                            node["frames"] = [self.tree(child, f, depth + 1) for f in range(n)]
                        else:
                            node["parts"] = self.tree(child, settled or 0, depth + 1)
                        parts.append(node)
                    else:
                        # Static content: flatten into the current image batch.
                        tmp = {"tag": el.tag}
                        batch.extend(self.flatten(el, em, t - idx))
                break
        flush()
        return parts

    def label(self, sym, name):
        for layer in self.lib.layers_all(sym):
            for idx, _, fr in layer:
                if fr.get("name") == name:
                    return idx
        return None

    def flatten(self, el, m, rel):
        lib = self.lib
        tag = el.tag[len(NS):]
        a = alpha_of(el)
        if tag == "DOMBitmapInstance":
            img = lib.image(el.get("libraryItemName"))
            return [(img, m, a)] if img is not None else []
        if tag == "DOMShape":
            fill = el.find(".//" + NS + "BitmapFill")
            if fill is not None:
                img = lib.image(fill.get("bitmapPath"))
                fm = matrix(fill)
                fm = (fm[0] / 20, fm[1] / 20, fm[2] / 20, fm[3] / 20, fm[4], fm[5])
                return [(img, mul(m, fm), a)] if img is not None else []
            return []
        child = el.get("libraryItemName")
        if child not in lib.symbols:
            return []
        n = lib.length(child)
        first = int(el.get("firstFrame", 0))
        loop = el.get("loop", "loop")
        if el.get("symbolType") == "graphic":
            ct = first if loop == "single frame" else (min(n - 1, first + rel) if loop == "play once" else (first + rel) % n)
        else:
            ct = 0
        return lib.draw_list(child, ct, m, a)


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
                    frame = next((idx for layer in ex.lib.layers_all(sym) for idx, _, fr in layer if fr.get("name") == frame), 0)
                data[cls] = {"parts": ex.tree(sym, frame)}
            print("[ui] %s %s: %d frames" % (doc, cls, n), flush=True)
    anims = {}
    for doc, syms in ANIMS.items():
        ex = Exporter(doc + "_anim")
        ex.lib = Library(UI / doc)
        for sym in syms:
            n = ex.lib.length(sym)

            def render_all():
                frames = []
                for t in range(n):
                    im, x0, y0 = composite(ex.lib.draw_list(sym, t, (1, 0, 0, 1, 0, 0), 1.0))
                    if im is None or not im.getbbox():
                        frames.append({})
                        continue
                    bb = im.getbbox()
                    frames.append({"img": ex.save(im.crop(bb)), "x": x0 + bb[0], "y": y0 + bb[1]})
                return frames
            # The round banner's digit (nummc) is set by script from $round.
            rounds = []
            for r in range(1, 6):
                ex.lib.frame_override = {"nummc": r - 1}
                rounds.append(render_all())
            ex.lib.frame_override = {}
            frames = rounds[0]
            labels = {}
            for layer in ex.lib.layers_all(sym):
                for idx, _, fr in layer:
                    nm = fr.get("name")
                    if nm and fr.get("labelType", "name") == "name" and nm not in labels:
                        labels[nm] = idx + 1
            anims[sym] = {"frames": frames, "labels": labels, "rounds": rounds}
            print("[ui] anim %s: %d frames" % (sym, n), flush=True)
    data["anims"] = anims
    gen = ROOT / "component_types" / "generated"
    (gen / "BVNUIData.lua").write_text("-- Generated by tools/convert_ui.py from 5DPLAY's interface XFL. Do not edit.\nBVNUIData = %s\n"
                                       % lua_val(data), encoding="utf-8")


if __name__ == "__main__":
    main()
