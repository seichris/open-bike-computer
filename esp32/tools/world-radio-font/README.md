# World Radio bitmap font

`worldRadioFont20.c` is a 20px, 1bpp LVGL conversion of Noto Sans CJK SC
Regular, release Sans2.004, licensed under the adjacent SIL OFL license.
Source: https://github.com/notofonts/noto-cjk/tree/Sans2.004
Font SHA-256: `2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`.

The selected ranges include Latin/accents, Greek, Cyrillic, CJK punctuation,
kana, CJK Extension A, unified ideographs and compatibility ideographs.
This is not complete Unicode coverage (e.g. supplementary CJK and emoji).
iOS normalizes metadata to NFC before UTF-8 truncation, preserving accents.

Regenerate from the repository root after downloading the source font and
verifying its hash:

```sh
npx --yes lv_font_conv@1.5.3 --font /tmp/world-radio-NotoSansCJKsc-Regular.otf \
  -r 0x20-0x024f,0x0370-0x052f,0x1e00-0x1eff,0x2000-0x206f,0x3000-0x30ff,0x3400-0x4dbf,0x4e00-0x9fff,0xf900-0xfaff,0xff00-0xffef \
  --size 20 --bpp 1 --no-kerning --format lvgl --lv-include lvgl.h \
  --lv-font-name worldRadioFont20 -o esp32/lib/gui/src/worldRadioFont20.c
```

The bitmap is approximately 1.13 MiB, held in flash, with no full-font RAM
allocation. Large font descriptors are enabled in both LVGL configuration
sources because bitmap offsets exceed the small descriptor's 20-bit limit.
Only the radio metadata uses this font; controls retain the icon font.
