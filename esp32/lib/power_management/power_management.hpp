#pragma once

#include "power_management_policy.hpp"

namespace power_management {

struct RuntimeStatus {
  bool enabled = false;
  Configuration requested = kDfsConfiguration;
  Configuration effective{};
  int errorCode = 0;
};

// Configure ESP-IDF dynamic frequency scaling once framework initialization is
// complete. A rejected request leaves the prior configuration intact. Any
// configuration or readback failure is exposed through status().
bool begin();
RuntimeStatus status();

} // namespace power_management
