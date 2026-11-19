#!/usr/bin/env python3
"""Writes the highway's white art to src/Encore/Textures (run from the repo root).

Every texture is white with an anti-aliased alpha, so the style tints it with SetVertexColor:
  HighwayRing1..3  the hit ring, thin, medium and thick (128 x 128)
  HighwayHalo      a soft round glow for the halo glow and the ring's flash (128 x 128)
  HighwayDot       a small disc for the tracked spell's half circle (32 x 32)

Deterministic: the same bytes on every run. Needs Pillow.
"""
import math
import os
import sys

from PIL import Image

OUT = os.path.join("src", "Encore", "Textures")
SS = 4  # supersampling per axis for the anti-aliasing


def coverage(size, inside):
    """An L-mode alpha of `size` px: per pixel the fraction of SS x SS samples where inside(x, y) holds,
    x and y in -1 .. 1 from the centre."""
    img = Image.new("L", (size, size))
    px = img.load()
    n = SS * SS
    for j in range(size):
        for i in range(size):
            hit = 0
            for sj in range(SS):
                for si in range(SS):
                    x = ((i + (si + 0.5) / SS) / size) * 2 - 1
                    y = ((j + (sj + 0.5) / SS) / size) * 2 - 1
                    if inside(x, y):
                        hit += 1
            px[i, j] = round(255 * hit / n)
    return img


def white(alpha):
    size = alpha.size
    img = Image.new("RGBA", size, (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


def ring(width):
    """A ring touching the texture's edge, `width` of the radius thick."""
    outer, inner = 1 - 1 / 128, 1 - 1 / 128 - width

    def inside(x, y):
        r = math.hypot(x, y)
        return inner <= r <= outer

    return white(coverage(128, inside))


def halo():
    size = 128
    img = Image.new("L", (size, size))
    px = img.load()
    for j in range(size):
        for i in range(size):
            x = ((i + 0.5) / size) * 2 - 1
            y = ((j + 0.5) / size) * 2 - 1
            r = math.hypot(x, y)
            a = 0.0 if r >= 1 else (1 - r) ** 1.6
            px[i, j] = round(255 * a)
    return white(img)


def dot():
    return white(coverage(32, lambda x, y: math.hypot(x, y) <= 1 - 1 / 32))


def main():
    if not os.path.isdir(OUT):
        sys.exit("run from the repo root: %s not found" % OUT)
    art = {
        "HighwayRing1": ring(0.08),
        "HighwayRing2": ring(0.14),
        "HighwayRing3": ring(0.22),
        "HighwayHalo": halo(),
        "HighwayDot": dot(),
    }
    for name, img in art.items():
        path = os.path.join(OUT, name + ".tga")
        img.save(path, format="TGA", compression=None)
        print("wrote", path, img.size)


if __name__ == "__main__":
    main()
