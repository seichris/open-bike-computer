// Match the real firmware's build-identity macro so generated wire identifiers
// cannot accidentally collide with VERSION again.
#ifndef VERSION
#define VERSION "host-firmware-identity"
#endif

#include "../../lib/ble_navigation/workout_zone_protocol.hpp"
#include "../../lib/ble_navigation/workout_telemetry_state.hpp"
#include "../../lib/gui/src/ride_stats_widget.hpp"
#include "../../lib/gui/src/rideTelemetryLayout.hpp"
#include <cassert>
#include <fstream>
#include <iterator>
#include <regex>
#include <vector>

using workout_telemetry::ApplyResult;
using workout_telemetry::Reducer;
using workout_telemetry_protocol::SessionState;

static std::vector<std::vector<uint8_t>> goldenPackets() {
  std::ifstream file("protocol/fixtures/workout-zones-v1.json");
  if (!file) file.open("../protocol/fixtures/workout-zones-v1.json");
  assert(file && "run from repository root or esp32");
  const std::string json((std::istreambuf_iterator<char>(file)), {});
  const std::regex hex("\"hex\": \"([0-9a-f]+)\"");
  std::vector<std::vector<uint8_t>> result;
  for (auto it = std::sregex_iterator(json.begin(), json.end(), hex);
       it != std::sregex_iterator(); ++it) {
    const auto encoded = (*it)[1].str();
    std::vector<uint8_t> data;
    for (std::size_t i = 0; i < encoded.size(); i += 2)
      data.push_back(static_cast<uint8_t>(std::stoul(encoded.substr(i, 2), nullptr, 16)));
    result.push_back(data);
  }
  assert(result.size() == 8);
  return result;
}

static Reducer established() {
  const uint8_t core[16] = {1, 0x42, 0x34, 0x12, 100, 0, 0, 0,
                            0, 0, 0, 0, 0xD2, 4, 75, 0};
  const uint8_t extended[16] = {2, 0x60, 0x34, 0x12, 75, 0, 0, 0,
                                75, 0, 0, 0, 3, 0, 0x80, 5};
  const uint8_t origin[28] = {3, 0, 0x34, 0x12, 100, 0, 0, 0,
      0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF,
      1, 0, 0, 0};
  Reducer reducer;
  assert(reducer.applyFrame(core, 16, 90, true) == ApplyResult::Applied);
  assert(reducer.applyFrame(extended, 16, 95, true) == ApplyResult::Applied);
  assert(reducer.applyFrame(origin, 28, 99, true) == ApplyResult::Applied);
  assert(reducer.state().committedPairGeneration == 1);
  return reducer;
}

static void set32(std::vector<uint8_t> &data, std::size_t offset, uint32_t value) {
  for (std::size_t i = 0; i < 4; ++i) data[offset + i] = static_cast<uint8_t>(value >> (i * 8));
}

