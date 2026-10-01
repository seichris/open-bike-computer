#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <string_view>
#include "diagnostics_capture_policy.hpp"

namespace bicino_diagnostics {
struct TailRequest {
  uint32_t boot = 0, after = 0, limit = 8;
};
inline bool parseTailRequest(std::string_view value, TailRequest &request) {
  constexpr std::string_view prefix = "tail|2|";
  if (value.size() > 64 || value.substr(0, prefix.size()) != prefix) return false;
  value.remove_prefix(prefix.size());
  uint32_t numbers[3] = {};
  for (unsigned i = 0; i < 3; ++i) {
    const auto separator = value.find('|');
    if ((i < 2 && separator == std::string_view::npos) || (i == 2 && separator != std::string_view::npos)) return false;
    const auto token = i < 2 ? value.substr(0, separator) : value;
    if (!unsignedDecimal(std::string(token), numbers[i])) return false;
    if (i < 2) value.remove_prefix(separator + 1);
  }
  if (numbers[2] < 1 || numbers[2] > 8) return false;
  request = {numbers[0], numbers[1], numbers[2]};
  return true;
}

template<std::size_t Capacity = 128, std::size_t MaximumLine = 768>
class TailRing {
public:
  struct Entry { uint32_t sequence = 0; uint16_t length = 0; char line[MaximumLine] = {}; };
  struct Page {
    uint32_t boot = 0, oldest = 0, newest = 0, next = 0;
    bool bootChanged = false, gap = false, more = false;
    std::size_t count = 0;
    std::array<Entry, 8> events{};
  };
  void begin(uint32_t boot) { boot_ = boot; count_ = write_ = 0; }
  bool append(uint32_t sequence, const char *line, std::size_t length) {
    if (line == nullptr || length == 0 || length >= MaximumLine || line[length-1] != '\n') return false;
    auto &entry = entries_[write_]; entry.sequence = sequence; entry.length = static_cast<uint16_t>(length);
    std::memcpy(entry.line, line, length); entry.line[length] = '\0';
    write_ = (write_ + 1) % Capacity; if (count_ < Capacity) ++count_;
    return true;
  }
  void page(const TailRequest &request, Page &out) const {
    out.boot = boot_; out.bootChanged = request.boot != boot_;
    out.count = 0; out.more = false; out.gap = false; out.next = request.after;
    out.oldest = out.newest = 0;
    if (count_ == 0) return;
    const auto start = (write_ + Capacity - count_) % Capacity;
    out.oldest = entries_[start].sequence;
    out.newest = entries_[(write_ + Capacity - 1) % Capacity].sequence;
    out.gap = !out.bootChanged && request.after < out.oldest && out.oldest - request.after > 1;
    for (std::size_t index = 0; index < count_; ++index) {
      const auto &entry = entries_[(start + index) % Capacity];
      if (!out.bootChanged && entry.sequence <= request.after) continue;
      if (out.count >= request.limit || out.count >= out.events.size()) { out.more = true; break; }
      out.events[out.count++] = entry; out.next = entry.sequence;
    }
  }
private:
  uint32_t boot_ = 0;
  std::size_t count_ = 0, write_ = 0;
  std::array<Entry, Capacity> entries_{};
};
} // namespace bicino_diagnostics
