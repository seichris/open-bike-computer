#pragma once
#include "diagnostics_registry_identity.hpp"
#include <cstdint>
#include <cstring>
#include <string>
#include <array>

namespace ride_diagnostics::policy_v2 {
constexpr uint32_t kMaximumDurationSeconds = 4U * 60U * 60U;
constexpr uint32_t kMaximumBudgetBytes = 32U * 1024U * 1024U;
struct Request {
  char capture[37] = {};
  uint32_t generation = 0, mask = 0, minimumLevel = 0;
  uint32_t durationSeconds = 0, budgetBytes = 0;
};
struct State {
  Request request{};
  uint32_t deadline = 0, remaining = 0, filtered = 0;
  bool installed = false;
};
inline bool uuid(const std::string &s) {
  if (s.size() != 36) return false;
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return false; }
    else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
  }
  return true;
}
inline bool number(const std::string &s, uint32_t &out) {
  if (s.empty() || s.size() > 10) return false;
  uint64_t value = 0;
  for (char c : s) { if (c < '0' || c > '9') return false; value = value * 10 + unsigned(c - '0'); }
  if (value > UINT32_MAX) return false;
  out = static_cast<uint32_t>(value);
  return true;
}
inline bool valid(const Request &r) {
  return uuid(r.capture) && r.generation != 0 && r.mask != 0 &&
      (r.mask & ~registry::kInstrumentedMask) == 0 && r.minimumLevel <= 5 &&
      r.durationSeconds > 0 && r.durationSeconds <= kMaximumDurationSeconds &&
      r.budgetBytes >= 1024 && r.budgetBytes <= kMaximumBudgetBytes;
}
inline bool parse(const std::string &command, Request &request) {
  if (command.size() > 240) return false;
  std::array<std::string, 9> fields;
  std::size_t cursor = 0;
  for (std::size_t i = 0; i < fields.size(); ++i) {
    const auto end = command.find('|', cursor);
    if ((end == std::string::npos) != (i == fields.size() - 1)) return false;
    fields[i] = command.substr(cursor, end == std::string::npos ? end : end - cursor);
    cursor = end == std::string::npos ? command.size() : end + 1;
  }
  if (fields[0] != "policy" || fields[1] != "2" || !uuid(fields[2]) || fields[8] != registry::kSha256) return false;
  std::memcpy(request.capture, fields[2].c_str(), sizeof(request.capture));
  return number(fields[3], request.generation) && number(fields[4], request.mask) &&
      number(fields[5], request.minimumLevel) && number(fields[6], request.durationSeconds) &&
      number(fields[7], request.budgetBytes) && valid(request);
}
inline bool active(const State &s, uint32_t now, const char *capture) {
  return s.installed && s.remaining > 0 &&
      std::strcmp(s.request.capture, capture) == 0 && static_cast<int32_t>(s.deadline - now) > 0;
}
inline bool same(const Request &a, const Request &b) {
  return std::strcmp(a.capture, b.capture) == 0 && a.generation == b.generation &&
      a.mask == b.mask && a.minimumLevel == b.minimumLevel &&
      a.durationSeconds == b.durationSeconds && a.budgetBytes == b.budgetBytes;
}
inline bool apply(State &s, const Request &r, uint32_t now, const char *capture) {
  if (!valid(r) || std::strcmp(r.capture, capture) != 0) return false;
  if (s.installed && std::strcmp(s.request.capture, r.capture) == 0) {
    if (r.generation == s.request.generation) return same(s.request, r); // no lease/budget renewal on retry
    if (r.generation < s.request.generation) return false;
  }
  s.request = r; s.deadline = now + r.durationSeconds * 1000U;
  s.remaining = r.budgetBytes; s.filtered = 0; s.installed = true;
  return true;
}
/// Baseline info+ and critical records are independent of the additional trace
/// budget. Charge the maximum encoded size, so actual trace bytes cannot exceed
/// the advertised budget. Filtered records aren't mislabeled queue/storage loss.
inline bool admit(State &s, unsigned level, uint32_t domain, uint32_t now,
                  const char *capture, uint32_t maximumEncodedBytes) {
  if (level >= 2) return true;
  const bool allowed = active(s, now, capture) && (s.request.mask & domain) != 0 &&
      level >= s.request.minimumLevel && s.remaining >= maximumEncodedBytes;
  if (allowed) s.remaining -= maximumEncodedBytes;
  else if (s.filtered != UINT32_MAX) ++s.filtered;
  return allowed;
}
} // namespace ride_diagnostics::policy_v2
