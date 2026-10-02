#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace usb_recovery_status {
// One read-only command; no arbitrary reflection, allocation, shell, or writes.
class Request {
public:
  bool feed(char value, uint32_t now) {
    if (static_cast<uint32_t>(now - lastByte_) > 1000) reset();
    lastByte_ = now;
    if (value == '\n') {
      constexpr char prefix[] = "BICINO_USB_STATUS 1 ";
      const bool valid = !overflow_ && size_ == sizeof(prefix) - 1 + 32 &&
                         std::memcmp(line_, prefix, sizeof(prefix) - 1) == 0;
      bool hex = valid;
      if (valid) {
        for (std::size_t index = sizeof(prefix) - 1; index < size_; ++index) {
          const char ch = line_[index];
          if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) hex = false;
        }
      }
      if (hex) {
        std::memcpy(nonce_, line_ + sizeof(prefix) - 1, 32);
        nonce_[32] = 0;
      }
      reset();
      return hex;
    }
    if (size_ == sizeof(line_)) overflow_ = true;
    if (!overflow_) line_[size_++] = value;
    return false;
  }
  const char *nonce() const { return nonce_; }

private:
  void reset() { size_ = 0; overflow_ = false; }
  char line_[64]{};
  char nonce_[33]{};
  std::size_t size_ = 0;
  uint32_t lastByte_ = 0;
  bool overflow_ = false;
};
} // namespace usb_recovery_status
