#pragma once
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace ride_diagnostics::live_v2 {
// Optional observation cache, never an acknowledgement of durable storage.
// The runtime allocates it once in PSRAM and serializes access with the
// recorder producer lock. No socket or subscriber can block a producer.
constexpr std::size_t kCapacity = 16;
constexpr std::size_t kLineBytes = 768;
constexpr std::size_t kPage = 2;
struct Entry { uint32_t sequence = 0; uint16_t length = 0; char json[kLineBytes] = {}; };
struct Ring {
  Entry entries[kCapacity]{};
  std::size_t head = 0, count = 0;
  void append(uint32_t sequence, const char *line, std::size_t length) {
    if (line == nullptr || length == 0 || length >= kLineBytes) return;
    if (line[length - 1] == '\n') --length;
    Entry &entry = entries[head];
    entry.sequence = sequence;
    entry.length = static_cast<uint16_t>(length);
    std::memcpy(entry.json, line, length);
    entry.json[length] = '\0';
    head = (head + 1) % kCapacity;
    if (count < kCapacity) ++count;
  }
  const Entry &at(std::size_t ordinal) const {
    return entries[(head + kCapacity - count + ordinal) % kCapacity];
  }
  void json(uint32_t boot, uint32_t requestedBoot, uint32_t after, std::string &out) const {
    const bool sameBoot = requestedBoot == boot;
    const uint32_t first = count ? at(0).sequence : 0;
    const uint32_t last = count ? at(count-1).sequence : 0;
    const bool gap = requestedBoot != 0 && (!sameBoot || (count &&
        (after > last || (after < first && first - after > 1))));
    std::size_t start = 0;
    if (requestedBoot == 0) start = count > kPage ? count-kPage : 0;
    else if (sameBoot && after <= last) {
      while (start < count && at(start).sequence <= after) ++start;
    }
    const std::size_t selected = count-start > kPage ? kPage : count-start;
    const uint32_t next = selected ? at(start+selected-1).sequence : (sameBoot ? after : last);
    char prefix[320]{};
    std::snprintf(prefix, sizeof(prefix),
      "{\"schema\":2,\"available\":true,\"bootSequence\":%lu,\"firstSequence\":%lu,"
      "\"lastSequence\":%lu,\"nextSequence\":%lu,\"gap\":%s,\"more\":%s,"
      "\"durability\":\"enqueued_not_durable\",\"events\":[",
      static_cast<unsigned long>(boot),static_cast<unsigned long>(first),
      static_cast<unsigned long>(last),static_cast<unsigned long>(next),
      gap ? "true" : "false",start+selected<count ? "true" : "false");
    out = prefix;
    for (std::size_t i=0;i<selected;++i) {
      if (i) out += ',';
      out.append(at(start+i).json,at(start+i).length);
    }
    out += "]}";
  }
};
} // namespace ride_diagnostics::live_v2
