#pragma once

#include "map_stream_format.hpp"

#include <cstddef>
#include <cstdint>

namespace map_transfer {

bool verifyMapStreamP256Signature(
    const uint8_t *manifest, size_t manifestSize,
    const MapStreamSignatureEnvelope &envelope, const uint8_t *publicKeyX963,
    size_t publicKeySize);

} // namespace map_transfer
