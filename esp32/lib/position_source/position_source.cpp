#include "position_source.hpp"

#include <Arduino.h>

#include "../board/board.hpp"
#include "gnss_receiver.hpp"

namespace position_source {

namespace {
portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
Arbiter arbiter;
}  // namespace

void begin() {
  arbiter.gnssFitted = board::gnss::fitted;
  gnss_receiver::begin();
}

void startTask() { gnss_receiver::startTask(); }

bool acceptsPhonePosition(uint32_t nowMs) {
  portENTER_CRITICAL(&mux);
  const bool accepts = arbiter.acceptsPhone(nowMs);
  portEXIT_CRITICAL(&mux);
  return accepts;
}

void notePhonePosition(uint32_t nowMs) {
  portENTER_CRITICAL(&mux);
  arbiter.notePhone(nowMs);
  portEXIT_CRITICAL(&mux);
}

void noteGnssFix(uint32_t nowMs, bool fixValid) {
  portENTER_CRITICAL(&mux);
  arbiter.noteGnss(nowMs, fixValid);
  portEXIT_CRITICAL(&mux);
}

bool applyPendingGnssFix() { return gnss_receiver::applyPendingFix(); }

Source activeSource(uint32_t nowMs) {
  portENTER_CRITICAL(&mux);
  const Source source = arbiter.active(nowMs);
  portEXIT_CRITICAL(&mux);
  return source;
}

GnssStatus gnssStatus() { return gnss_receiver::status(); }

bool gnssFitted() { return board::gnss::fitted; }

uint8_t sourceFlags() {
  return static_cast<uint8_t>(1U | (board::gnss::fitted ? 2U : 0U));
}

uint8_t moduleCode() { return static_cast<uint8_t>(board::gnss::module); }

const char *moduleName() {
  switch (board::gnss::module) {
  case board::GnssModule::quectelLc76g:
    return "lc76g";
  case board::GnssModule::none:
    break;
  }
  return "none";
}

const char *transportName() {
  switch (board::gnss::transport) {
  case board::GnssTransport::uart:
    return "uart";
  case board::GnssTransport::i2c:
    return "i2c";
  case board::GnssTransport::none:
    break;
  }
  return "none";
}

const char *activeSourceName(uint32_t nowMs) {
  switch (activeSource(nowMs)) {
  case Source::Phone:
    return "phone";
  case Source::Gnss:
    return "gnss";
  case Source::None:
    break;
  }
  return "none";
}

}  // namespace position_source
