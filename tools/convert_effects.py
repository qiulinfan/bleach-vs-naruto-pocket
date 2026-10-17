#!/usr/bin/env python3
"""Render 5DPLAY's shared effect library (hit sparks, dust, cut-in, ...) from the
FlashSrc effect XFL into frames, and copy its linked sounds.

Writes (ignored by Git):
  images/bvn/fx/<class>_<n>.png
  audio/bvn/fx/<class>.<ext>
  component_types/generated/BVNFxData.lua   {effects = {[class] = {frames, add}}, sounds = {[class] = clip}}
Effects whose EffectVO uses an additive blend are stored with alpha taken from
brightness, which approximates additive blending under normal alpha blending.
"""
import hashlib
import math
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_bvn import ROOT, lua_val  # noqa: E402

XFL = ROOT / "external" / "FlashSrc" / "SRC_XFL" / "effect"
NS = "{http://ns.adobe.com/xfl/2008/}"
ADDITIVE = {"XG_bs", "XG_cbs", "XG_jump_air", "xg_hitfloor_yan", "XG_mfdjx", "XG_ghost_step", "xg_mc_change", "XG_kan2",
            "XG_kanx2", "XG_qdj", "XG_qdjx", "XG_mfdj", "XG_fire", "XG_ice", "XG_leidian", "XG_fykan", "XG_fykanx", "XG_fyq",
            "XG_fyqx", "XG_mffy", "XG_mffyx", "XG_fire_fy", "XG_ice_fy", "XG_dian_fy", "XG_kan", "XG_kanx", "XG_bdj"}


