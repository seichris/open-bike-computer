#include "../../lib/power/sleep_audit_policy.hpp"
#include <cassert>
#include <iostream>
#include <string>
#include <vector>

using namespace sleep_audit::policy;

static PmicSnapshot battery(int mv = 4012, int percent = 72) {
  PmicSnapshot s{};
  put(s, 0x00, 0x08);
  put(s, 0x01, 0x40);
  put(s, 0x18, 0x08);
  put(s, 0x30, 0x01);
  put(s, 0x34, static_cast<uint8_t>(mv >> 8));
  put(s, 0x35, static_cast<uint8_t>(mv));
  put(s, 0x36, 0);
  put(s, 0xA4, static_cast<uint8_t>(percent));
  return s;
}

static Capsule request(Stage stage = Stage::Entering) {
  Capsule c{};
  c.fingerprint = 123;
  c.bootSequence = 42;
  c.stage = static_cast<uint8_t>(stage);
  c.entryEpochUs = kMinimumEpochUs + 1000000;
  c.pmic = battery();
  seal(c);
  return c;
}

static void sampling() {
  std::vector<unsigned> addresses;
  uint32_t clock = 0;
  auto s = samplePmic([&](uint8_t first, uint8_t *out, uint8_t count) {
    assert(count <= 11);
    for (uint8_t i = 0; i < count; ++i) {
      assert(indexOf(first + i) >= 0);
      addresses.push_back(first + i);
      out[i] = first + i;
    }
    clock += 2;
    return true;
  }, [&] { return clock; });
  assert(s.validMask == kAllRead && s.elapsedMs == 16);
  assert(addresses.size() == kRegisterCount);
  for (std::size_t i = 0; i < addresses.size(); ++i)
    assert(addresses[i] == kRegisters[i]);

  for (unsigned failedGroup = 0; failedGroup < 8; ++failedGroup) {
    unsigned calls = 0;
    auto partial = samplePmic([&](uint8_t, uint8_t *out, uint8_t count) {
      std::memset(out, 255, count); // a failed partial read must remain unknown
      return calls++ != failedGroup;
    }, [] { return 0U; });
    assert(calls == failedGroup + 1);
    const auto &group = kReadGroups[failedGroup];
    uint8_t value = 77;
    assert(!get(partial, group.first, value) && value == 77);
    assert(partial.validMask != kAllRead);
  }
  clock = UINT32_MAX - 20;
  unsigned calls = 0;
  s = samplePmic([&](uint8_t, uint8_t *out, uint8_t count) {
    ++calls;
    std::memset(out, 0, count);
    clock += 75;
    return true;
  }, [&] { return clock; });
  assert(calls == 2 && s.elapsedMs == 150); // also covers millis wrap
}

static void decoding() {
  auto s = battery();
  assert(batteryPercent(s) == 72 && batteryMillivolts(s) == 4012);
  for (int percent : {0, 100}) assert(batteryPercent(battery(4000, percent)) == percent);
  for (int percent : {101, 255}) assert(batteryPercent(battery(4000, percent)) == -1);
  for (int mv : {0, 6001, 16383}) assert(batteryMillivolts(battery(mv)) == -1);
  put(s, 0x00, 0);
  assert(batteryPresent(s) == 0 && batteryPercent(s) == -1 && batteryMillivolts(s) == -1);
  s = battery(); put(s, 0x18, 0);
  assert(batteryPercent(s) == -1);
  s = battery(); put(s, 0x30, 0);
  assert(batteryMillivolts(s) == -1);
  for (uint8_t flag : {0x40, 0x80, 0xC0}) {
    s = battery(); put(s, 0x34, flag | 15);
    assert(batteryMillivolts(s) == -1);
  }
  s = battery(); put(s, 0x36, 0x40);
  assert(batteryMillivolts(s) == -1);
  for (uint8_t reg : {0x00, 0x30, 0x34, 0x35, 0x36}) {
    s = battery(); s.validMask &= ~(1U << indexOf(reg));
    assert(batteryMillivolts(s) == -1);
  }
  assert(batteryPresent(PmicSnapshot{}) == -1);
}

static void retention() {
  const auto original = request();
  assert(valid(original));
  for (std::size_t i = 0; i < offsetof(Capsule, checksum) + sizeof(uint32_t); ++i) {
    auto damaged = original;
    reinterpret_cast<uint8_t *>(&damaged)[i] ^= 1;
    assert(!valid(damaged));
  }
  auto c = original;
  const auto r = consume(c, 123, 8, 3, original.entryEpochUs + 48LL*3600*1000000);
  assert(r.previousValid && r.sameFirmware && r.confirmedDeepSleep);
  assert(r.intervalValid && r.intervalMs == 48ULL*3600*1000);
  assert(std::strcmp(r.code, "confirmed_deep_sleep") == 0 && !valid(c));
  assert(!consume(c, 123, 8, 3, original.entryEpochUs).previousValid);
  for (auto stage : {Stage::Requested, Stage::PeripheralsReturned}) {
    c = request(stage);
    assert(!consume(c, 123, 8, 3, original.entryEpochUs).confirmedDeepSleep);
  }
  for (uint32_t reset : {0U, 1U, 3U, 4U, 6U, 9U, 11U}) {
    c = original;
    auto result = consume(c, 123, reset, 3, original.entryEpochUs + 1000000);
    assert(!result.confirmedDeepSleep && !result.intervalValid);
    if (reset == 1) assert(!result.previousValid);
  }
  c = original;
  auto changed = consume(c, 124, 8, 3, original.entryEpochUs);
  assert(changed.previousValid && !changed.sameFirmware && !changed.confirmedDeepSleep);
  c = original;
  assert(!consume(c, 123, 8, 0, original.entryEpochUs).confirmedDeepSleep);
  for (int64_t time : {int64_t(0), original.entryEpochUs - 1,
                       original.entryEpochUs + kMaximumIntervalUs + 1}) {
    c = original;
    auto result = consume(c, 123, 8, 3, time);
    assert(result.confirmedDeepSleep && !result.intervalValid);
  }
  c = original; c.entryEpochUs = 0; seal(c);
  assert(!consume(c, 123, 8, 3, original.entryEpochUs).intervalValid);
}

static void formatting() {
  char out[512] = {}, state[256] = {};
  assert(formatRegisters(PmicSnapshot{}, state, sizeof(state)));
  assert(std::string(state).find("00=??") == 0 && std::strlen(state) == 155);
  assert(formatBattery(PmicSnapshot{}, state, sizeof(state)));
  assert(std::strstr(state, "percent=unknown") && std::strstr(state, "voltage_mV=unknown"));
  assert(formatObservation("request", "battery", "123", state, false, out, sizeof(out)));
  assert(std::strstr(out, "\"available\":false"));
  assert(!formatObservation("request", "battery", "123", "x=\"bad", true, out, sizeof(out)));
  assert(!formatObservation("request", "battery", "123", std::string(257, 'x').c_str(), true, out, sizeof(out)));
  assert(!formatObservation("request", "battery", "123", "x=1", true, out, 8));
  assert(!formatRegisters(battery(), nullptr, 0));
  assert(!formatBattery(battery(), nullptr, 0));
  assert(!formatRegisters(battery(), out, 2));
  assert(!formatBattery(battery(), out, 2));
}

int main() {
  sampling(); decoding(); retention(); formatting();
  std::cout << "sleep audit policy tests passed\n";
}
