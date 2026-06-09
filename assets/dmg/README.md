# DMG install window

`background.svg` is the source. `background.tiff` is the committed, multi-resolution
artifact Finder actually shows (it picks @2x on Retina, @1x otherwise) — `scripts/make-dmg.sh`
and the release pipeline read the TIFF, not the SVG.

Regenerate after editing the SVG:

```bash
cd assets/dmg
rsvg-convert -w 600  -h 400 background.svg -o background.png
rsvg-convert -w 1200 -h 800 background.svg -o background@2x.png
tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
rm background@2x.png   # folded into the TIFF; background.png is kept as a preview
```

Preview the styled window locally with `make dmg` (mounts as `dist/Peekr.dmg`).
Icon positions live in `scripts/make-dmg.sh` and must match the podiums in the SVG.