def matrix(el):
    m = el.find(NS + "matrix") if el is not None else None
    m = m.find(NS + "Matrix") if m is not None else None
    if m is None:
        return (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    g = lambda k, d: float(m.get(k, d))
    return (g("a", 1), g("b", 0), g("c", 0), g("d", 1), g("tx", 0), g("ty", 0))


def mul(m, n):
    a, b, c, d, tx, ty = m
    e, f, g, h, ux, uy = n
    return (a * e + c * f, b * e + d * f, a * g + c * h, b * g + d * h, a * ux + c * uy + tx, b * ux + d * uy + ty)


def alpha_of(el):
    col = el.find(NS + "color")
    col = col.find(NS + "Color") if col is not None else None
    if col is None:
        return 1.0
    return float(col.get("alphaMultiplier", 1))


def lerp_m(m0, m1, t):
    return tuple(a + (b - a) * t for a, b in zip(m0, m1))


def decode_dat_bitmap(path):
    """XFL bin/*.dat bitmap: 0x0305 lossless (zlib-chunked premultiplied ARGB) or a JPEG."""
    import struct
    import zlib
    data = path.read_bytes()
    if data[:2] == b"\xff\xd8":
        import io
        return Image.open(io.BytesIO(data)).convert("RGBA")
    def chunks_from(pos):
        out = []
        while pos + 2 <= len(data):
            n = struct.unpack_from("<H", data, pos)[0]
            pos += 2
            if n == 0:
                break
            out.append(data[pos:pos + n])
            pos += n
        return zlib.decompress(b"".join(out))

    if data[:2] == b"\x03\x03":
        # 8-bit palette: RGBA entries from offset 28, then zlib chunks of indices.
        stride, w, h = struct.unpack_from("<HHH", data, 2)
        for k in range(28, min(len(data) - 3, 28 + 4 * 257), 4):
            if data[k + 2] == 0x78:
                try:
                    raw = chunks_from(k)
                except zlib.error:
                    continue
                pal = [tuple(data[28 + i * 4:32 + i * 4]) for i in range((k - 28) // 4)]
                im = Image.new("RGBA", (w, h))
                im.putdata([pal[v] if v < len(pal) else (0, 0, 0, 0) for row in range(h) for v in raw[row * stride:row * stride + w]])
                return im
        return None
    if data[:2] != b"\x03\x05":
        return None
    stride, w, h = struct.unpack_from("<HHH", data, 2)
    pos = 8 + 16
    has_alpha, compressed = data[pos], data[pos + 1]
    pos += 2
    if compressed:
        chunks = []
        while pos + 2 <= len(data):
            n = struct.unpack_from("<H", data, pos)[0]
            pos += 2
            if n == 0:
                break
            chunks.append(data[pos:pos + n])
            pos += n
        raw = zlib.decompress(b"".join(chunks))
    else:
        raw = data[pos:]
    im = Image.frombuffer("RGBA", (w, h), raw, "raw", "ARGB", stride, 1).copy()
    # Un-premultiply.
    px = im.load()
    for y in range(h):
        for x in range(w):
            r, g, bl, a = px[x, y]
            if 0 < a < 255:
                px[x, y] = (min(255, r * 255 // a), min(255, g * 255 // a), min(255, bl * 255 // a), a)
    if not has_alpha:
        im.putalpha(255)
    return im


def write_dat_sound(item, out):
    """XFL bin/*.dat sound: raw PCM described by the item's format ("22kHz 16bit Stereo")."""
    import wave
    fmt = item.get("format", "22kHz 16bit Mono")
    rate = {"5kHz": 5512, "11kHz": 11025, "22kHz": 22050, "44kHz": 44100}.get(fmt.split()[0], 22050)
    bits = 16 if "16bit" in fmt else 8
    ch = 2 if "Stereo" in fmt else 1
    data = (XFL / "bin" / item.get("soundDataHRef")).read_bytes()
    with wave.open(str(out), "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(bits // 8)
        w.setframerate(rate)
        w.writeframes(data)


class Library:
    def __init__(self):
        doc = ET.parse(XFL / "DOMDocument.xml").getroot()
        self.bitmaps, self.symbols, self.sounds = {}, {}, {}
        self.dat = {}
        for it in doc.iter(NS + "DOMBitmapItem"):
            self.bitmaps[it.get("name")] = XFL / "LIBRARY" / it.get("href")
            if it.get("bitmapDataHRef"):
                self.dat[it.get("name")] = XFL / "bin" / it.get("bitmapDataHRef")
        self.sound_items = {}
        for it in doc.iter(NS + "DOMSoundItem"):
            if it.get("linkageClassName"):
                self.sounds[it.get("linkageClassName")] = XFL / "LIBRARY" / it.get("href")
                self.sound_items[it.get("linkageClassName")] = it
        self.linkage = {}
        for inc in doc.iter(NS + "Include"):
            href = inc.get("href")
            path = XFL / "LIBRARY" / href
            if not path.exists():
                continue
            root = ET.parse(path).getroot()
            name = root.get("name")
            self.symbols[name] = root
            if root.get("linkageClassName"):
                self.linkage[root.get("linkageClassName")] = name
        self._img = {}
        self._len = {}

    def image(self, name):
        if name not in self._img:
            p = self.bitmaps.get(name)
            if p and p.exists():
                self._img[name] = Image.open(p).convert("RGBA")
            elif name in self.dat and self.dat[name].exists():
                self._img[name] = decode_dat_bitmap(self.dat[name])
            else:
                self._img[name] = None
        return self._img[name]

    def layers(self, sym):
        tl = self.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
        out = []
        for layer in tl.find(NS + "layers").findall(NS + "DOMLayer"):
            if layer.get("layerType") in ("guide", "folder", "mask"):
                continue
            frames = []
            for fr in layer.find(NS + "frames").findall(NS + "DOMFrame"):
                frames.append((int(fr.get("index")), int(fr.get("duration", 1)), fr))
            out.append(frames)
        return out

    def length(self, sym):
        if sym not in self._len:
            n = 1
            for frames in self.layers(sym):
                for idx, dur, _ in frames:
                    n = max(n, idx + dur)
            self._len[sym] = n
        return self._len[sym]

    def elements(self, fr):
        els = fr.find(NS + "elements")
        out = []
        if els is None:
            return out
        for el in els:
            tag = el.tag[len(NS):]
            if tag == "DOMGroup":
                out += self.elements_group(el)
            elif tag in ("DOMBitmapInstance", "DOMSymbolInstance", "DOMShape"):
                out.append(el)
        return out

    def elements_group(self, g):
        out = []
        members = g.find(NS + "members")
        for el in (members if members is not None else []):
            tag = el.tag[len(NS):]
            if tag in ("DOMBitmapInstance", "DOMSymbolInstance", "DOMShape"):
                out.append(el)
        return out

    def draw_list(self, sym, t, m, alpha, depth=0):
        """Bitmaps (image, matrix, alpha) visible on frame t (0-based) of symbol sym, bottom first."""
        out = []
        if depth > 12:
            return out
        layers = self.layers(sym)
        for frames in reversed(layers):  # XFL lists the top layer first
            for k, (idx, dur, fr) in enumerate(frames):
                if not (idx <= t < idx + dur):
                    continue
                els = self.elements(fr)
                nxt = frames[k + 1] if k + 1 < len(frames) else None
                tween = fr.get("tweenType") == "motion" and nxt is not None and dur > 0
                for i, el in enumerate(els):
                    em, ea = matrix(el), alpha_of(el)
                    if tween:
                        nels = self.elements(nxt[2])
                        if i < len(nels):
                            f = (t - idx) / dur
                            em = lerp_m(em, matrix(nels[i]), f)
                            ea = ea + (alpha_of(nels[i]) - ea) * f
                    mm = mul(m, em)
                    tag = el.tag[len(NS):]
                    if tag == "DOMShape":
                        # Decompiled shapes: a rectangle filled with one bitmap (fill matrix in twips).
                        fill = el.find(".//" + NS + "BitmapFill")
                        if fill is not None:
                            img = self.image(fill.get("bitmapPath"))
                            fm = matrix(fill)
                            fm = (fm[0] / 20, fm[1] / 20, fm[2] / 20, fm[3] / 20, fm[4] / 20, fm[5] / 20)
                            if img is not None:
                                out.append((img, mul(mm, fm), alpha * ea))
                        continue
                    if tag == "DOMBitmapInstance":
                        img = self.image(el.get("libraryItemName"))
                        if img is not None:
                            out.append((img, mm, alpha * ea))
                    else:
                        child = el.get("libraryItemName")
                        if child not in self.symbols:
                            continue
                        n = self.length(child)
                        first = int(el.get("firstFrame", 0))
                        loop = el.get("loop", "loop")
                        rel = t - idx
                        if el.get("symbolType") == "graphic":
                            if loop == "single frame":
                                ct = first
                            elif loop == "play once":
                                ct = min(n - 1, first + rel)
                            else:
                                ct = (first + rel) % n
                        else:
                            ct = rel % n
                        out += self.draw_list(child, ct, mm, alpha * ea, depth + 1)
                break
        return out


def composite(items):
    boxes = []
    for img, m, _ in items:
        w, h = img.size
        a, b, c, d, tx, ty = m
        xs = [a * x + c * y + tx for x, y in ((0, 0), (w, 0), (0, h), (w, h))]
        ys = [b * x + d * y + ty for x, y in ((0, 0), (w, 0), (0, h), (w, h))]
        boxes.append((min(xs), min(ys), max(xs), max(ys)))
    if not boxes:
        return None, 0, 0
    x0 = math.floor(min(b[0] for b in boxes))
    y0 = math.floor(min(b[1] for b in boxes))
    x1 = math.ceil(max(b[2] for b in boxes))
    y1 = math.ceil(max(b[3] for b in boxes))
    W, H = max(1, x1 - x0), max(1, y1 - y0)
    if W * H > 4000 * 4000:
        return None, 0, 0
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for img, m, alpha in items:
        a, b, c, d, tx, ty = m
        det = a * d - b * c
        if abs(det) < 1e-9:
            continue
        # Inverse map: canvas pixel -> source pixel.
        ia, ib, ic, id_ = d / det, -b / det, -c / det, a / det
        ox, oy = tx - x0, ty - y0
        coeffs = (ia, ic, -(ia * ox + ic * oy), ib, id_, -(ib * ox + id_ * oy))
        layer = img.transform((W, H), Image.AFFINE, coeffs, resample=Image.BILINEAR)
        if alpha < 1:
            r, g, bl, al = layer.split()
            al = al.point(lambda v: int(v * alpha))
            layer = Image.merge("RGBA", (r, g, bl, al))
        canvas = Image.alpha_composite(canvas, layer)
    return canvas, x0, y0


def to_additive(im):
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            r, g, b = r * a // 255, g * a // 255, b * a // 255
            A = max(r, g, b)
            if A == 0:
                px[x, y] = (0, 0, 0, 0)
            else:
                px[x, y] = (r * 255 // A, g * 255 // A, b * 255 // A, A)
    return im


def main():
    lib = Library()
    out_dir = ROOT / "images" / "bvn" / "fx"
    snd_dir = ROOT / "audio" / "bvn" / "fx"
    shutil.rmtree(out_dir, ignore_errors=True)
    shutil.rmtree(snd_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    snd_dir.mkdir(parents=True)
    effects = {}
    for cls, sym in sorted(lib.linkage.items()):
        n = lib.length(sym)
        frames, seen = [], {}
        add = cls in ADDITIVE
        for t in range(n):
            im, x0, y0 = composite(lib.draw_list(sym, t, (1, 0, 0, 1, 0, 0), 1.0))
            if im is None or im.getbbox() is None:
                frames.append({})
                continue
            bb = im.getbbox()
            im = im.crop(bb)
            if add:
                im = to_additive(im)
            key = hashlib.sha1(im.tobytes() + bytes(str(im.size), "ascii")).hexdigest()
            if key not in seen:
                name = "%s_%d.png" % (re.sub(r"\W", "_", cls), len(seen) + 1)
                im.save(out_dir / name, optimize=True)
                seen[key] = name
            frames.append({"img": "bvn/fx/" + seen[key], "x": x0 + bb[0], "y": y0 + bb[1], "w": im.width, "h": im.height})
        effects[cls] = {"frames": frames, "add": add}
        print("[fx] %s: %d frames, %d images" % (cls, n, len(seen)), flush=True)
    sounds = {}
    for cls, path in lib.sounds.items():
        if path.exists():
            shutil.copy(path, snd_dir / (cls + path.suffix.lower()))
            sounds[cls] = "bvn/fx/" + cls
        elif lib.sound_items[cls].get("soundDataHRef"):
            write_dat_sound(lib.sound_items[cls], snd_dir / (cls + ".wav"))
            sounds[cls] = "bvn/fx/" + cls
    gen = ROOT / "component_types" / "generated"
    gen.mkdir(parents=True, exist_ok=True)
    (gen / "BVNFxData.lua").write_text("-- Generated by tools/convert_effects.py from 5DPLAY's effect library. Do not edit.\n"
                                       "BVNFxData = %s\n" % lua_val({"effects": effects, "sounds": sounds}), encoding="utf-8")
    print("effects %d, sounds %d" % (len(effects), len(sounds)))


if __name__ == "__main__":
    main()
