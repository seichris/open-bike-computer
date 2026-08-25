#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace runtime_watchdog_diagnostics::policy {

constexpr uint32_t kSlotMagic = 0x57445453U;    // WDTS
constexpr uint32_t kTriggerMagic = 0x57445454U; // WDTT
constexpr uint8_t kSchema = 1;
constexpr uint8_t kUnavailable = 0xFFU;
constexpr std::size_t kMaximumFieldsBytes = 320;

enum class Role : uint8_t {
  Ui = 0,
  MapRender = 1,
  RideDiagnosticsWriter = 2,
  Count,
};

enum class Phase : uint8_t {
  Unregistered = 0,
  Setup,
  Loop,
  Waiting,
  MapActivation,
  MapBlockPlanning,
  MapBlockIo,
  MapBlockParse,
  MapRaster,
  DiagnosticsWrite,
  DiagnosticsFlush,
  DiagnosticsRecovery,
};

constexpr std::size_t kRoleCount = static_cast<std::size_t>(Role::Count);

struct RetainedRoleSlot {
  uint32_t magic;
  uint32_t bootSequence;
  uint32_t firmwareFingerprint;
  uint32_t lastProgressUptimeMs;
  uint32_t detail;
  uint32_t checksum;
  uint16_t size;
  uint8_t schema;
  uint8_t role;
  uint8_t phase;
  uint8_t core;
  uint8_t priority;
  uint8_t reserved;
};

struct RetainedTrigger {
  uint32_t magic;
  uint32_t bootSequence;
  uint32_t firmwareFingerprint;
  uint32_t watchdogUptimeMs;
  uint32_t failingCoreMask;
  uint32_t checksum;
  uint16_t size;
  uint8_t schema;
  uint8_t reserved;
};

struct RetainedState {
  RetainedRoleSlot roles[kRoleCount];
  RetainedTrigger trigger;
};

struct PreviousSnapshot {
  bool available = false;
  bool triggerValid = false;
  uint32_t bootSequence = 0;
  RetainedTrigger trigger = {};
  bool roleValid[kRoleCount] = {};
  RetainedRoleSlot roles[kRoleCount] = {};
};

inline uint32_t mix(uint32_t hash, uint32_t value) {
  hash ^= value;
  hash *= 16777619U;
  return hash;
}

inline uint32_t roleChecksum(const RetainedRoleSlot &slot) {
  uint32_t hash = 2166136261U;
  hash = mix(hash, slot.magic);
  hash = mix(hash, slot.bootSequence);
  hash = mix(hash, slot.firmwareFingerprint);
  hash = mix(hash, slot.lastProgressUptimeMs);
  hash = mix(hash, slot.detail);
  hash = mix(hash, slot.size);
  hash = mix(hash, slot.schema);
  hash = mix(hash, slot.role);
  hash = mix(hash, slot.phase);
  hash = mix(hash, slot.core);
  hash = mix(hash, slot.priority);
  return hash;
}

inline uint32_t triggerChecksum(const RetainedTrigger &trigger) {
  uint32_t hash = 2166136261U;
  hash = mix(hash, trigger.magic);
  hash = mix(hash, trigger.bootSequence);
  hash = mix(hash, trigger.firmwareFingerprint);
  hash = mix(hash, trigger.watchdogUptimeMs);
  hash = mix(hash, trigger.failingCoreMask);
  hash = mix(hash, trigger.size);
  hash = mix(hash, trigger.schema);
  return hash;
}

inline void seal(RetainedRoleSlot &slot) {
  slot.magic = kSlotMagic;
  slot.schema = kSchema;
  slot.size = sizeof(RetainedRoleSlot);
  slot.checksum = roleChecksum(slot);
}

inline void seal(RetainedTrigger &trigger) {
  trigger.magic = kTriggerMagic;
  trigger.schema = kSchema;
  trigger.size = sizeof(RetainedTrigger);
  trigger.checksum = triggerChecksum(trigger);
}

inline bool valid(const RetainedRoleSlot &slot) {
  return slot.magic == kSlotMagic && slot.schema == kSchema &&
         slot.size == sizeof(RetainedRoleSlot) &&
         slot.role < static_cast<uint8_t>(Role::Count) &&
         slot.phase <= static_cast<uint8_t>(Phase::DiagnosticsRecovery) &&
         slot.checksum == roleChecksum(slot);
}

inline bool valid(const RetainedTrigger &trigger) {
  return trigger.magic == kTriggerMagic && trigger.schema == kSchema &&
         trigger.size == sizeof(RetainedTrigger) &&
         trigger.checksum == triggerChecksum(trigger);
}

inline RetainedRoleSlot initialRoleSlot(Role role, uint32_t bootSequence,
                                        uint32_t firmwareFingerprint) {
  RetainedRoleSlot slot = {};
  slot.bootSequence = bootSequence;
  slot.firmwareFingerprint = firmwareFingerprint;
  slot.role = static_cast<uint8_t>(role);
  slot.phase = static_cast<uint8_t>(Phase::Unregistered);
  slot.core = kUnavailable;
  slot.priority = kUnavailable;
  seal(slot);
  return slot;
}

