# Recipe: logo.png

- image: logo.png
- kind: edit
- made: 2026-11-15 with ImageMagick (no Codex run: the pick already has no name or text)
- parent: candidates/tray-p3.recipe.md
- inputs:
  - candidates/tray-p3.png sha256 c77f5648b280b24f1f203d10c24ddf77e02cf852d831761d549ff51ab0955e2e

## Prompt

none: made by ImageMagick from the input above; the prompt is in the parent's recipe

## Steps

Crop a square around the drawing (981x981 at +110+160 of the 1254 px original, the object plus an even margin) and scale it to 800x800 with a Lanczos filter. No palette remap: the original's in-between shades stay (the owner's choice, 94a), so the main colours are the palette's and the rest are blends.

```
magick candidates/tray-p3.png -crop 981x981+110+160 +repage -filter Lanczos -resize 800x800 logo.png
```
