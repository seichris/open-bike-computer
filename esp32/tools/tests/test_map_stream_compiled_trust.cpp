#include "../../lib/map_transfer/map_stream_compiled_trust.hpp"

#include <cassert>
#include <string>

int main() {
  const map_transfer::MapStreamTrustStore trust =
      map_transfer::compiledMapStreamTrustStore();
  const std::string capabilities =
      map_transfer::compiledMapStreamTrustCapabilitiesJson();

  assert(trust.find("map-prod-2026-07") != nullptr);
  assert(trust.find("map-prod-2026-08") != nullptr);
  assert(capabilities.find("map-prod-2026-07=") != std::string::npos);
  assert(capabilities.find("map-prod-2026-08=") != std::string::npos);

#if defined(MAP_STREAM_DEVELOPMENT_TRUST) && MAP_STREAM_DEVELOPMENT_TRUST
  assert(trust.find("map-dev-2026-08") != nullptr);
  assert(capabilities.find("map-dev-2026-08=") != std::string::npos);
#else
  assert(trust.find("map-dev-2026-08") == nullptr);
  assert(capabilities.find("map-dev-2026-08=") == std::string::npos);
#endif
}