int main() {
  const auto fixtures = goldenPackets();
  for (const auto &bytes : fixtures) {
    workout_zones::Packet packet;
    assert(workout_zones::decode(bytes.data(), bytes.size(), packet));
    const auto &zone = packet.value;
    assert(packet.token == 0x1234 && packet.pairGeneration == 1 && packet.state == 2);
    assert(zone.source == 2 && zone.sequence == 42 && zone.current == 2);
    assert(zone.sampleAgeMs == 1250 && zone.durations() && !zone.final());
    assert(bytes.size() == 32 + (zone.count - 1) * 8U + zone.count * 4U);
    for (uint8_t i = 0; i + 1 < zone.count; ++i) assert(zone.boundaries[i] == (i + 1) * 50 + 0.25);
    for (uint8_t i = 0; i < zone.count; ++i) assert(zone.milliseconds[i] == i * 1000U + 125U);
    auto reducer = established();
    assert(reducer.applyFrame(bytes.data(), bytes.size(), 100, false) == ApplyResult::RejectedUnauthenticated);
    assert(reducer.applyFrame(bytes.data(), bytes.size(), 100, true) == ApplyResult::Applied);
    const auto retained = reducer.state();
    assert(reducer.applyFrame(bytes.data(), bytes.size(), 5000, true) == ApplyResult::Applied);
    assert(reducer.state() == retained); // replay cannot renew expiry
    auto old = bytes; set32(old, 12, 41);
    assert(reducer.applyFrame(old.data(), old.size(), 5000, true) == ApplyResult::IgnoredZoneSequence);
    assert(reducer.state() == retained);
    for (std::size_t offset : {std::size_t(8), std::size_t(16), std::size_t(31)}) {
      auto wrong = bytes; wrong[offset] ^= 1;
      assert(reducer.applyFrame(wrong.data(), wrong.size(), 5000, true) == ApplyResult::IgnoredToken);
      assert(reducer.state() == retained);
    }
    auto wrongPair = bytes; wrongPair[7] = 0x82;
    assert(reducer.applyFrame(wrongPair.data(), wrongPair.size(), 5000, true) == ApplyResult::IgnoredPair);
    auto paused = bytes; paused[7] = 0x43; paused[6] = 0; paused[10] = paused[11] = 255;
    assert(reducer.applyFrame(paused.data(), paused.size(), 5000, true) == ApplyResult::IgnoredLifecyclePhase);
    auto impossibleTotal = bytes; set32(impossibleTotal, 32 + (zone.count - 1) * 8, 101001);
    assert(reducer.applyFrame(impossibleTotal.data(), impossibleTotal.size(), 5000, true) == ApplyResult::RejectedMetric);
    auto snapshot = workout_telemetry::makeSnapshot(retained, 101);
    const auto &fresh = packet.metric == 1 ? snapshot.state.zones.heartRate : snapshot.state.zones.power;
    assert(fresh.current == 2);
    snapshot = workout_telemetry::makeSnapshot(retained, packet.metric == 1 ? 10100 : 3850);
    const auto &stale = packet.metric == 1 ? snapshot.state.zones.heartRate : snapshot.state.zones.power;
    assert(stale.current == 0 && stale.count == zone.count); // retain definition; hide stale current
    auto newer = bytes; set32(newer, 12, 43);
    assert(reducer.applyFrame(newer.data(), newer.size(), 6000, true) == ApplyResult::Applied);
    assert((packet.metric == 1 ? reducer.state().zones.heartRate : reducer.state().zones.power).sequence == 43);

    // Corruption never partially mutates the output or runtime snapshot.
    for (std::size_t offset : {std::size_t(0),std::size_t(1),std::size_t(2),std::size_t(3),std::size_t(4),std::size_t(5),std::size_t(6)}) {
      auto bad = bytes; bad[offset] = 255;
      workout_zones::Packet output = packet;
      assert(!workout_zones::decode(bad.data(), bad.size(), output));
      assert(output.value == zone);
    }
    for (std::size_t length = 0; length < bytes.size(); ++length) {
      workout_zones::Packet output;
      assert(!workout_zones::decode(bytes.data(), length, output));
    }
    auto tooLong = bytes; tooLong.push_back(0);
    workout_zones::Packet output;
    assert(!workout_zones::decode(tooLong.data(), tooLong.size(), output));
    for (double bad : {0.0, -1.0, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()}) {
      auto invalid = bytes; uint64_t bits; std::memcpy(&bits, &bad, 8);
      for (unsigned i=0;i<8;++i) invalid[32+i] = static_cast<uint8_t>(bits >> (i*8));
      assert(!workout_zones::decode(invalid.data(), invalid.size(), output));
    }
    auto clear = bytes; clear.resize(32); clear[4] = clear[5] = clear[6] = 0;
    clear[10] = clear[11] = 255; set32(clear, 12, 44);
    assert(reducer.applyFrame(clear.data(), clear.size(), 6100, true) == ApplyResult::Applied);
    const auto &cleared = packet.metric == 1 ? reducer.state().zones.heartRate : reducer.state().zones.power;
    assert(cleared.received && cleared.count == 0 && cleared.current == 0);
    assert(reducer.applyFrame(bytes.data(), bytes.size(), 6200, true) == ApplyResult::IgnoredZoneSequence);

    auto wrap = packet.value;
    wrap.receivedAtMs = UINT32_MAX - 100;
    workout_zones::expire(wrap, true, false, 200, 5000);
    assert(wrap.current == 2);
    workout_zones::expire(wrap, true, false, 4000, 5000);
    assert(wrap.current == 0);
  }

  // A full UUID, not only the short token, namespaces native configuration.
  auto initial = established();
  assert(initial.applyFrame(fixtures[0].data(), fixtures[0].size(), 100, true) == ApplyResult::Applied);
  auto state = initial.state(); state.sessionID[0] ^= 1;
  Reducer otherSession(state);
  assert(otherSession.applyFrame(fixtures[0].data(), fixtures[0].size(), 200, true) == ApplyResult::IgnoredToken);

  // Completed data never carries a current highlight; no live group is final.
  auto finalBytes = fixtures[0]; finalBytes[7] = 0x45; finalBytes[6] = 0;
  finalBytes[10] = finalBytes[11] = 255;
  workout_zones::Packet decoded;
  assert(!workout_zones::decode(finalBytes.data(), finalBytes.size(), decoded));
  finalBytes[4] |= workout_zone_wire::FLAG_FINAL;
  assert(workout_zones::decode(finalBytes.data(), finalBytes.size(), decoded));
  auto finalZone = decoded.value;
  workout_zones::expire(finalZone, false, true, UINT32_MAX, 5000);
  assert(finalZone.final() && finalZone.count == 3 && finalZone.current == 0);

  // Shared renderer: all counts, every slot, both device dimensions.
  for (const auto &dimensions : {std::pair<int,int>{466,466}, {410,502}}) {
    const auto layout = ride_telemetry_layout::makeLayout(dimensions.first, dimensions.second);
    for (std::size_t slot = 0; slot < 7; ++slot) {
      const auto rect = ride_telemetry_layout::configurableSlotRect(layout, slot);
      for (std::size_t count = 3; count <= 9; ++count) for (int8_t current = 0; current < static_cast<int8_t>(count); ++current) {
        const auto presentation = ride_telemetry_layout::makeZonePresentation(rect, dimensions.first, -2, current, count, false);
        assert(presentation.update.action == ride_telemetry_layout::ZoneUpdateAction::Show);
        assert(!presentation.heartVisible && presentation.labelText[0] == 'Z');
        for (std::size_t i = 0; i < 9; ++i) {
          assert(presentation.segmentVisible[i] == (i < count));
          if (i < count) {
            assert(presentation.segments[i].width > 0);
            assert(presentation.segments[i].x >= rect.x && presentation.segments[i].right() <= rect.right());
          }
        }
        assert(presentation.label.width > 0 && presentation.label.right() <= presentation.segments[current].right());
      }
    }
  }
  ride_telemetry_presenter::ViewModel model;
  model.usesWorkout = true; model.sessionState = SessionState::Running;
  model.currentHeartRateZone = {true, 4}; model.heartRateZoneCount = {true, 5};
  assert(ride_telemetry_presenter::zoneIndex(model) == 3); // old app, new firmware
  assert(workout_zones::decode(fixtures[3].data(), fixtures[3].size(), decoded));
  model.zones.heartRate = decoded.value;
  auto widget = ride_stats_widget::make(screen_configuration_protocol::RideStatsWidget::HeartRateZone, model);
  assert(widget.zoneCount == 9 && widget.zoneIndex == 1 && std::strcmp(widget.title, "HR: Health") == 0);
  model.zones.heartRate.current = 0;
  assert(ride_telemetry_presenter::zoneIndex(model) == -1); // explicit unavailable never silently falls back
  assert(workout_zones::decode(fixtures[6].data(), fixtures[6].size(), decoded));
  model.zones.power = decoded.value;
  widget = ride_stats_widget::make(screen_configuration_protocol::RideStatsWidget::PowerZone, model);
  assert(widget.zoneCount == 6 && widget.zoneIndex == 1 && !widget.zoneShowsHeart);
  widget = ride_stats_widget::make(screen_configuration_protocol::RideStatsWidget::PowerZoneTime, model);
  assert(widget.available && std::strcmp(widget.value.data(), "00:01") == 0);
  return 0;
}
