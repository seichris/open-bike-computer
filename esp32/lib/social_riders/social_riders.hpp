#pragma once
#include "social_riders_protocol.hpp"
namespace social_riders {
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
constexpr bool ENABLED = true;
#else
constexpr bool ENABLED = false; // Physical round-screen qualification gates production.
#endif
bool ready();
void reset();
bool ingest(const uint8_t *packet, size_t length, uint8_t (&ack)[17]);
bool snapshot(size_t slot, Rider &destination);
}
