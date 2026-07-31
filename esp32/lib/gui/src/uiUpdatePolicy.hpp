#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace ui_update_policy {

constexpr uint32_t kRideStatsPeriodMs = 1000;
constexpr uint32_t kStatusPollPeriodMs = 1000;
constexpr uint32_t kDeviceBatteryPeriodMs = 5000;
constexpr uint32_t kWaitingBatteryPeriodMs = 30000;

enum class Source : uint8_t {
  Navigation = 0,
  Gps,
  Route,
  Workout,
  PhoneBattery,
  Settings,
  DeviceBattery,
  Count,
};

constexpr uint32_t sourceMask(Source source) {
  return 1U << static_cast<uint8_t>(source);
}

constexpr uint32_t kAllSources =
    (1U << static_cast<uint8_t>(Source::Count)) - 1U;

struct SourceSignatures {
  std::array<uint64_t, static_cast<std::size_t>(Source::Count)> values{};

  uint64_t &operator[](Source source) {
    return values[static_cast<std::size_t>(source)];
  }

  uint64_t operator[](Source source) const {
    return values[static_cast<std::size_t>(source)];
  }
};

class ChangeTracker {
public:
  uint32_t observe(const SourceSignatures &current) {
    uint32_t changed = 0;
    if (!initialized_) {
      changed = kAllSources;
      initialized_ = true;
    } else {
      for (uint8_t raw = 0; raw < static_cast<uint8_t>(Source::Count); ++raw) {
        const Source source = static_cast<Source>(raw);
        if (current[source] != previous_[source]) {
          changed |= sourceMask(source);
        }
      }
    }
    previous_ = current;
    pending_ |= changed;
    return changed;
  }

  bool take(Source source) {
    const uint32_t mask = sourceMask(source);
    const bool wasPending = (pending_ & mask) != 0;
    pending_ &= ~mask;
    return wasPending;
  }

  uint32_t take(uint32_t mask) {
    const uint32_t result = pending_ & mask;
    pending_ &= ~mask;
    return result;
  }

  void mark(Source source) { pending_ |= sourceMask(source); }
  uint32_t pending() const { return pending_; }

private:
  bool initialized_ = false;
  SourceSignatures previous_{};
  uint32_t pending_ = 0;
};

inline bool cadenceDue(uint32_t nowMs, uint32_t &lastRunMs,
                       uint32_t periodMs) {
  if (lastRunMs != 0 && static_cast<uint32_t>(nowMs - lastRunMs) < periodMs) {
    return false;
  }
  lastRunMs = nowMs == 0 ? 1 : nowMs;
  return true;
}

constexpr uint32_t nextMinuteDelayMs(uint8_t second, uint16_t millisecond = 0) {
  const uint32_t elapsedInMinute =
      static_cast<uint32_t>(second % 60U) * 1000U +
      static_cast<uint32_t>(millisecond % 1000U);
  return elapsedInMinute == 0 ? 60000U : 60000U - elapsedInMinute;
}

enum StatusMutation : uint8_t {
  StatusNone = 0,
  StatusGpsCount = 1U << 0,
  StatusGpsFix = 1U << 1,
  StatusWifi = 1U << 2,
  StatusSd = 1U << 3,
  StatusBattery = 1U << 4,
};

struct StatusSnapshot {
  uint8_t satellites = 0;
  uint8_t fixMode = 0;
  bool fixed = false;
  bool wifiConnected = false;
  bool sdLoaded = false;
  int16_t batteryLevel = -1;
  bool batteryCharging = false;
  bool batteryAvailable = false;
};

constexpr uint8_t statusMutations(const StatusSnapshot &previous,
                                  const StatusSnapshot &current) {
  uint8_t mutations = StatusNone;
  if (previous.satellites != current.satellites) {
    mutations |= StatusGpsCount;
  }
  if (previous.fixMode != current.fixMode || previous.fixed != current.fixed) {
    mutations |= StatusGpsFix;
  }
  if (previous.wifiConnected != current.wifiConnected) {
    mutations |= StatusWifi;
  }
  if (previous.sdLoaded != current.sdLoaded) {
    mutations |= StatusSd;
  }
  if (previous.batteryLevel != current.batteryLevel ||
      previous.batteryCharging != current.batteryCharging ||
      previous.batteryAvailable != current.batteryAvailable) {
    mutations |= StatusBattery;
  }
  return mutations;
}

} // namespace ui_update_policy
