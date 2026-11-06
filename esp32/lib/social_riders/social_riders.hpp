#pragma once
#include "social_riders_protocol.hpp"
namespace social_riders {
// Friend markers are a standard map feature in production and development.
// BLE negotiation, authenticated ownership and fresh shared positions still
// determine whether any riders are received and displayed.
constexpr bool ENABLED = true;
bool ready();
void reset();
bool ingest(const uint8_t *packet, size_t length, uint8_t (&ack)[17]);
bool snapshot(size_t slot, Rider &destination);
}
