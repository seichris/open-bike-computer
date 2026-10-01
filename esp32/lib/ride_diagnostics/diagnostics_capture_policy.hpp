#pragma once
#include "diagnostics_contract.generated.hpp"
#include <array>
#include <cstdint>
#include <cstring>
#include <string>

namespace bicino_diagnostics {

enum class Severity : uint8_t { Trace, Debug, Info, Warning, Error, Fault };

inline bool validUuid(const char *value) {
  if (value == nullptr || std::strlen(value) != 36) return false;
  for (unsigned i = 0; i < 36; ++i) {
    const char c = value[i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != '-') return false;
    } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}
inline int domainIndex(const char *domain) {
  if (domain == nullptr) return -1;
  for (std::size_t i = 0; i < contract::kDomainCount; ++i)
    if (std::strcmp(domain, contract::kDomains[i]) == 0) return static_cast<int>(i);
  return -1;
}
inline bool unsignedDecimal(const std::string &text, uint32_t &value) {
  if (text.empty() || text.size() > 10 || (text.size() > 1 && text[0] == '0')) return false;
  uint64_t n = 0;
  for (char c : text) {
    if (c < '0' || c > '9') return false;
    n = n * 10U + static_cast<unsigned>(c - '0');
    if (n > UINT32_MAX) return false;
  }
  value = static_cast<uint32_t>(n);
  return true;
}

struct CaptureRequest {
  char captureId[37] = {};
  uint32_t generation = 0;
  uint32_t durationSeconds = 0;
  uint32_t expiresAtEpoch = 0;
  std::array<uint8_t, contract::kDomainCount> levels{};

