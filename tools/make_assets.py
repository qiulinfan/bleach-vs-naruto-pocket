#!/usr/bin/env python3
"""Build BleachVsNaruto's generated assets.

fonts/bvn.ttf: Noto Sans CJK SC (SIL OFL 1.1) cut down to ASCII plus every
non-ASCII character in component_types/*.lua. Rerun after adding new text:
    tools/make_assets.py --font /path/to/NotoSansCJKsc-Regular.otf
audio/*.wav: short synthesized sound effects (no source files needed).
"""
import argparse
import math
import random
import struct
import subprocess
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RATE = 22050


def subset_font(source: Path) -> None:
    text = "".join(p.read_text(encoding="utf-8") for p in sorted((ROOT / "component_types").glob("*.lua")))
    chars = sorted({c for c in text if ord(c) > 0x7F} | {chr(c) for c in range(0x20, 0x7F)})
    subprocess.run(
        ["pyftsubset", str(source), "--text=" + "".join(chars), "--output-file=" + str(ROOT / "fonts" / "bvn.ttf"),
         "--layout-features=*", "--no-hinting"],
        check=True,
    )
    print(f"fonts/bvn.ttf: {len(chars)} characters")


def write(name: str, samples: list[float]) -> None:
    peak = max(1e-6, max(abs(s) for s in samples))
    with wave.open(str(ROOT / "audio" / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(s / peak * 0.8 * 32767)) for s in samples))


def tone(seconds, f0, f1, noise=0.0, decay=6.0, square=False, seed=1):
    rng = random.Random(seed)
    n = int(seconds * RATE)
    out, phase = [], 0.0
    for i in range(n):
        t = i / n
        phase += 2 * math.pi * (f0 + (f1 - f0) * t) / RATE
        v = math.sin(phase)
        if square:
            v = 1.0 if v > 0 else -1.0
        v = v * (1 - noise) + (rng.random() * 2 - 1) * noise
        out.append(v * math.exp(-decay * t) * min(1.0, i / 60))
    return out


def sounds() -> None:
    (ROOT / "audio").mkdir(exist_ok=True)
    write("hit", tone(0.12, 220, 80, noise=0.6, decay=8))
    write("heavy", tone(0.25, 140, 40, noise=0.55, decay=6, seed=2))
    write("block", tone(0.1, 900, 600, noise=0.3, decay=10, square=True, seed=3))
    write("slash", tone(0.14, 1800, 400, noise=0.8, decay=7, seed=4))
    write("whoosh", tone(0.16, 600, 200, noise=0.9, decay=5, seed=5))
    write("beam", tone(0.45, 300, 900, noise=0.35, decay=3, seed=6))
    write("ice", tone(0.35, 2200, 1500, noise=0.4, decay=4, seed=7))
    write("fire", tone(0.6, 120, 60, noise=0.85, decay=2.5, seed=8))
    write("thunder", tone(0.8, 90, 40, noise=0.9, decay=2, seed=9))
    write("ult", tone(0.6, 200, 1200, noise=0.2, decay=1.5, square=True, seed=10))
    write("ko", tone(0.9, 300, 60, noise=0.3, decay=2, seed=11))
    write("land", tone(0.12, 120, 50, noise=0.7, decay=9, seed=12))
    write("select", tone(0.06, 880, 880, decay=8, square=True))
    write("confirm", tone(0.18, 660, 1320, decay=5, square=True))
    print("audio/*.wav written")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", type=Path, help="Noto Sans CJK SC .otf to subset into fonts/bvn.ttf")
    parser.add_argument("--no-sounds", action="store_true")
    args = parser.parse_args()
    if args.font:
        subset_font(args.font)
    if not args.no_sounds:
        sounds()
