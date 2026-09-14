"""Native regression tests for Workout Stats geometry and typography.

Discovered by the existing root tools/tests CI step. Compile the production
headers and label-update helpers against a small LVGL API test double. Custom
font metrics are read from the actual checked-in assets; Montserrat fallbacks
are deliberately synthetic proportional fonts, not a pixel-rendering oracle.
Firmware CI and a real 1.75-inch visual check remain separate acceptance gates.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GUI = ROOT / "esp32/lib/gui/src"


def custom_font_data(path: Path, symbol: str) -> str:
    source = path.read_text()
    table = re.search(r"glyph_dsc\[\]\s*=\s*\{(.*?)\n\};", source, re.S).group(1)
    rows = [dict((k, int(v)) for k, v in re.findall(r"\.(\w+)\s*=\s*(-?\d+)", row))
            for row in re.findall(r"\{([^}]+)\}", table)]
    start = int(re.search(r"\.range_start\s*=\s*(\d+)", source).group(1))
    sparse = re.search(r"unicode_list_0\[\]\s*=\s*\{(.*?)\};", source, re.S)
    if sparse:
        offsets = [int(x, 0) for x in re.findall(r"0x[0-9a-fA-F]+|\d+", sparse.group(1))]
        mapping = [(start + offset, i + 1) for i, offset in enumerate(offsets)]
    else:
        full = re.search(r"glyph_id_ofs_list_0\[\]\s*=\s*\{(.*?)\};", source, re.S)
        offsets = [int(x) for x in re.findall(r"\d+", full.group(1))]
        mapping = [(start + i, offset + 1) for i, offset in enumerate(offsets)]
    height = int(re.search(r"\.line_height\s*=\s*(\d+)", source).group(1))
    baseline = int(re.search(r"\.base_line\s*=\s*(\d+)", source).group(1))
    entries = []
    for code, index in mapping:
        row = rows[index]
        fields = [code, (row["adv_w"] + 8) >> 4, row["box_w"], row["box_h"],
                  row["ofs_x"], row["ofs_y"]]
        entries.append("{" + ",".join(map(str, fields)) + "}")
    return (f"static const HostGlyph {symbol}_glyphs[] = {{" + ",".join(entries) + "};\n"
            f"const lv_font_t {symbol} = customFont({symbol}_glyphs, "
            f"sizeof({symbol}_glyphs)/sizeof(HostGlyph), {height}, {baseline});\n")


STUB = r'''
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
struct lv_font_t;
struct lv_draw_buf_t {};
struct lv_font_glyph_dsc_t {
  const lv_font_t *resolved_font = nullptr;
  uint16_t adv_w = 0, box_w = 0, box_h = 0;
  int16_t ofs_x = 0, ofs_y = 0;
  bool is_placeholder = false;
  uint32_t gid = 0;
};
struct lv_font_t {
  bool (*get_glyph_dsc)(const lv_font_t *, lv_font_glyph_dsc_t *, uint32_t, uint32_t) = nullptr;
  const void *(*get_glyph_bitmap)(lv_font_glyph_dsc_t *, lv_draw_buf_t *) = nullptr;
  void (*release_glyph)(const lv_font_t *, lv_font_glyph_dsc_t *) = nullptr;
  int32_t line_height = 0, base_line = 0;
  int kerning = 0;
  const void *dsc = nullptr;
  const lv_font_t *fallback = nullptr;
  void *user_data = nullptr;
};
constexpr int LV_FONT_KERNING_NONE = 1, LV_PART_MAIN = 0;
#define LV_FONT_DECLARE(name) extern const lv_font_t name
struct HostGlyph { uint32_t code; uint16_t advance, width, height; int16_t x, y; };
struct HostFontData { const HostGlyph *glyphs; size_t count; };
inline bool customDescribe(const lv_font_t *f, lv_font_glyph_dsc_t *g,
                           uint32_t ch, uint32_t) {
  const auto &data = *static_cast<const HostFontData *>(f->dsc);
  for (size_t i = 0; i < data.count; ++i) {
    const auto &v = data.glyphs[i];
    if (v.code != ch) continue;
    *g = {}; g->adv_w = v.advance; g->box_w = v.width; g->box_h = v.height;
    g->ofs_x = v.x; g->ofs_y = v.y; g->gid = static_cast<uint32_t>(i);
    return true;
  }
  return false;
}
inline const void *customBitmap(lv_font_glyph_dsc_t *g, lv_draw_buf_t *) {
  const auto *data = static_cast<const HostFontData *>(g->resolved_font->dsc);
  return &data->glyphs[g->gid];
}
inline lv_font_t customFont(const HostGlyph *glyphs, size_t count, int h, int b) {
  // Test-only allocations live until exit; production adapters allocate nothing.
  lv_font_t f{}; f.get_glyph_dsc = customDescribe;
  f.get_glyph_bitmap = customBitmap; f.line_height = h; f.base_line = b;
  f.dsc = new HostFontData{glyphs, count}; return f;
}
inline bool syntheticDescribe(const lv_font_t *f, lv_font_glyph_dsc_t *g,
                             uint32_t ch, uint32_t next) {
  if (ch < 32 || ch > 126) return false;
  *g = {};
  const int size = f->line_height - 3;
  const int width = ch == '1' ? size/3 : (ch == ':' || ch == '.' || ch == ' ')
      ? size/4 : (size*2)/3;
  g->adv_w = static_cast<uint16_t>(width + (next == '1' ? 1 : 0));
  g->box_w = static_cast<uint16_t>(width);
  g->box_h = static_cast<uint16_t>(size); return true;
}
inline lv_font_t syntheticFont(int size) {
  lv_font_t f{}; f.get_glyph_dsc = syntheticDescribe; f.line_height = size + 3;
  return f;
}
inline bool lv_font_get_glyph_dsc(const lv_font_t *f, lv_font_glyph_dsc_t *g,
                                uint32_t ch, uint32_t next) {
  bool ok = f->get_glyph_dsc(f, g, ch, next);
  g->resolved_font = f; return ok;
}
inline int32_t lv_text_get_width(const char *s, uint32_t n, const lv_font_t *f, int) {
  int32_t width = 0;
  for (uint32_t i = 0; i < n; ++i) {
    lv_font_glyph_dsc_t g{};
    if (lv_font_get_glyph_dsc(f, &g, static_cast<uint8_t>(s[i]),
                             static_cast<uint8_t>(s[i+1]))) width += g.adv_w;
  }
  return width;
}
inline const lv_font_t lv_font_montserrat_48 = syntheticFont(48);
inline const lv_font_t lv_font_montserrat_38 = syntheticFont(38);
inline const lv_font_t lv_font_montserrat_24 = syntheticFont(24);
inline const lv_font_t lv_font_montserrat_18 = syntheticFont(18);
inline const lv_font_t lv_font_montserrat_14 = syntheticFont(14);
inline const lv_font_t lv_font_montserrat_12 = syntheticFont(12);
inline const lv_font_t lv_font_montserrat_10 = syntheticFont(10);
enum lv_text_align_t { LV_TEXT_ALIGN_LEFT, LV_TEXT_ALIGN_CENTER };
constexpr int LV_LABEL_LONG_CLIP = 1, LV_LABEL_LONG_DOT = 2, LV_OBJ_FLAG_HIDDEN = 1;
struct lv_obj_t {
  int x=0,y=0,width=0,height=0,mode=0,flags=0;
  const lv_font_t *font = nullptr;
  lv_text_align_t align = LV_TEXT_ALIGN_LEFT;
  std::string text;
};
inline void lv_obj_set_pos(lv_obj_t *o,int x,int y) { o->x=x; o->y=y; }
inline void lv_obj_set_size(lv_obj_t *o,int w,int h) { o->width=w; o->height=h; }
inline void lv_obj_set_style_text_font(lv_obj_t *o,const lv_font_t *f,int) { o->font=f; }
inline const lv_font_t *lv_obj_get_style_text_font(lv_obj_t *o,int) { return o->font; }
inline void lv_obj_set_style_text_align(lv_obj_t *o,lv_text_align_t a,int) { o->align=a; }
inline void lv_label_set_long_mode(lv_obj_t *o,int m) { o->mode=m; }
inline const char *lv_label_get_text(lv_obj_t *o) { return o->text.c_str(); }
inline void lv_label_set_text(lv_obj_t *o,const char *s) { o->text=s; }
inline void lv_obj_add_flag(lv_obj_t *o,int f) { o->flags|=f; }
inline void lv_obj_clear_flag(lv_obj_t *o,int f) { o->flags&=~f; }
inline uint32_t lv_color_hex(uint32_t c) { return c; }
inline void lv_obj_set_style_text_color(lv_obj_t *,uint32_t,int) {}
'''

HARNESS = r'''
#include <cassert>
#include <cstdio>
using namespace ride_telemetry_layout;
using namespace ride_metric_typography;
void assertVisible(const lv_obj_t &label) {
  assert(label.font);
  assert(label.font->line_height <= label.height);
  assert(lv_text_get_width(label.text.c_str(), label.text.size(), label.font, 0) <= label.width);
  assert(fits({label.x,label.y,label.width,label.height},rideLayout.screenWidth,rideLayout.screenHeight));
  if (usesRoundScreenSafeArea(rideLayout.screenWidth,rideLayout.screenHeight))
    assert(cornersFitCircle({label.x,label.y,label.width,label.height},466));
}
int main() {
  constexpr auto round = makeLayout(466,466);
  constexpr auto rectangle = makeLayout(410,502);
  static_assert(isValid(round) && isValid(rectangle));
  static_assert(!usesRoundScreenSafeArea(410,410));
  static_assert(!cornersFitCircle({12,316,209,82},466));
  static_assert(rectangle.metrics[0].x == 12 && rectangle.metrics[0].y == 136);
  static_assert(rectangle.metrics[0].width == 181 && rectangle.metrics[0].height == 68);
  static_assert(rectangle.hero.x == 0 && rectangle.hero.y == 45);
  auto invalid = round; invalid.metrics[4] = {12,316,209,82}; assert(!isValid(invalid));
  // Reproduce the reported threshold with the real checked-in 64px metrics.
  assert(lv_text_get_width("2:18:21",7,&ride_value_font_64,0) == 193);
  assert(lv_text_get_width("2:18:22",7,&ride_value_font_64,0) == 206);
  for (const auto *base : {&ride_value_font_64,&ride_value_font_56,&ride_speed_font_84}) {
    TabularFont adapted(*base); const auto *font = adapted.get();
    assert(font->dsc == base->dsc && font->get_glyph_bitmap == base->get_glyph_bitmap);
    uint16_t advance = 0;
    for (char digit='0';digit<='9';++digit) {
      lv_font_glyph_dsc_t g{};
      assert(lv_font_get_glyph_dsc(font,&g,digit,'1'));
      if (advance) assert(g.adv_w == advance);
      advance=g.adv_w;
      assert(g.ofs_x >= 0 && g.ofs_x+g.box_w <= g.adv_w);
      assert(font->get_glyph_bitmap(&g,nullptr));
      const int top=font->line_height-font->base_line-g.box_h-g.ofs_y;
      assert(top >= 0 && top+g.box_h <= font->line_height);
    }
    assert(lv_text_get_width("11.1",4,font,0) == lv_text_get_width("88.8",4,font,0));
  }
  for (const auto &layout : {round,rectangle}) {
    rideLayout=layout;
    for (size_t slot=0;slot<7;++slot) {
      const auto metric=configurableSlotRect(layout,slot);
      const auto value=configurableValueRect(layout,slot);
      const auto role=slot==0?Role::Hero:metricFontRole();
      lv_obj_t label{},heart{};
      const lv_font_t *previous=nullptr;
      size_t previousLength=0;
      // Every second through both the one-hour and ten-hour transitions.
      for (unsigned seconds=0;seconds<=36001;++seconds) {
        char text[24];
        if (seconds<3600) std::snprintf(text,sizeof(text),"%02u:%02u",seconds/60,seconds%60);
        else std::snprintf(text,sizeof(text),"%u:%02u:%02u",seconds/3600,(seconds/60)%60,seconds%60);
        setMetricValueIfChanged(&label,text,value,role);
        assert(label.text == text); assertVisible(label);
        if (previous && previousLength==std::strlen(text)) assert(previous==label.font);
        previous=label.font; previousLength=std::strlen(text);
      }
      for (const char *text : {"2:18:21","2:18:22","1193046:28:15","999999 m","4294967 km",
                                "-32768","65535","123.4","--"}) {
        setMetricValueIfChanged(&label,text,value,role); assertVisible(label);
        assert(label.text==text);
      }
      for (const char *text : {"111","222","999"}) {
        setHeartValue(&label,&heart,text,metric,true); assertVisible(label);
        assert(!(heart.flags & LV_OBJ_FLAG_HIDDEN));
        if (layout.screenWidth==466) assert(cornersFitCircle({heart.x,heart.y,heart.width,heart.height},466));
      }
      setHeartValue(&label,&heart,"--",metric,false);
      assertVisible(label); assert(heart.flags & LV_OBJ_FLAG_HIDDEN);
      // A tight heart label must not control the next metric's font or position.
      setHeartValue(&label,&heart,"111",metric,true);
      setMetricValueIfChanged(&label,"2:18:22",value,role);
      assert(label.x==value.x && label.y==value.y && label.width==value.width);
      lv_obj_t fresh{}; setMetricValueIfChanged(&fresh,"2:18:22",value,role);
      assert(fresh.font==label.font && label.align==LV_TEXT_ALIGN_CENTER);
      for (size_t active=0;active<5;++active) {
        const auto zone=makeZoneStripLayout(metric,layout.screenWidth,active);
        for (const auto r : zone.segments) {
          assert(fits(r,layout.screenWidth,layout.screenHeight));
          if (layout.screenWidth==466) assert(cornersFitCircle(r,466));
        }
        if (layout.screenWidth==466) {
          assert(cornersFitCircle(zone.heart,466)); assert(cornersFitCircle(zone.label,466));
        }
        setMetricValueIfChanged(&label,"ZONE 5",zone.label,Role::Zone);
        assert(label.text=="ZONE 5"); assertVisible(label);
      }
      setMetricValueIfChanged(&label,"unrepresentable value longer than any slot",value,role);
      assert(label.text=="--"); assertVisible(label);
    }
  }
  for (const auto &layout : {round,rectangle}) {
    rideLayout=layout;
    for (size_t right=2;right<7;right+=2) {
      auto leftRect=configurableValueRect(layout,right-1);
      auto rightRect=configurableValueRect(layout,right);
      for (const char *time : {"2:18:21","2:18:22","9:59:59","10:00:00"}) {
        for (const char *altitude : {"111","222","-32768","0","32767"}) {
          const auto *font=fontForPair(
              {time,leftRect.width-4,leftRect.height},
              {altitude,rightRect.width-4,rightRect.height},metricFontRole());
          assert(font);
          lv_obj_t left{},rightLabel{};
          setMetricValueIfChanged(&left,time,leftRect,metricFontRole(),font);
          setMetricValueIfChanged(&rightLabel,altitude,rightRect,metricFontRole(),font);
          assert(left.font==rightLabel.font);assertVisible(left);assertVisible(rightLabel);
          assert(left.text==time && rightLabel.text==altitude);
        }
      }
      assert(fontForPair({"2:18:21",leftRect.width-4,leftRect.height},
                         {"111",rightRect.width-4,rightRect.height},metricFontRole()) ==
             fontForPair({"2:18:22",leftRect.width-4,leftRect.height},
                         {"222",rightRect.width-4,rightRect.height},metricFontRole()));
    }
  }
  assert(!fontForText("123",1,60,Role::MetricLarge));
  assert(!fontForText("123",200,1,Role::MetricLarge));
  assert(!fontForText(nullptr,200,60,Role::MetricLarge));
  assert(!fontForText("\x01",200,60,Role::MetricLarge));
  std::puts("Workout Stats: geometry, actual custom metrics, stable timers and slot transitions passed");
}
'''


class WorkoutStatsRenderingTests(unittest.TestCase):
    def test_native_layout_and_typography(self):
        source = (GUI / "rideTelemetryScr.cpp").read_text()
        # Compile the actual shared renderer helpers, not a rewritten model.
        helpers = source.split("ride_metric_typography::Role metricFontRole()", 1)[1]
        helpers = "ride_metric_typography::Role metricFontRole()" + helpers.split("lv_obj_t *createPage(", 1)[0]
        fonts = "".join(custom_font_data(GUI / filename, symbol) for filename, symbol in [
            ("rideValueFont64.c", "ride_value_font_64"),
            ("rideValueFont56.c", "ride_value_font_56"),
            ("rideSpeedFont84.c", "ride_speed_font_84"),
        ])
        with tempfile.TemporaryDirectory(prefix="workout-stats-") as directory:
            temp = Path(directory)
            (temp / "lvgl.h").write_text(STUB)
            translation = ('#include "rideMetricTypography.hpp"\n#include "rideTelemetryLayout.hpp"\n'
                           + fonts + '\nride_telemetry_layout::Layout rideLayout{};\n'
                           + helpers + HARNESS)
            (temp / "test.cpp").write_text(translation)
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2",
                            "-I", str(temp), "-I", str(GUI), str(temp / "test.cpp"),
                            "-o", str(temp / "test")], check=True, timeout=60)
            subprocess.run([str(temp / "test")], check=True, timeout=60)


if __name__ == "__main__":
    unittest.main()
