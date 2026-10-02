#pragma once

#include "rideMetricFontSelection.hpp"
#include <lvgl.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

LV_FONT_DECLARE(ride_value_font_56);
LV_FONT_DECLARE(ride_value_font_64);
LV_FONT_DECLARE(ride_speed_font_84);

namespace ride_metric_typography {

// Share the existing bitmap data; only the small descriptors are adapted.
// This object must not move: LVGL labels retain the address of font_.
class TabularFont {
public:
  explicit TabularFont(const lv_font_t &base) : base_(base), font_(base) {
    for (uint32_t digit = '0'; digit <= '9'; ++digit) {
      lv_font_glyph_dsc_t glyph{};
      if (base_.get_glyph_dsc(&base_, &glyph, digit, 0)) {
        if (glyph.adv_w > digitWidth_)
          digitWidth_ = glyph.adv_w;
        if (glyph.box_w > digitWidth_)
          digitWidth_ = glyph.box_w;
      }
    }
    font_.user_data = this;
    font_.get_glyph_dsc = describe;
    // No pair-dependent advances for punctuation/units adjacent to digits.
    font_.kerning = LV_FONT_KERNING_NONE;
    // A fallback with proportional digits would break the width contract.
    // Selection explicitly checks coverage before using an adapted font.
    font_.fallback = nullptr;
  }

  TabularFont(const TabularFont &) = delete;
  TabularFont &operator=(const TabularFont &) = delete;
  const lv_font_t *get() const { return &font_; }

private:
  static bool describe(const lv_font_t *font, lv_font_glyph_dsc_t *glyph,
                       uint32_t letter, uint32_t /*next*/) {
    const auto &self = *static_cast<const TabularFont *>(font->user_data);
    if (!self.base_.get_glyph_dsc(&self.base_, glyph, letter, 0))
      return false;
    if (letter >= '0' && letter <= '9') {
      glyph->adv_w = self.digitWidth_;
      glyph->ofs_x = static_cast<int16_t>(
          (static_cast<int32_t>(self.digitWidth_) - glyph->box_w) / 2);
    }
    // dsc and the bitmap/release callbacks still refer to the original
    // fmt_txt asset. LVGL supplies this adapted font as resolved_font.
    return true;
  }

  const lv_font_t &base_;
  lv_font_t font_;
  uint16_t digitWidth_ = 0;
};

enum class Role : uint8_t { MetricLarge, MetricCompact, Hero, Zone };

struct TextBounds {
  const char *text = nullptr;
  int32_t width = 0;
  int32_t height = 0;
};

// Every digit has the same advance, and kerning is disabled. Therefore
// measuring a value measures its entire format class (e.g. D:DD:DD), not
// whichever glyphs happen to occur this second. No history/first-value cache.
inline bool supportsText(const lv_font_t *font, const char *text) {
  for (std::size_t i = 0; text[i] != '\0'; ++i) {
    lv_font_glyph_dsc_t glyph{};
    if (!lv_font_get_glyph_dsc(font, &glyph,
                               static_cast<uint8_t>(text[i]), 0) ||
        glyph.is_placeholder)
      return false;
  }
  return true;
}

template <std::size_t N>
const lv_font_t *firstFitting(const std::array<const lv_font_t *, N> &fonts,
                             const char *text, int32_t width,
                             int32_t height, const TextBounds *peer = nullptr) {
  if (text == nullptr || width <= 0 || height <= 0)
    return nullptr;
  std::array<ride_metric_font_selection::Candidate, N> candidates{};
  for (std::size_t i = 0; i < N; ++i) {
    candidates[i] = {
        lv_text_get_width(text, static_cast<uint32_t>(std::strlen(text)),
                          fonts[i], 0),
        fonts[i]->line_height <= height && supportsText(fonts[i], text) &&
            (peer == nullptr ||
             (peer->text != nullptr && peer->width > 0 &&
              fonts[i]->line_height <= peer->height &&
              supportsText(fonts[i], peer->text) &&
              lv_text_get_width(peer->text, std::strlen(peer->text),
                                fonts[i], 0) <= peer->width)),
    };
  }
  const auto index =
      ride_metric_font_selection::firstFittingIndex(candidates, width);
  // Never return an overflowing or unsupported "last resort" font.
  return index < N ? fonts[index] : nullptr;
}

inline const lv_font_t *fontForText(const char *text, int32_t width,
                                    int32_t height, Role role,
                                    const TextBounds *peer = nullptr) {
  static const TabularFont value64(ride_value_font_64);
  static const TabularFont value56(ride_value_font_56);
  static const TabularFont value48(lv_font_montserrat_48);
  static const TabularFont value38(lv_font_montserrat_38);
  static const TabularFont value24(lv_font_montserrat_24);
  static const TabularFont value18(lv_font_montserrat_18);
  switch (role) {
  case Role::Hero: {
    static const TabularFont speed84(ride_speed_font_84);
    return firstFitting(
        std::array<const lv_font_t *, 7>{speed84.get(), value64.get(),
            value56.get(), value48.get(), value38.get(), value24.get(),
            value18.get()}, text, width, height, peer);
  }
  case Role::MetricLarge:
    return firstFitting(
        std::array<const lv_font_t *, 6>{value64.get(), value56.get(),
            value48.get(), value38.get(), value24.get(), value18.get()},
        text, width, height, peer);
  case Role::MetricCompact:
    return firstFitting(
        std::array<const lv_font_t *, 3>{value38.get(), value24.get(),
            value18.get()}, text, width, height, peer);
  case Role::Zone: {
    static const TabularFont zone14(lv_font_montserrat_14);
    static const TabularFont zone12(lv_font_montserrat_12);
    static const TabularFont zone10(lv_font_montserrat_10);
    return firstFitting(
        std::array<const lv_font_t *, 3>{zone14.get(), zone12.get(),
            zone10.get()}, text, width, height, peer);
  }
  }
  return nullptr;
}

// Altitude follows its numeric left neighbour. Select once for both complete
// strings and both safe bounds, so a long/negative altitude cannot clip and
// neither label grows/shrinks when a same-width digit changes.
inline const lv_font_t *fontForPair(const TextBounds &left,
                                    const TextBounds &right, Role role) {
  return fontForText(left.text, left.width, left.height, role, &right);
}

} // namespace ride_metric_typography
