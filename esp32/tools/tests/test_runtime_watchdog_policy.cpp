#include "../../lib/runtime_watchdog_diagnostics/runtime_watchdog_policy.hpp"

#include <cassert>
#include <cstring>
#include <iostream>
#include <type_traits>

int main() {
  using namespace runtime_watchdog_diagnostics::policy;

  static_assert(std::is_trivial<RetainedRoleSlot>::value,
                "RTC role slots must not have startup initialization");
  static_assert(std::is_trivial<RetainedTrigger>::value,
                "RTC trigger must not have startup initialization");
  static_assert(std::is_trivial<RetainedState>::value,
                "RTC state must remain byte-preserving storage");

  RetainedState retained = {};
  PreviousSnapshot first = beginBoot(retained, 120, 0x12345678U, false);
  assert(!first.available);
  for (std::size_t index = 0; index < kRoleCount; ++index) {
    assert(valid(retained.roles[index]));
    assert(retained.roles[index].bootSequence == 120);
  }

  RetainedRoleSlot &ui = retained.roles[static_cast<std::size_t>(Role::Ui)];
  ui.phase = static_cast<uint8_t>(Phase::Loop);
  ui.core = 1;
  ui.priority = 1;
  ui.lastProgressUptimeMs = 2'775'900;
  seal(ui);

  RetainedRoleSlot &map =
      retained.roles[static_cast<std::size_t>(Role::MapRender)];
  map.phase = static_cast<uint8_t>(Phase::MapBlockIo);
  map.core = 0;
  map.priority = 0;
  map.lastProgressUptimeMs = 2'770'000;
  map.detail = 337;
  seal(map);

  RetainedRoleSlot &writer = retained.roles[
      static_cast<std::size_t>(Role::RideDiagnosticsWriter)];
  writer.phase = static_cast<uint8_t>(Phase::DiagnosticsFlush);
  writer.core = 1;
  writer.priority = 0;
  writer.lastProgressUptimeMs = 2'769'000;
  writer.detail = 336;
  seal(writer);

  retained.trigger.bootSequence = 120;
  retained.trigger.firmwareFingerprint = 0x12345678U;
  retained.trigger.watchdogUptimeMs = 2'776'000;
  retained.trigger.failingCoreMask = 1;
  seal(retained.trigger);

  PreviousSnapshot recovered =
      beginBoot(retained, 121, 0x12345678U, true);
  assert(recovered.available);
  assert(recovered.triggerValid);
  assert(recovered.bootSequence == 120);
  assert(recovered.trigger.failingCoreMask == 1);
  assert(std::strcmp(phaseName(recovered, Role::MapRender),
                     "map_block_io") == 0);
  assert(progressUptime(recovered, Role::MapRender) == 2'770'000);
  assert(detail(recovered, Role::MapRender) == 337);

  char fields[kMaximumFieldsBytes] = {};
  assert(formatPreviousFields(recovered, fields, sizeof(fields)));
  assert(std::strlen(fields) < kMaximumFieldsBytes);
  assert(std::strstr(fields, "\"watchdogCoreMask\":1") != nullptr);
  assert(std::strstr(fields, "\"uiPhase\":\"loop\"") != nullptr);
  assert(std::strstr(fields, "\"mapPhase\":\"map_block_io\"") !=
         nullptr);
  assert(std::strstr(fields,
                     "\"writerPhase\":\"diagnostics_flush\"") !=
         nullptr);
  assert(!formatPreviousFields(recovered, fields, 64));

  PreviousSnapshot maximum = recovered;
  maximum.bootSequence = UINT32_MAX;
  maximum.trigger.watchdogUptimeMs = UINT32_MAX;
  maximum.trigger.failingCoreMask = UINT32_MAX;
  for (std::size_t index = 0; index < kRoleCount; ++index) {
    maximum.roles[index].lastProgressUptimeMs = UINT32_MAX;
    maximum.roles[index].detail = UINT32_MAX;
  }
  maximum.roles[static_cast<std::size_t>(Role::MapRender)].phase =
      static_cast<uint8_t>(Phase::MapBlockPlanning);
  maximum.roles[static_cast<std::size_t>(Role::RideDiagnosticsWriter)].phase =
      static_cast<uint8_t>(Phase::DiagnosticsRecovery);
  assert(formatPreviousFields(maximum, fields, sizeof(fields)));
  assert(std::strlen(fields) < kMaximumFieldsBytes);

  // A torn role update invalidates only that role. The trigger and other
  // independently sealed slots remain attributable after the reset.
  map = retained.roles[static_cast<std::size_t>(Role::MapRender)];
  map.phase = static_cast<uint8_t>(Phase::MapRaster);
  map.lastProgressUptimeMs = 50;
  seal(map);
  map.checksum ^= 1U;
  ui = retained.roles[static_cast<std::size_t>(Role::Ui)];
  ui.phase = static_cast<uint8_t>(Phase::Loop);
  ui.lastProgressUptimeMs = 55;
  seal(ui);
  retained.trigger.bootSequence = 121;
  retained.trigger.firmwareFingerprint = 0x12345678U;
  retained.trigger.watchdogUptimeMs = 60;
  retained.trigger.failingCoreMask = 1;
  seal(retained.trigger);

  PreviousSnapshot partial =
      beginBoot(retained, 122, 0x12345678U, true);
  assert(partial.available);
  assert(partial.triggerValid);
  assert(partial.roleValid[static_cast<std::size_t>(Role::Ui)]);
  assert(!partial.roleValid[static_cast<std::size_t>(Role::MapRender)]);
  assert(std::strcmp(phaseName(partial, Role::MapRender), "unavailable") ==
         0);

  // Power/deep-sleep resets and a different firmware identity never expose
  // stale runtime state as watchdog evidence.
  PreviousSnapshot nonWatchdog =
      beginBoot(retained, 123, 0x12345678U, false);
  assert(!nonWatchdog.available);
  retained.roles[0].bootSequence = 123;
  seal(retained.roles[0]);
  PreviousSnapshot differentFirmware =
      beginBoot(retained, 124, 0x87654321U, true);
  assert(!differentFirmware.available);

  // Repeated retained-state rotations preserve independently sealed roles,
  // including when every seventh simulated reset tears the map slot.
  RetainedState stress = {};
  (void)beginBoot(stress, 1, 0xA5A5A5A5U, false);
  for (uint32_t boot = 1; boot <= 2000; ++boot) {
    for (std::size_t index = 0; index < kRoleCount; ++index) {
      RetainedRoleSlot &slot = stress.roles[index];
      slot.phase = static_cast<uint8_t>(
          index == static_cast<std::size_t>(Role::MapRender)
              ? Phase::MapRaster
              : Phase::Waiting);
      slot.lastProgressUptimeMs = boot * 1000U + index;
      slot.detail = boot;
      seal(slot);
    }
    const bool tornMap = (boot % 7U) == 0;
    if (tornMap) {
      stress.roles[static_cast<std::size_t>(Role::MapRender)].checksum ^= 1U;
    }
    stress.trigger.bootSequence = boot;
    stress.trigger.firmwareFingerprint = 0xA5A5A5A5U;
    stress.trigger.watchdogUptimeMs = boot * 1000U + 999U;
    stress.trigger.failingCoreMask = 1;
    seal(stress.trigger);

    PreviousSnapshot snapshot =
        beginBoot(stress, boot + 1U, 0xA5A5A5A5U, true);
    assert(snapshot.available);
    assert(snapshot.triggerValid);
    assert(snapshot.roleValid[static_cast<std::size_t>(Role::Ui)]);
    assert(snapshot.roleValid[
        static_cast<std::size_t>(Role::RideDiagnosticsWriter)]);
    assert(snapshot.roleValid[static_cast<std::size_t>(Role::MapRender)] ==
           !tornMap);
    assert(formatPreviousFields(snapshot, fields, sizeof(fields)));
  }

  std::cout << "runtime watchdog policy tests passed\n";
  return 0;
}
