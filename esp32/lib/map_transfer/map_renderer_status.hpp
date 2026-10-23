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
  const char *poiHealth = healthyPois ? "true" : "false";
  // In-place appends avoid one string temporary per operator+ in both
  // transports' status serializers.
  body += ",\"fontAssetHealthy\":";
  body += target.formatVersion >= 2 && fontHealthy ? "true" : "false";
  body += ",\"poiProfileVersion\":";
  body += std::to_string(target.poiProfileVersion);
  body += ",\"poiIndexProfileVersion\":";
  body += std::to_string(target.poiIndexProfileVersion);
  body += ",\"poiDataHealthy\":";
  body += poiHealth;
  body += ",\"poiIndexHealthy\":";
  body += poiHealth;
  body += ",\"contourLayerIncluded\":";
  body += target.contoursIncluded ? "true" : "false";
}
} // namespace map_transfer
