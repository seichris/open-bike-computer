#pragma once

#include <string>

#include "../ble_navigation/map_profile_protocol.hpp"

namespace map_transfer {

// Reader capabilities this firmware reports in its authenticated map transfer
// status. They follow exactly what mapStreamTargetSupported() admits and the
// renderer draws, so the app decides map installability from them rather than
// from the firmware build identity. Durable map contract v1 requires every
// firmware profile to keep each production format and feature listed here
// (map-platform/config/map-compatibility-contract-v1.json).
inline std::string mapReaderCapabilitiesJson() {
  return std::string(
             "{\"schemaVersion\":1,\"streamFormats\":[{\"format\":"
             "\"bike-map-stream-v1\",\"manifestSchemaVersions\":[1]}],"
             "\"renderers\":[{\"renderer\":\"esp32-fmb\",\"formatVersions\":"
             "[1,2,3,4") +
         (MAP_POIS_RUNTIME_ENABLED ? ",5" : "") +
         "],\"features\":[\"3d-buildings\",\"contours\"" +
         (MAP_POIS_RUNTIME_ENABLED ? ",\"map-pois\"" : "") +
         ",\"street-labels\"]}]}";
}

} // namespace map_transfer
