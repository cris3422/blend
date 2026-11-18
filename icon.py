# Blend's icon: two waveforms, ember (deck A) and blue (deck B), crossing on dark glass. Writes build/AppIcon.icns.
import os, math, subprocess
from PIL import Image, ImageDraw, ImageFilter
HERE = os.path.dirname(os.path.abspath(__file__)); BUILD = os.path.join(HERE, "build"); os.makedirs(BUILD, exist_ok=True)
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0)); ImageDraw.Draw(sh).rounded_rectangle((100, 118, 924, 942), 190, fill=(0, 0, 0, 120))
img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(24)))
d = ImageDraw.Draw(img); d.rounded_rectangle((100, 100, 924, 924), 190, fill=(22, 21, 20, 255))
d.rounded_rectangle((100, 100, 924, 924), 190, outline=(255, 255, 255, 40), width=4)
def wave(col, phase, yc):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
    for i in range(36):
        x = 200 + i * 18
        a = 0.25 + 0.75 * abs(math.sin(i * 0.37 + phase)) * (0.6 + 0.4 * math.sin(i * 0.11 + phase * 2))
        h = 190 * a
        ld.rounded_rectangle((x, yc - h, x + 10, yc + h), 5, fill=col)
    return layer
img.alpha_composite(wave((245, 130, 46, 235), 0.0, 430))
img.alpha_composite(wave((90, 176, 255, 210), 1.7, 600))
p = os.path.join(BUILD, "icon.iconset"); os.makedirs(p, exist_ok=True)
for s in [16, 32, 64, 128, 256, 512, 1024]:
    im = img.resize((s, s), Image.LANCZOS)
    if s <= 512: im.save(os.path.join(p, f"icon_{s}x{s}.png"))
    if s >= 32: im.save(os.path.join(p, f"icon_{s//2}x{s//2}@2x.png"))
subprocess.run(["iconutil", "-c", "icns", p, "-o", os.path.join(BUILD, "AppIcon.icns")], check=True)
print("wrote build/AppIcon.icns")
