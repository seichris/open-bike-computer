#pragma once

#include "mapBlockFormat.hpp"
#include "mapFontAssetFormat.hpp"
#include "mapPoiIndex.hpp"

#include <string>

namespace map_renderer_format {

inline bool isFontAssetPath(const std::string &path) {
  static constexpr const char *suffix = "/assets/street-labels.fma";
  const size_t suffixBytes = std::char_traits<char>::length(suffix);
  return path.size() >= suffixBytes &&
         path.compare(path.size() - suffixBytes, suffixBytes, suffix) == 0;
}

inline bool isPoiIndexPath(const std::string &path) {
  static constexpr const char *suffix = "/assets/nearby-pois.fpi";
  const size_t suffixBytes = std::char_traits<char>::length(suffix);
  return path.size() >= suffixBytes &&
         path.compare(path.size() - suffixBytes, suffixBytes, suffix) == 0;
}

class StreamValidator {
public:
  explicit StreamValidator(const std::string &path)
      : fontAsset_(isFontAssetPath(path)),
        poiIndex_(isPoiIndexPath(path)),
        blockValidator_((fontAsset_ || poiIndex_) ? std::string() : path) {}

  bool feed(const uint8_t *data, size_t size) {
    return fontAsset_ ? fontValidator_.feed(data, size)
                      : (poiIndex_ ? poiValidator_.feed(data, size)
                                   : blockValidator_.feed(data, size));
  }

  bool finish() {
    return fontAsset_ ? fontValidator_.finish()
                      : (poiIndex_ ? poiValidator_.finish()
                                   : blockValidator_.finish());
  }

  bool failed() const {
    return fontAsset_ ? fontValidator_.failed()
                      : (poiIndex_ ? poiValidator_.failed()
                                   : blockValidator_.failed());
  }

private:
  bool fontAsset_ = false;
  bool poiIndex_ = false;
  map_block_format::StreamValidator blockValidator_;
  map_font_asset_format::StreamValidator fontValidator_;
  map_poi_index::StreamValidator poiValidator_;
};

} // namespace map_renderer_format
