#pragma once

#include <cstdint>

namespace ownership_button_policy {

class ComparisonRenderGate {
public:
  void request(uint32_t pairingGeneration) {
    pendingGeneration_ = pairingGeneration;
    renderedGeneration_ = 0;
  }

  void cancel() {
    pendingGeneration_ = 0;
    renderedGeneration_ = 0;
  }

  void displayFlushed() {
    if (pendingGeneration_ != 0) {
      renderedGeneration_ = pendingGeneration_;
    }
  }

  uint32_t renderedGeneration() const { return renderedGeneration_; }

  bool consumeRendered(uint32_t pairingGeneration) {
    if (pairingGeneration == 0 ||
        pairingGeneration != pendingGeneration_ ||
        pairingGeneration != renderedGeneration_) {
      return false;
    }
    cancel();
    return true;
  }

private:
  uint32_t pendingGeneration_ = 0;
  uint32_t renderedGeneration_ = 0;
};

class FreshBootButtonGate {
public:
  void arm() {
    requiresStableRelease_ = true;
    releaseStartMs_ = 0;
  }

  bool blocksInput(bool pressed, uint32_t nowMs, uint32_t debounceMs) {
    if (!requiresStableRelease_) {
      return false;
    }
    if (pressed) {
      releaseStartMs_ = 0;
      return true;
    }
    if (releaseStartMs_ == 0) {
      releaseStartMs_ = nowMs;
      return true;
    }
    if (nowMs - releaseStartMs_ < debounceMs) {
      return true;
    }
    requiresStableRelease_ = false;
    releaseStartMs_ = 0;
    return true;
  }

private:
  bool requiresStableRelease_ = false;
  uint32_t releaseStartMs_ = 0;
};

class FreshPowerButtonGate {
public:
  void arm(uint32_t pairingGeneration) {
    pairingGeneration_ = pairingGeneration;
    sawPressEdge_ = false;
  }

  void cancel() {
    pairingGeneration_ = 0;
    sawPressEdge_ = false;
  }

  bool acceptEvents(uint32_t pairingGeneration, bool negativeEdge,
                    bool positiveEdge, bool shortPress) {
    if (pairingGeneration == 0 || pairingGeneration != pairingGeneration_) {
      return false;
    }
    if (negativeEdge) {
      sawPressEdge_ = true;
    }
    if (!sawPressEdge_ || (!positiveEdge && !shortPress)) {
      return false;
    }
    // Consume the tap, but retain the generation so a transient failure in
    // the confirmation handler can be retried only with another fresh tap.
    sawPressEdge_ = false;
    return true;
  }

private:
  uint32_t pairingGeneration_ = 0;
  bool sawPressEdge_ = false;
};

template <typename ConfirmPairing, typename Fallback>
bool handleShortPress(ConfirmPairing confirmPairing, Fallback fallback) {
  if (confirmPairing()) {
    return true;
  }
  fallback();
  return false;
}

inline bool shouldRecoverOwner(uint32_t pressDurationMs,
                               bool handledPairingConfirmation) {
  return pressDurationMs >= 8000 && !handledPairingConfirmation;
}

} // namespace ownership_button_policy
