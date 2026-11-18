# README hero animation

The animation at the top of the README (`docs/images/hero.gif`, poster `docs/images/hero.png`) is a
Stageshow (see [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)) scene: faux product UI built with Benji Taylor's Stageshow React kit (MIT).
All content in it is fictional (555 numbers, an invented dental office).

- `index.tsx`, `scamshield.css`: the scene (a device pair: the Mac's decision on the left, the iPhone app on the right).
- `scams/`: the still in the README's "Using it" section (`docs/images/scams.png`), the iPhone app's Scams list grouped by type.
- `record-frames.mjs`: records one loop frame by frame on the kit's virtual clock.

To rebuild it:

1. Copy this folder to `<stageshow>/examples/scamshield/`, and copy `design/icon-1024.png` there as `icon.png`.
2. In the Stageshow folder run `npm install && npm run dev`, then preview `?capture=scamshield`.
3. Record and encode it:

```sh
STAGESHOW_DIR=/path/to/stageshow node record-frames.mjs ./frames
# keep the first 254 frames (one 12.7 s loop at 20 fps), then:
ffmpeg -framerate 20 -pattern_type glob -i 'frames/*.png' \
  -vf "scale=1140:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 hero.gif
```
