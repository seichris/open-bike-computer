#pragma once

#include <string>

#include "map_stream_trust.hpp"

namespace map_transfer {

// Loads public verification keys compiled into firmware. Private signing keys
// never belong on the device. Release and ordinary profiles use only the
// production registry; opt-in remote-debug profiles may additionally compile
// the Bicino Dev public signer for development-stream physical testing.
MapStreamTrustStore compiledMapStreamTrustStore();

// JSON array of key-id/public-key-fingerprint capabilities advertised to iOS.
std::string compiledMapStreamTrustCapabilitiesJson();

} // namespace map_transfer
