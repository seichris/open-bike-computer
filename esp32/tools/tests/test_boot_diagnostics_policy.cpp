#include "../../lib/boot_diagnostics/boot_diagnostics_policy.hpp"

#include <cassert>
#include <cstring>

namespace {

using boot_diagnostics::policy::PersistentState;
using boot_diagnostics::policy::Stage;

constexpr uint32_t kFirmwareA = 0x11223344;
constexpr uint32_t kFirmwareB = 0x55667788;

void enterAndCrash(PersistentState &state, Stage stage) {
  assert(boot_diagnostics::policy::enterStage(state, stage));
}

} // namespace

int main() {
  using namespace boot_diagnostics::policy;

  static_assert(kSafeModeFailureThreshold == 3);
  assert(std::strcmp(stageName(Stage::PmicInspection),
                     "pmic_inspection") == 0);

  PersistentState state{};
  BeginResult first = beginBoot(state, kFirmwareA, 1, true);
  assert(!first.previousValid);
  assert(!first.safeMode);
  assert(isValid(state));
  assert(state.bootSequence == 1);
  assert(state.activeStage == static_cast<uint8_t>(Stage::Startup));

  assert(completeStage(state, Stage::Startup));
  assert(enterStage(state, Stage::CoreServices));
  assert(completeStage(state, Stage::CoreServices));
  assert(state.activeStage == static_cast<uint8_t>(Stage::None));
  assert(state.completedStage == static_cast<uint8_t>(Stage::CoreServices));
  assert(markReady(state));
  assert(isReady(state));

  BeginResult afterReady = beginBoot(state, kFirmwareA, 11, false);
  assert(afterReady.previousValid);
  assert(afterReady.previousSameFirmware);
  assert(!afterReady.failureRecorded);
  assert(state.bootSequence == 2);
  assert(state.consecutiveEarlyFailures == 0);

  // Three unfinished boots of the same exact image trigger the fourth boot's
  // minimal safe mode and retain the actual failing stage.
  enterAndCrash(state, Stage::Display);
  BeginResult secondAttempt = beginBoot(state, kFirmwareA, 4, false);
  assert(secondAttempt.failureRecorded);
  assert(!secondAttempt.safeMode);
  assert(state.consecutiveEarlyFailures == 1);
  assert(state.lastFailureStage == static_cast<uint8_t>(Stage::Display));

  enterAndCrash(state, Stage::Display);
  BeginResult thirdAttempt = beginBoot(state, kFirmwareA, 6, false);
  assert(thirdAttempt.failureRecorded);
  assert(!thirdAttempt.safeMode);
  assert(state.consecutiveEarlyFailures == 2);

  enterAndCrash(state, Stage::Display);
  BeginResult safeAttempt = beginBoot(state, kFirmwareA, 9, false);
  assert(safeAttempt.failureRecorded);
  assert(safeAttempt.safeMode);
  assert(isSafeMode(state));
  assert(state.consecutiveEarlyFailures == 3);
  assert(state.lastFailureStage == static_cast<uint8_t>(Stage::Display));
  assert(!enterStage(state, Stage::I2cBus));
  assert(!markReady(state));

  // Rebooting the deliberate hold does not count it as another failed
  // peripheral initialization or erase the original failing stage.
  BeginResult heldAgain = beginBoot(state, kFirmwareA, 3, false);
  assert(!heldAgain.failureRecorded);
  assert(heldAgain.safeMode);
  assert(state.consecutiveEarlyFailures == 3);
  assert(state.lastFailureStage == static_cast<uint8_t>(Stage::Display));

  // A newly built firmware is allowed to try again without requiring a power
  // cycle, while a true cold power-on also clears retained failure history.
  BeginResult newFirmware = beginBoot(state, kFirmwareB, 11, false);
  assert(newFirmware.previousValid);
  assert(!newFirmware.previousSameFirmware);
  assert(!newFirmware.safeMode);
  assert(state.bootSequence == 1);
  assert(state.consecutiveEarlyFailures == 0);

  enterAndCrash(state, Stage::PmicInspection);
  BeginResult coldBoot = beginBoot(state, kFirmwareB, 1, true);
  assert(coldBoot.previousValid);
  assert(coldBoot.coldStart);
  assert(!coldBoot.failureRecorded);
  assert(!coldBoot.safeMode);
  assert(state.bootSequence == 1);
  assert(state.consecutiveEarlyFailures == 0);

  PersistentState corrupt = state;
  corrupt.activeStage = 0xFF;
  assert(!isValid(corrupt));
  BeginResult recovered = beginBoot(corrupt, kFirmwareB, 3, false);
  assert(!recovered.previousValid);
  assert(isValid(corrupt));
  assert(corrupt.bootSequence == 1);

  return 0;
}
