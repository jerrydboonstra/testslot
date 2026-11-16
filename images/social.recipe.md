# Recipe: social.png

- image: social.png
- kind: edit
- made: 2026-11-15 with Pillow (no Codex run, no new image generation: the text is composited over the picked image)
- parent: logo.recipe.md
- inputs:
  - logo.png sha256 3b9c567ab321f62e20bc99ba27cce0d5d508c077bddee73dc972f5bab1a39524

## Prompt

none: made by the script below from the input above; the drawing's prompt is in candidates/tray-p3.recipe.md

## Steps

A 1280x640 canvas in the logo's own background colour (read from the logo's corner, so the paste leaves no edge). logo.png scaled to 600x600 and pasted at (20, 20); the word "testslot" in Georgia Bold (the Mac's /System/Library/Fonts/Supplemental/Georgia Bold.ttf, approved by the owner), 156 px, in dark coffee (#432818), its left edge at x=650 and centred vertically (text box about 588x120 at 650,260). No palette remap: the logo's in-between shades and the text's antialiasing stay. Run it from this folder (testslot/images).

```python
from PIL import Image, ImageDraw, ImageFont
INK = (0x43, 0x28, 0x18)
W, H = 1280, 640
logo = Image.open("logo.png").convert("RGB").resize((600, 600), Image.LANCZOS)
BG = logo.getpixel((5, 5))          # the render's own background, so the paste leaves no edge
canvas = Image.new("RGB", (W, H), BG)
canvas.paste(logo, (20, 20))
font_path = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
size = 200
while True:
    font = ImageFont.truetype(font_path, size)
    l, t, r, b = ImageDraw.Draw(canvas).textbbox((0, 0), "testslot", font=font)
    if r - l <= 590: break
    size -= 4
d = ImageDraw.Draw(canvas)
d.text((650 - l, (H - (b - t)) // 2 - t), "testslot", font=font, fill=INK)
canvas.save("social.png")
```
