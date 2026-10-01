#include "diagnostics_segment_catalog.hpp"
#include "../storage/storage.hpp"
#include "../power_management/power_management.hpp"
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <sys/stat.h>

namespace bicino_diagnostics {
namespace {
std::string cachePath(const char *path) { return std::string(path) + ".catalog"; }
}
bool readSegmentDescriptor(Storage &storage, const char *path, uint32_t boot,
                           uint32_t chunk, uint32_t bytes, SegmentDescriptor &out) {
  power_management::ScopedLock lock(power_management::LockDomain::Storage);
  const auto cached = cachePath(path);
  struct stat stat{};
  if (::stat(cached.c_str(), &stat) != 0 || !S_ISREG(stat.st_mode) || stat.st_size <= 0 || stat.st_size > 112) return false;
  FILE *file = storage.open(cached.c_str(), "rb");
  if (file == nullptr) return false;
  char body[113] = {};
  const std::size_t count = storage.read(file, reinterpret_cast<uint8_t *>(body), stat.st_size);
  const bool closed = storage.close(file) == 0;
  SegmentDescriptor candidate;
  if (!closed || count != static_cast<std::size_t>(stat.st_size) ||
      !decodeSegmentDescriptor(std::string(body, count), candidate) ||
      candidate.boot != boot || candidate.chunk != chunk || candidate.bytes != bytes) return false;
  out = candidate; return true;
}
bool writeSegmentDescriptor(Storage &storage, const char *path, const SegmentDescriptor &descriptor) {
  if (!descriptor.valid()) return false;
  power_management::ScopedLock lock(power_management::LockDomain::Storage);
  const auto destination = cachePath(path), temporary = destination + ".tmp";
  const std::string body = descriptor.encode();
  FILE *file = storage.open(temporary.c_str(), "wb");
  if (file == nullptr) return false;
  bool ok = storage.write(file, reinterpret_cast<const uint8_t *>(body.data()), body.size()) == body.size();
  if (ok) ok = storage.flush(file) == 0 && ::fsync(::fileno(file)) == 0;
  if (storage.close(file) != 0) ok = false;
  if (ok) {
    // A cache is advisory and reconstructible. Loss between remove/rename
    // causes one rehash, never missing raw evidence or a false digest.
    (void)storage.remove(destination.c_str());
    ok = ::rename(temporary.c_str(), destination.c_str()) == 0;
  }
  if (!ok) (void)storage.remove(temporary.c_str());
  return ok;
}
void removeSegmentDescriptor(Storage &storage, const char *path) {
  const auto destination = cachePath(path);
  (void)storage.remove(destination.c_str());
  (void)storage.remove((destination + ".tmp").c_str());
}
}
