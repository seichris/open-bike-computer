#pragma once

#include "navigation_protocol.h"
#include <stddef.h>
#include <string.h>
#include <string>

class NavigationPayloadQueue {
public:
  bool enqueue(const std::string &value) {
    if (value.empty() || value.length() > NAV_PAYLOAD_MAX_LEN) {
      return false;
    }

    memcpy(payload_, value.data(), value.length());
    payload_[value.length()] = '\0';
    pending_ = true;
    return true;
  }

  bool dequeue(char *out, size_t outSize) {
    if (!pending_ || out == nullptr || outSize == 0) {
      return false;
    }

    strncpy(out, payload_, outSize);
    out[outSize - 1] = '\0';
    pending_ = false;
    return true;
  }

  bool hasPending() const {
    return pending_;
  }

private:
  char payload_[NAV_PAYLOAD_MAX_LEN + 1] = "";
  bool pending_ = false;
};
