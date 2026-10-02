#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <initializer_list>
#include <type_traits>

// Portable, read-only observation/retention policy. No Arduino or register
// writes: host tests exercise the same decoding and wake classification.
namespace sleep_audit::policy {

constexpr uint32_t kMagic = 0x534C5041; // SLPA
constexpr uint16_t kSchema = 1;
constexpr int32_t kNotAttempted = std::numeric_limits<int32_t>::min();
constexpr uint32_t kReadBudgetMs = 150;
constexpr int64_t kMinimumEpochUs = 1700000000LL * 1000000LL;
constexpr int64_t kMaximumIntervalUs = 366LL * 24 * 60 * 60 * 1000000;

// AXP2101 SWcharge v1.0: status, gauge enable, PWR configuration, ADC
// configuration/data, regulator enable/voltage configuration, and gauge SOC.
// Never read IRQ status, touch frames, or undocumented/reserved addresses.
constexpr uint8_t kRegisters[] = {
    0x00, 0x01, 0x18, 0x27, 0x30, 0x34, 0x35, 0x36,
    0x80, 0x81, 0x82, 0x83, 0x84, 0x85,
    0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A,
    0xA4,
};
constexpr std::size_t kRegisterCount = sizeof(kRegisters);
static_assert(kRegisterCount < 32, "read validity must fit in a uint32_t");
constexpr uint32_t kAllRead = (1U << kRegisterCount) - 1;

struct ReadGroup { uint8_t first; uint8_t count; };
constexpr ReadGroup kReadGroups[] = {
    {0x00, 2}, {0x18, 1}, {0x27, 1}, {0x30, 1},
    {0x34, 3}, {0x80, 6}, {0x90, 11}, {0xA4, 1},
};

struct PmicSnapshot {
  uint32_t validMask;
  uint32_t elapsedMs;
  uint8_t bytes[kRegisterCount];
};

inline int indexOf(uint8_t address) {
  for (std::size_t i = 0; i < kRegisterCount; ++i)
    if (kRegisters[i] == address) return static_cast<int>(i);
  return -1;
}

inline bool get(const PmicSnapshot &s, uint8_t address, uint8_t &value) {
  const int i = indexOf(address);
  if (i < 0 || (s.validMask & (1U << i)) == 0) return false;
  value = s.bytes[i];
  return true;
}

inline void put(PmicSnapshot &s, uint8_t address, uint8_t value) {
  const int i = indexOf(address);
  if (i < 0) return;
  s.bytes[i] = value;
  s.validMask |= 1U << i;
}

// Stops at the first failed transfer or expired budget; no retries, probing,
// bus recovery, ADC enabling, or reinterpretation of unread bytes as zero.
// A transfer already in progress retains the shared bus's existing timeout.
template <typename Read, typename Now>
PmicSnapshot samplePmic(Read read, Now now) {
  PmicSnapshot s{};
  const uint32_t start = now();
  for (const auto &group : kReadGroups) {
    if (static_cast<uint32_t>(now() - start) >= kReadBudgetMs) break;
    uint8_t bytes[11] = {};
    if (!read(group.first, bytes, group.count)) break;
    for (uint8_t i = 0; i < group.count; ++i)
      put(s, static_cast<uint8_t>(group.first + i), bytes[i]);
  }
  s.elapsedMs = static_cast<uint32_t>(now() - start);
  return s;
}

inline int batteryPresent(const PmicSnapshot &s) {
  uint8_t status = 0;
  return get(s, 0x00, status) ? ((status & 0x08) != 0 ? 1 : 0) : -1;
}

inline int batteryPercent(const PmicSnapshot &s) {
  uint8_t gauge = 0, percent = 0;
  if (batteryPresent(s) != 1 || !get(s, 0x18, gauge) ||
      (gauge & 0x08) == 0 || !get(s, 0xA4, percent) || percent > 100)
    return -1;
  return percent;
}

inline int batteryMillivolts(const PmicSnapshot &s) {
  uint8_t adc = 0, high = 0, low = 0, tsHigh = 0;
  if (batteryPresent(s) != 1 || !get(s, 0x30, adc) || (adc & 1) == 0 ||
      !get(s, 0x34, high) || !get(s, 0x35, low) || !get(s, 0x36, tsHigh))
    return -1;
  // REG34[7:6] + REG36[6] can repurpose ADC channels. Decode only the
  // documented normal mode; preserve all other modes as raw evidence.
  if ((high & 0xC0) != 0 || (tsHigh & 0x40) != 0) return -1;
  const int mv = ((high & 0x3F) << 8) | low;
  // Zero is also the power-on/unconverted register value. We cannot establish
  // sample age from these registers, even for a plausible nonzero result.
  return mv > 0 && mv <= 6000 ? mv : -1;
}

enum class Stage : uint8_t { Requested = 1, PeripheralsReturned, Entering };

struct Capsule {
  uint32_t magic;
  uint16_t schema;
  uint16_t size;
  uint32_t fingerprint;
  uint32_t bootSequence;
  uint32_t attemptHigh;
  uint32_t attemptLow;
  int64_t entryEpochUs;
  uint64_t requestedWakeMask;
  uint32_t configuredTimeoutSeconds;
  uint32_t requestUptimeMs;
  uint32_t acceptedRequestRecords;
  int32_t wifiStopResult;
  int32_t bluetoothStopResult;
  int32_t bluedroidStopResult;
  int32_t wakeConfigResult;
  PmicSnapshot pmic;
  uint8_t stage;
  uint8_t connected;
  uint8_t displayState;
  uint8_t audioPlaying;
  uint8_t diagnosticsStorageAvailable;
  uint8_t recorderSealed;
  uint8_t panelOffRequested;
  uint8_t panelChangeApplied;
  uint8_t spiEndCalled;
  uint8_t wireEndCalled;
  uint8_t bootPinLevel;
  uint8_t reserved;
  uint32_t checksum;
};
static_assert(std::is_trivial<Capsule>::value &&
              std::is_standard_layout<Capsule>::value, "RTC envelope must be POD");
static_assert(sizeof(Capsule) <= 192, "keep retained diagnostics bounded");

inline uint32_t checksum(const Capsule &s) {
  const auto *bytes = reinterpret_cast<const uint8_t *>(&s);
  uint32_t hash = 2166136261U;
  for (std::size_t i = 0; i < offsetof(Capsule, checksum); ++i) {
    hash ^= bytes[i];
    hash *= 16777619U;
  }
  return hash;
}

inline void seal(Capsule &s) {
  s.magic = kMagic;
  s.schema = kSchema;
  s.size = sizeof(Capsule);
  s.checksum = checksum(s);
}

inline bool valid(const Capsule &s) {
  return s.magic == kMagic && s.schema == kSchema && s.size == sizeof(Capsule) &&
         s.fingerprint != 0 && s.bootSequence != 0 &&
         s.stage >= static_cast<uint8_t>(Stage::Requested) &&
         s.stage <= static_cast<uint8_t>(Stage::Entering) &&
         (s.pmic.validMask & ~kAllRead) == 0 && s.checksum == checksum(s);
}

struct Resume {
  Capsule previous;
  bool previousValid;
  bool sameFirmware;
  bool confirmedDeepSleep;
  bool intervalValid;
  uint64_t intervalMs;
  const char *code;
};

inline Resume consume(Capsule &retained, uint32_t fingerprint,
                      uint32_t resetReason, uint32_t wakeCause,
                      int64_t observedEpochUs) {
  Resume r{};
  // Only a deep-sleep reset can confirm entry. A reset/watchdog with a valid
  // intent is an interruption, not evidence of a completed sleep interval.
  r.previousValid = resetReason != 1 && valid(retained);
  if (r.previousValid) r.previous = retained;
  std::memset(&retained, 0, sizeof(retained)); // consume once; no stale replay
  r.sameFirmware = r.previousValid && r.previous.fingerprint == fingerprint;
  r.confirmedDeepSleep = r.sameFirmware && resetReason == 8 && wakeCause != 0 &&
      r.previous.stage == static_cast<uint8_t>(Stage::Entering);
  r.code = !r.previousValid ? "no_retained_request" :
           !r.sameFirmware ? "firmware_changed" :
           r.confirmedDeepSleep ? "confirmed_deep_sleep" : "interrupted_or_reset";
  if (r.confirmedDeepSleep && r.previous.entryEpochUs >= kMinimumEpochUs &&
      observedEpochUs >= r.previous.entryEpochUs &&
      observedEpochUs - r.previous.entryEpochUs <= kMaximumIntervalUs) {
    r.intervalValid = true;
    r.intervalMs = static_cast<uint64_t>(
        (observedEpochUs - r.previous.entryEpochUs) / 1000);
  }
  return r;
}

inline bool formatRegisters(const PmicSnapshot &s, char *out, std::size_t size) {
  if (out == nullptr || size == 0) return false;
  std::size_t used = 0;
  for (std::size_t i = 0; i < kRegisterCount; ++i) {
    const char *separator = i == 0 ? "" : ";";
    const int n = (s.validMask & (1U << i)) != 0
        ? std::snprintf(out + used, size - used, "%s%02X=%02X", separator,
                        kRegisters[i], s.bytes[i])
        : std::snprintf(out + used, size - used, "%s%02X=??", separator,
                        kRegisters[i]);
    if (n < 0 || static_cast<std::size_t>(n) >= size - used) {
      out[0] = '\0';
      return false;
    }
    used += static_cast<std::size_t>(n);
  }
  return true;
}

inline const char *knownBool(int value) {
  return value < 0 ? "unknown" : value == 0 ? "0" : "1";
}

inline bool formatBattery(const PmicSnapshot &s, char *out, std::size_t size) {
  if (out == nullptr || size == 0) return false;
  const int percent = batteryPercent(s), mv = batteryMillivolts(s);
  char percentText[12] = "unknown", mvText[12] = "unknown";
  if (percent >= 0) std::snprintf(percentText, sizeof(percentText), "%d", percent);
  if (mv >= 0) std::snprintf(mvText, sizeof(mvText), "%d", mv);
  uint8_t status0 = 0, status1 = 0;
  const int vbus = get(s, 0x00, status0) ? ((status0 & 0x20) != 0) : -1;
  char direction[12] = "unknown";
  if (get(s, 0x01, status1))
    std::snprintf(direction, sizeof(direction), "%u", (status1 >> 5) & 3);
  const int n = std::snprintf(out, size,
      "present=%s;percent=%s;voltage_mV=%s;vbus=%s;direction_code=%s;"
      "sample_age=unknown;current_mA=unsupported",
      knownBool(batteryPresent(s)), percentText, mvText, knownBool(vbus), direction);
  return n >= 0 && static_cast<std::size_t>(n) < size;
}

// Compatible with the existing closed ride_diagnostics field vocabulary.
// The versioned, bounded state string contains hardware state (not counters
// masquerading as measurements); raw registers retain explicit unknowns.
inline bool formatObservation(const char *phase, const char *domain,
                              const char *attemptId, const char *state,
                              bool available, char *out, std::size_t size) {
  if (!phase || !domain || !attemptId || !state || !out || size == 0 ||
      std::strlen(state) > 256) return false;
  // All inputs come from fixed enum names/formatters. Reject JSON metacharacters
  // rather than silently changing evidence if a future producer violates this.
  for (const char *text : {phase, domain, attemptId, state}) {
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(text);
         *p; ++p)
      if (*p < 0x20 || *p == '"' || *p == '\\') return false;
  }
  const int n = std::snprintf(out, size,
      "{\"schemaVersion\":1,\"phase\":\"%s\",\"domain\":\"%s\","
      "\"attemptId\":\"%s\",\"state\":\"%s\",\"available\":%s}",
      phase, domain, attemptId, state, available ? "true" : "false");
  return n >= 0 && static_cast<std::size_t>(n) < size;
}

} // namespace sleep_audit::policy
