"""Read Adobe Animate XFL documents (5DPLAY's FlashSrc): symbol timelines,
bitmap and symbol instances, decompiled bitmap-fill shapes, classic tweens and
alpha, plus decoders for bin/*.dat bitmaps (0x0305 ARGB, 0x0303 palette) and
raw PCM sounds. `composite` renders a draw list to one image.
"""
import math
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

NS = "{http://ns.adobe.com/xfl/2008/}"
XFL = None


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
    def __init__(self, xfl):
        global XFL
        XFL = xfl
        self.root = xfl
        doc = ET.parse(xfl / "DOMDocument.xml").getroot()
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

    def layers_all(self, sym):
        """Every layer's frames, guides included (labels often sit on guide layers)."""
        tl = self.symbols[sym].find(NS + "timeline").find(NS + "DOMTimeline")
        return [[(int(fr.get("index")), int(fr.get("duration", 1)), fr) for fr in layer.find(NS + "frames").findall(NS + "DOMFrame")]
                for layer in tl.find(NS + "layers").findall(NS + "DOMLayer")]

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

    frame_override = {}

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
                        # Bitmap-filled shapes: the fill matrix scales by 20 (twips) but translates in pixels.
                        fill = el.find(".//" + NS + "BitmapFill")
                        if fill is not None:
                            img = self.image(fill.get("bitmapPath"))
                            fm = matrix(fill)
                            fm = (fm[0] / 20, fm[1] / 20, fm[2] / 20, fm[3] / 20, fm[4], fm[5])
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
                        if el.get("name") in self.frame_override:
                            ct = min(n - 1, self.frame_override[el.get("name")])
                        elif el.get("symbolType") == "graphic":
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