  CaptureRequest() { levels.fill(static_cast<uint8_t>(Severity::Info)); }
  bool valid() const {
    if (!validUuid(captureId) || generation == 0 ||
        durationSeconds > contract::kMaximumCaptureSeconds ||
        (durationSeconds > 0 && expiresAtEpoch < 1700000000U)) return false;
    for (auto level : levels)
      if (level > static_cast<uint8_t>(Severity::Fault) ||
          (durationSeconds == 0 && level < static_cast<uint8_t>(Severity::Info))) return false;
    return true;
  }
};

// The outer DTRN payload is already owner-authenticated. Keep this parser
// bounded and reject trailing fields, ambiguous decimals and partial policies.
inline bool parseCaptureRequest(const std::string &command, CaptureRequest &out) {
  constexpr char prefix[] = "capture|2|";
  if (command.size() > 160 || command.rfind(prefix, 0) != 0) return false;
  std::array<std::string, 5> parts;
  std::size_t cursor = sizeof(prefix) - 1;
  for (std::size_t i = 0; i < parts.size(); ++i) {
    const auto end = command.find('|', cursor);
    if ((i + 1 < parts.size()) == (end == std::string::npos)) return false;
    parts[i] = command.substr(cursor, end == std::string::npos ? end : end - cursor);
    cursor = end == std::string::npos ? command.size() : end + 1;
  }
  CaptureRequest candidate;
  if (!validUuid(parts[0].c_str()) ||
      !unsignedDecimal(parts[1], candidate.generation) ||
      !unsignedDecimal(parts[2], candidate.durationSeconds) ||
      !unsignedDecimal(parts[3], candidate.expiresAtEpoch) ||
      parts[4].size() != contract::kDomainCount) return false;
  std::memcpy(candidate.captureId, parts[0].c_str(), sizeof(candidate.captureId));
  for (std::size_t i = 0; i < candidate.levels.size(); ++i) {
    if (parts[4][i] < '0' || parts[4][i] > '5') return false;
    candidate.levels[i] = static_cast<uint8_t>(parts[4][i] - '0');
  }
  if (!candidate.valid()) return false;
  out = candidate;
  return true;
}

struct PolicyCounters {
  uint32_t filtered = 0;
  uint32_t rateLimited = 0;
};
enum class ApplyResult { Applied, Duplicate, Stale, Conflict, Invalid };

class CapturePolicy {
 public:
  ApplyResult apply(const CaptureRequest &request, uint32_t now, uint32_t epoch = 0) {
    if (!request.valid()) return ApplyResult::Invalid;
    if (std::strcmp(request.captureId, request_.captureId) == 0) {
      if (request.generation == request_.generation) {
        return request.durationSeconds == request_.durationSeconds && request.expiresAtEpoch == request_.expiresAtEpoch && request.levels == request_.levels
                   ? ApplyResult::Duplicate : ApplyResult::Conflict;
      }
      if (static_cast<int32_t>(request.generation - request_.generation) <= 0) return ApplyResult::Stale;
    }
    request_ = request;
    startedAt_ = now;
    durationMs_ = request.durationSeconds * 1000U;
    if (epoch >= 1700000000U && request.expiresAtEpoch > 0) {
      durationMs_ = request.expiresAtEpoch <= epoch ? 0U :
          (request.expiresAtEpoch - epoch < request.durationSeconds ?
           request.expiresAtEpoch - epoch : request.durationSeconds) * 1000U;
    }
    expired_ = durationMs_ == 0;
    windowStart_ = now;
    windowEvents_ = windowBytes_ = 0;
    return ApplyResult::Applied;
  }
  void stop() { expired_ = true; }
  bool expire(uint32_t now) {
    if (!expired_ && static_cast<uint32_t>(now - startedAt_) >= durationMs_) {
      expired_ = true;
      return true;
    }
    return false;
  }
  bool detailed(uint32_t now) {
    expire(now);
    if (expired_) return false;
    for (auto level : request_.levels)
      if (level < static_cast<uint8_t>(Severity::Info)) return true;
    return false;
  }
  uint32_t remainingSeconds(uint32_t now) {
    expire(now);
    if (expired_) return 0;
    return (durationMs_ - static_cast<uint32_t>(now - startedAt_) + 999U) / 1000U;
  }
  std::array<uint8_t, contract::kDomainCount> effectiveLevels(uint32_t now) {
    expire(now);
    if (!expired_) return request_.levels;
    std::array<uint8_t, contract::kDomainCount> baseline;
    baseline.fill(static_cast<uint8_t>(Severity::Info));
    return baseline;
  }
  bool admit(Severity severity, const char *domain, std::size_t estimatedBytes, uint32_t now) {
    expire(now);
    // Safety and lifecycle evidence cannot be suppressed by a capture policy.
    if (severity >= Severity::Warning || (domain != nullptr &&
        (std::strcmp(domain, "logger") == 0 || std::strcmp(domain, "boot") == 0 ||
         std::strcmp(domain, "lifecycle") == 0 || std::strcmp(domain, "user") == 0))) return true;
    const int index = domainIndex(domain);
    const uint8_t threshold = expired_ || index < 0 ? static_cast<uint8_t>(Severity::Info) : request_.levels[index];
    if (static_cast<uint8_t>(severity) < threshold) { increment(counters_.filtered); return false; }
    if (severity >= Severity::Info) return true;
    if (static_cast<uint32_t>(now - windowStart_) >= 1000U) {
      windowStart_ = now; windowEvents_ = windowBytes_ = 0;
    }
    if (windowEvents_ >= contract::kMaximumTraceEventsPerSecond ||
        estimatedBytes > contract::kMaximumTraceBytesPerSecond - windowBytes_) {
      increment(counters_.rateLimited); return false;
    }
    ++windowEvents_;
    windowBytes_ += static_cast<uint32_t>(estimatedBytes);
    return true;
  }
  const CaptureRequest &request() const { return request_; }
  PolicyCounters counters() const { return counters_; }
 private:
  static void increment(uint32_t &value) { if (value != UINT32_MAX) ++value; }
  CaptureRequest request_;
  PolicyCounters counters_;
  uint32_t durationMs_ = 0;
  uint32_t startedAt_ = 0, windowStart_ = 0, windowEvents_ = 0, windowBytes_ = 0;
  bool expired_ = true;
};
} // namespace bicino_diagnostics