inline PreviousSnapshot beginBoot(RetainedState &state,
                                  uint32_t currentBootSequence,
                                  uint32_t currentFirmwareFingerprint,
                                  bool taskWatchdogReset) {
  PreviousSnapshot previous = {};
  if (taskWatchdogReset) {
    const bool triggerMatches =
        valid(state.trigger) &&
        state.trigger.bootSequence != currentBootSequence &&
        state.trigger.firmwareFingerprint == currentFirmwareFingerprint;
    if (triggerMatches) {
      previous.triggerValid = true;
      previous.trigger = state.trigger;
      previous.bootSequence = state.trigger.bootSequence;
    }

    if (previous.bootSequence == 0) {
      for (std::size_t index = 0; index < kRoleCount; ++index) {
        const RetainedRoleSlot &slot = state.roles[index];
        if (valid(slot) && slot.bootSequence != currentBootSequence &&
            slot.firmwareFingerprint == currentFirmwareFingerprint) {
          previous.bootSequence = slot.bootSequence;
          break;
        }
      }
    }

    if (previous.bootSequence != 0) {
      for (std::size_t index = 0; index < kRoleCount; ++index) {
        const RetainedRoleSlot &slot = state.roles[index];
        const Role expectedRole = static_cast<Role>(index);
        if (valid(slot) && slot.bootSequence == previous.bootSequence &&
            slot.firmwareFingerprint == currentFirmwareFingerprint &&
            slot.role == static_cast<uint8_t>(expectedRole)) {
          previous.roleValid[index] = true;
          previous.roles[index] = slot;
          previous.available = true;
        }
      }
    }
    previous.available = previous.available || previous.triggerValid;
  }

  state = {};
  for (std::size_t index = 0; index < kRoleCount; ++index) {
    state.roles[index] = initialRoleSlot(
        static_cast<Role>(index), currentBootSequence,
        currentFirmwareFingerprint);
  }
  return previous;
}

inline const char *phaseName(const PreviousSnapshot &snapshot, Role role) {
  const std::size_t index = static_cast<std::size_t>(role);
  if (index >= kRoleCount || !snapshot.roleValid[index])
    return "unavailable";
  switch (static_cast<Phase>(snapshot.roles[index].phase)) {
  case Phase::Unregistered:
    return "unregistered";
  case Phase::Setup:
    return "setup";
  case Phase::Loop:
    return "loop";
  case Phase::Waiting:
    return "waiting";
  case Phase::MapActivation:
    return "map_activation";
  case Phase::MapBlockPlanning:
    return "map_block_planning";
  case Phase::MapBlockIo:
    return "map_block_io";
  case Phase::MapBlockParse:
    return "map_block_parse";
  case Phase::MapRaster:
    return "map_raster";
  case Phase::DiagnosticsWrite:
    return "diagnostics_write";
  case Phase::DiagnosticsFlush:
    return "diagnostics_flush";
  case Phase::DiagnosticsRecovery:
    return "diagnostics_recovery";
  }
  return "unknown";
}

inline uint32_t progressUptime(const PreviousSnapshot &snapshot, Role role) {
  const std::size_t index = static_cast<std::size_t>(role);
  return index < kRoleCount && snapshot.roleValid[index]
             ? snapshot.roles[index].lastProgressUptimeMs
             : 0;
}

inline uint32_t detail(const PreviousSnapshot &snapshot, Role role) {
  const std::size_t index = static_cast<std::size_t>(role);
  return index < kRoleCount && snapshot.roleValid[index]
             ? snapshot.roles[index].detail
             : 0;
}

inline bool formatPreviousFields(const PreviousSnapshot &snapshot, char *out,
                                 std::size_t capacity) {
  if (!snapshot.available || out == nullptr || capacity == 0)
    return false;
  const int written = std::snprintf(
      out, capacity,
      "{\"runtimeBootSequence\":%lu,"
      "\"watchdogCoreMask\":%lu,\"watchdogUptimeMs\":%lu,"
      "\"uiPhase\":\"%s\",\"uiProgressMs\":%lu,"
      "\"mapPhase\":\"%s\",\"mapProgressMs\":%lu,"
      "\"mapDetail\":%lu,\"writerPhase\":\"%s\","
      "\"writerProgressMs\":%lu,\"writerDetail\":%lu}",
      static_cast<unsigned long>(snapshot.bootSequence),
      static_cast<unsigned long>(snapshot.triggerValid
                                     ? snapshot.trigger.failingCoreMask
                                     : 0),
      static_cast<unsigned long>(snapshot.triggerValid
                                     ? snapshot.trigger.watchdogUptimeMs
                                     : 0),
      phaseName(snapshot, Role::Ui),
      static_cast<unsigned long>(progressUptime(snapshot, Role::Ui)),
      phaseName(snapshot, Role::MapRender),
      static_cast<unsigned long>(progressUptime(snapshot, Role::MapRender)),
      static_cast<unsigned long>(detail(snapshot, Role::MapRender)),
      phaseName(snapshot, Role::RideDiagnosticsWriter),
      static_cast<unsigned long>(
          progressUptime(snapshot, Role::RideDiagnosticsWriter)),
      static_cast<unsigned long>(
          detail(snapshot, Role::RideDiagnosticsWriter)));
  return written > 0 && static_cast<std::size_t>(written) < capacity &&
         static_cast<std::size_t>(written) < kMaximumFieldsBytes;
}

} // namespace runtime_watchdog_diagnostics::policy
