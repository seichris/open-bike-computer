#pragma once

#include "mapBlockFormat.hpp"
#include "mapFontAssetFormat.hpp"
#include "mapTerrain.hpp"

#include <string>

namespace map_renderer_format {

inline bool isFontAssetPath(const std::string &path) {
  static constexpr const char *suffix = "/assets/street-labels.fma";
  const size_t suffixBytes = std::char_traits<char>::length(suffix);
  return path.size() >= suffixBytes &&
         path.compare(path.size() - suffixBytes, suffixBytes, suffix) == 0;
}

class StreamValidator {
public:
  explicit StreamValidator(const std::string &path)
      : terrain_(path.size() >= 4 && path.substr(path.size() - 4) == ".fme"),
        fontAsset_(isFontAssetPath(path)),
        blockValidator_(fontAsset_ ? std::string() : path) {}

  bool feed(const uint8_t *data, size_t size) {
    if (terrain_)
      return terrainValidator_.feed(data, size);
    return fontAsset_ ? fontValidator_.feed(data, size)
                      : blockValidator_.feed(data, size);
  }

  bool finish() {
    if (terrain_)
      return terrainValidator_.finish();
    return fontAsset_ ? fontValidator_.finish() : blockValidator_.finish();
  }

  bool failed() const {
    if (terrain_)
      return terrainValidator_.failed();
    return fontAsset_ ? fontValidator_.failed() : blockValidator_.failed();
  }

private:
  bool terrain_ = false;
  map_terrain::StreamValidator terrainValidator_;
  bool fontAsset_ = false;
  map_block_format::StreamValidator blockValidator_;
  map_font_asset_format::StreamValidator fontValidator_;
};

} // namespace map_renderer_format
