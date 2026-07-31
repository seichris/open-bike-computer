#pragma once

namespace power_management {

// Level-triggered GPIO wake sources remain active until the peripheral or
// button releases the line. Latch the first interrupt, mask the hardware
// interrupt in the ISR, then re-arm it only after the source is inactive.
class ActiveLowWakeInterruptGate {
public:
  bool latch() {
    if (masked_) {
      return false;
    }
    masked_ = true;
    return true;
  }

  bool rearmIfInactive(bool sourceActive) {
    if (!masked_ || sourceActive) {
      return false;
    }
    masked_ = false;
    return true;
  }

  bool masked() const { return masked_; }

private:
  volatile bool masked_ = false;
};

} // namespace power_management
