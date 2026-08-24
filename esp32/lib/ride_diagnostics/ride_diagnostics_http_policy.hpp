#pragma once

#include <cstdint>
#include <string>

namespace ride_diagnostics::http_policy {

enum class RouteKind : uint8_t {
  Unknown = 0,
  Status,
  Index,
  Chunk,
  ActiveTail,
  Exit,
};

struct Route {
  RouteKind kind = RouteKind::Unknown;
  uint32_t boot = 0;
  uint32_t chunk = 0;
};

inline bool parsePositiveUnsigned(const std::string &value, uint32_t &out) {
  if (value.empty() || value.size() > 10)
    return false;
  uint64_t parsed = 0;
  for (const char c : value) {
    if (c < '0' || c > '9')
      return false;
    parsed = parsed * 10U + static_cast<unsigned>(c - '0');
    if (parsed > UINT32_MAX)
      return false;
  }
  if (parsed == 0)
    return false;
  out = static_cast<uint32_t>(parsed);
  return true;
}

inline Route parseRoute(const std::string &method, const std::string &path,
                        const std::string &prefix) {
  if (prefix.empty() || path.rfind(prefix, 0) != 0)
    return {};
  const std::string relative = path.substr(prefix.size());
  if (method == "GET") {
    if (relative == "status")
      return {RouteKind::Status};
    if (relative == "index")
      return {RouteKind::Index};
    if (relative == "active-tail")
      return {RouteKind::ActiveTail};
    constexpr char chunkPrefix[] = "chunks/";
    if (relative.rfind(chunkPrefix, 0) == 0) {
      const std::string identity = relative.substr(sizeof(chunkPrefix) - 1);
      const std::size_t slash = identity.find('/');
      if (slash == std::string::npos ||
          identity.find('/', slash + 1) != std::string::npos) {
        return {};
      }
      Route route{RouteKind::Chunk};
      if (!parsePositiveUnsigned(identity.substr(0, slash), route.boot) ||
          !parsePositiveUnsigned(identity.substr(slash + 1), route.chunk)) {
        return {};
      }
      return route;
    }
  } else if (method == "POST" && relative == "session/exit") {
    return {RouteKind::Exit};
  }
  return {};
}

} // namespace ride_diagnostics::http_policy
