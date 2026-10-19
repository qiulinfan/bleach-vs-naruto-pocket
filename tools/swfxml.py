"""Read FFDec's swf2xml output: symbols, sprite timelines and display-list bounds.

Coordinates are pixels (twips / 20). A matrix is (a, b, c, d, tx, ty) with
x' = a*x + c*y + tx and y' = b*x + d*y + ty, as in Flash.
"""
import xml.etree.ElementTree as ET

IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
IDENTITY_CM = (1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
SHAPE_TAGS = {"DefineShapeTag", "DefineShape2Tag", "DefineShape3Tag", "DefineShape4Tag"}
PLACE_TAGS = {"PlaceObject2Tag", "PlaceObject3Tag"}
# Blend modes that light up what is under them (screen, lighten, add): the effects drawn on a black
# background. The engine draws them as an additive blend.
ADDITIVE_BLENDS = {"4", "5", "8"}
# Blend modes FFDec cannot flatten onto a transparent canvas (a black box) that the engine can
# approximate: "add" (above), "sub" (subtract: drawn as a multiply by the inverted image) and "mul"
# (multiply, darken: a multiply).
BLEND_KINDS = {"4": "add", "5": "add", "8": "add", "9": "sub", "3": "mul", "6": "mul"}


def additive(obj):
    return obj.get("blend") in ADDITIVE_BLENDS


def blend_kind(obj):
    """"add", "sub", "mul" or None for a placement."""
    return BLEND_KINDS.get(obj.get("blend"))


def parse_matrix(el):
    if el is None:
        return IDENTITY
    g = lambda k, d: float(el.get(k, d))
    a = g("scaleX", 1) if el.get("hasScale") == "true" else 1.0
    d = g("scaleY", 1) if el.get("hasScale") == "true" else 1.0
    b = g("rotateSkew0", 0) if el.get("hasRotate") == "true" else 0.0
    c = g("rotateSkew1", 0) if el.get("hasRotate") == "true" else 0.0
    return (a, b, c, d, g("translateX", 0) / 20, g("translateY", 0) / 20)


def mul(m, n):
    """m applied after n."""
    a, b, c, d, tx, ty = m
    e, f, g, h, ux, uy = n
    return (a * e + c * f, b * e + d * f, a * g + c * h, b * g + d * h, a * ux + c * uy + tx, b * ux + d * uy + ty)


def transform_rect(m, r):
    if r is None:
        return None
    x0, y0, x1, y1 = r
    a, b, c, d, tx, ty = m
    xs, ys = [], []
    for x, y in ((x0, y0), (x1, y0), (x0, y1), (x1, y1)):
        xs.append(a * x + c * y + tx)
        ys.append(b * x + d * y + ty)
    return (min(xs), min(ys), max(xs), max(ys))


def union(r, s):
    if r is None:
        return s
    if s is None:
        return r
    return (min(r[0], s[0]), min(r[1], s[1]), max(r[2], s[2]), max(r[3], s[3]))


def rect_of(el):
    if el is None:
        return None
    return (int(el.get("Xmin")) / 20, int(el.get("Ymin")) / 20, int(el.get("Xmax")) / 20, int(el.get("Ymax")) / 20)


class Swf:
    def __init__(self, path):
        self.root = ET.parse(path).getroot()
        self.tags = list(self.root.find("tags"))
        self.shapes, self.sprites, self.sounds, self.bitmaps = {}, {}, {}, {}
        self.classes = {}
        self.other_bounds = {}
        for t in self.tags:
            ty = t.get("type")
            if ty in SHAPE_TAGS:
                self.shapes[t.get("shapeId")] = rect_of(t.find("shapeBounds"))
            elif ty == "DefineSpriteTag":
                self.sprites[t.get("spriteId")] = t
            elif ty == "DefineSoundTag":
                self.sounds[t.get("soundId")] = t
            elif ty and ty.startswith("DefineBits"):
                self.bitmaps[t.get("characterID") or t.get("characterId")] = t
            elif ty in ("DefineMorphShapeTag", "DefineMorphShape2Tag"):
                self.other_bounds[t.get("characterId")] = union(rect_of(t.find("startBounds")), rect_of(t.find("endBounds")))
            elif ty == "DefineEditTextTag":
                self.other_bounds[t.get("characterID")] = rect_of(t.find("bounds"))
            elif ty == "DefineTextTag":
                self.other_bounds[t.get("characterID")] = rect_of(t.find("textBounds"))
            elif ty == "SymbolClassTag":
                for i, n in zip(t.find("tags"), t.find("names")):
                    self.classes[n.text] = i.text
        self.id_class = {v: k for k, v in self.classes.items()}
        self._bounds = {}
        self._timelines = {}

    def frame_count(self, sid):
        return int(self.sprites[sid].get("frameCount"))

    def timeline(self, sid):
        """Per frame: (display list {depth: obj}, label or None, [sound ids])."""
        if sid in self._timelines:
            return self._timelines[sid]
        frames, dl, label, sounds = [], {}, None, []
        for t in self.sprites[sid].find("subTags"):
            ty = t.get("type")
            if ty in PLACE_TAGS:
                depth = int(t.get("depth"))
                has_char = t.get("placeFlagHasCharacter") == "true"
                move = t.get("placeFlagMove") == "true"
                old = dl.get(depth)
                # Flash ignores a new placement on an occupied depth (obfuscators add such
                # decoys, sometimes pointing at the sprite itself).
                if has_char and not move and old is not None:
                    continue
                if has_char and t.get("characterId") == sid:
                    continue
                if has_char:
                    obj = dict(old) if (move and old) else {}
                    obj["cid"] = t.get("characterId")
                    if not move or not old:
                        obj = {"cid": t.get("characterId"), "m": IDENTITY, "name": None, "alpha": 1.0, "blend": "1"}
                    # A new display object instance (a replaced character also restarts its timeline).
                    self._serial = getattr(self, "_serial", 0) + 1
                    obj["serial"] = self._serial
                elif old:
                    obj = dict(old)
                else:
                    continue
                if t.get("placeFlagHasMatrix") == "true":
                    obj["m"] = parse_matrix(t.find("matrix"))
                if t.get("placeFlagHasName") == "true":
                    obj["name"] = t.get("name")
                if t.get("placeFlagHasBlendMode") == "true":
                    obj["blend"] = t.get("blendMode") or "1"   # SWF BlendMode: 4 screen, 5 lighten, 8 add, ...
                if t.get("placeFlagHasClipDepth") == "true":
                    obj["clip"] = int(t.get("clipDepth"))   # a mask over the depths up to it
                if t.get("placeFlagHasColorTransform") == "true":
                    cx = t.find("colorTransform")
                    mult = cx is not None and cx.get("hasMultTerms") == "true"
                    add = cx is not None and cx.get("hasAddTerms") == "true"
                    obj["alpha"] = int(cx.get("alphaMultTerm", 256)) / 256 if mult else 1.0
                    # The colour part: multipliers (0..1) and offsets (-255..255) of red, green, blue.
                    ct = tuple([int(cx.get(k + "MultTerm", 256)) / 256 if mult else 1.0 for k in ("red", "green", "blue")] +
                               [int(cx.get(k + "AddTerm", 0)) if add else 0 for k in ("red", "green", "blue")])
                    obj["ct"] = None if ct == (1.0, 1.0, 1.0, 0, 0, 0) else ct
                if t.get("placeFlagHasFilterList") == "true":
                    # A colour matrix filter (4 x 5, offsets in 0..255); identity ones are left out.
                    obj["cm"] = None
                    for f in t.iter("item"):
                        if f.get("type") == "COLORMATRIXFILTER" and f.find("matrix") is not None:
                            m = tuple(round(float(v.text), 4) for v in f.find("matrix"))
                            if len(m) == 20 and m != IDENTITY_CM:
                                obj["cm"] = m
                dl[depth] = obj
            elif ty == "RemoveObject2Tag" or ty == "RemoveObjectTag":
                dl.pop(int(t.get("depth")), None)
            elif ty == "FrameLabelTag":
                label = t.get("name")
            elif ty == "StartSoundTag" or ty == "StartSound2Tag":
                sounds.append(t.get("soundId"))
            elif ty == "ShowFrameTag":
                frames.append(({d: dict(o) for d, o in dl.items()}, label, sounds))
                label, sounds = None, []
        self._timelines[sid] = frames
        return frames

    def bounds(self, cid, depth=0):
        """Local bounds of a character (a sprite: union over all its frames)."""
        if cid in self._bounds:
            return self._bounds[cid]
        r = None
        if cid in self.shapes:
            r = self.shapes[cid]
        elif cid in self.other_bounds:
            r = self.other_bounds[cid]
        elif cid in self.sprites and depth < 12:
            self._bounds[cid] = None
            for dl, _, _ in self.timeline(cid):
                for obj in dl.values():
                    r = union(r, transform_rect(obj["m"], self.bounds(obj["cid"], depth + 1)))
        self._bounds[cid] = r
        return r

    def frame1_bounds(self, cid):
        """Bounds of a child as shown on its first frame (hit and body areas)."""
        if cid in self.sprites:
            tl = self.timeline(cid)
            r = None
            if tl:
                for obj in tl[0][0].values():
                    r = union(r, transform_rect(obj["m"], self.bounds(obj["cid"])))
            return r
        return self.bounds(cid)
