#pragma once
#include "diagnostics_capture_policy.hpp"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace bicino_diagnostics {
struct SegmentDescriptor {
  uint32_t boot = 0, chunk = 0, bytes = 0;
  char sha256[65] = {};
  bool valid() const {
    if (boot == 0 || chunk == 0 || bytes == 0 || bytes > 256U * 1024U || std::strlen(sha256) != 64) return false;
    for (char c : std::string(sha256))
      if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
  }
  std::string encode() const {
    if (!valid()) return {};
    return "BDG2 " + std::to_string(boot) + " " + std::to_string(chunk) + " " + std::to_string(bytes) + " " + sha256 + "\n";
  }
};
inline bool decodeSegmentDescriptor(const std::string &text, SegmentDescriptor &out) {
  if (text.size() > 112 || text.rfind("BDG2 ", 0) != 0 || text.back() != '\n') return false;
  std::array<std::string, 4> parts;
  std::size_t cursor = 5;
  for (unsigned i = 0; i < 4; ++i) {
    const auto end = text.find(i == 3 ? '\n' : ' ', cursor);
    if (end == std::string::npos || (i == 3 && end + 1 != text.size())) return false;
    parts[i] = text.substr(cursor, end - cursor); cursor = end + 1;
  }
  SegmentDescriptor candidate;
  if (!unsignedDecimal(parts[0], candidate.boot) || !unsignedDecimal(parts[1], candidate.chunk) ||
      !unsignedDecimal(parts[2], candidate.bytes) || parts[3].size() != 64) return false;
  std::memcpy(candidate.sha256, parts[3].c_str(), sizeof(candidate.sha256));
  if (!candidate.valid()) return false;
  out = candidate; return true;
}

struct SegmentRange {
  uint32_t boot = 0, chunk = 0, offset = 0, length = 0;
  std::string hash;
};
// Bounded, content-addressed slices deliberately use path components rather
// than unvalidated Range headers or an unbounded query parser.
inline bool parseSegmentRange(const std::string &path, SegmentRange &out) {
  constexpr char prefix[] = "/device-diagnostics/v2/range/";
  if (path.size() > 180 || path.rfind(prefix, 0) != 0) return false;
  std::array<std::string, 5> parts;
  std::size_t cursor = sizeof(prefix) - 1;
  for (unsigned i = 0; i < parts.size(); ++i) {
    auto end = path.find('/', cursor);
    if ((i + 1 < parts.size()) == (end == std::string::npos)) return false;
    parts[i] = path.substr(cursor, end == std::string::npos ? end : end - cursor);
    cursor = end == std::string::npos ? path.size() : end + 1;
  }
  SegmentRange candidate;
  if (!unsignedDecimal(parts[0], candidate.boot) || !unsignedDecimal(parts[1], candidate.chunk) ||
      !unsignedDecimal(parts[3], candidate.offset) || !unsignedDecimal(parts[4], candidate.length) ||
      candidate.boot == 0 || candidate.chunk == 0 || candidate.offset >= 256U * 1024U ||
      candidate.length == 0 || candidate.length > 16U * 1024U ||
      candidate.length > 256U * 1024U - candidate.offset || parts[2].size() != 64) return false;
  for (char c : parts[2]) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  candidate.hash = parts[2]; out = candidate; return true;
}
} // namespace bicino_diagnostics
