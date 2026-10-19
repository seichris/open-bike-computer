#pragma once

#include <string>

namespace map_transfer {
// Both transports publish the same metadata and observed runtime health. A
// format version alone is never evidence that the corresponding asset loaded.
template <typename Target>
inline void appendRendererLayerStatus(std::string &body, const Target &target,
                                      bool fontHealthy, bool poiHealthy) {
  const bool healthyPois = target.formatVersion == 5 &&
      target.poiProfileVersion == 1 && target.poiIndexProfileVersion == 1 &&
      poiHealthy;
  body += ",\"fontAssetHealthy\":";
  body += target.formatVersion >= 2 && fontHealthy ? "true" : "false";
  body += ",\"poiProfileVersion\":" + std::to_string(target.poiProfileVersion) +
      ",\"poiIndexProfileVersion\":" + std::to_string(target.poiIndexProfileVersion) +
      ",\"poiDataHealthy\":" + (healthyPois ? "true" : "false") +
      ",\"poiIndexHealthy\":" + (healthyPois ? "true" : "false") +
      ",\"contourLayerIncluded\":" + (target.contoursIncluded ? "true" : "false");
}
} // namespace map_transfer
