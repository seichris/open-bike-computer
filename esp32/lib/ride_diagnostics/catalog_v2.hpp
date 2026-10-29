#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <string>

namespace ride_diagnostics::catalog_v2 {
// Fixed 64-byte, little-endian, checksummed optional descriptor. This is an
// acceleration index, never a replacement for verification of returned bytes.
constexpr std::size_t kBytes = 64;
struct Descriptor {
  uint32_t boot = 0, chunk = 0, bytes = 0, firstSequence = 0, lastSequence = 0;
  std::array<uint8_t, 32> digest{};
};
inline uint32_t checksum(const uint8_t *data) {
  uint32_t h = 2166136261U;
  for (std::size_t i=0;i<60;++i) h=(h ^ data[i])*16777619U;
  return h;
}
inline void put(uint8_t *p, uint32_t v) { for (unsigned i=0;i<4;++i) p[i]=static_cast<uint8_t>(v >> (8*i)); }
inline uint32_t get(const uint8_t *p) { return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
inline std::array<uint8_t,kBytes> encode(const Descriptor &d) {
  std::array<uint8_t,kBytes> b{};
  put(b.data(),0x32444342U); put(b.data()+4,2); put(b.data()+8,d.boot);
  put(b.data()+12,d.chunk); put(b.data()+16,d.bytes); put(b.data()+20,d.firstSequence);
  put(b.data()+24,d.lastSequence); std::memcpy(b.data()+28,d.digest.data(),32);
  put(b.data()+60,checksum(b.data())); return b;
}
inline bool decode(const uint8_t *b, std::size_t n, Descriptor &d) {
  if (n!=kBytes || get(b)!=0x32444342U || get(b+4)!=2 || get(b+60)!=checksum(b)) return false;
  d.boot=get(b+8); d.chunk=get(b+12); d.bytes=get(b+16);
  d.firstSequence=get(b+20); d.lastSequence=get(b+24); std::memcpy(d.digest.data(),b+28,32);
  return d.boot!=0 && d.chunk!=0 && d.bytes>0 && d.bytes<=256U*1024U && d.firstSequence<=d.lastSequence;
}
inline std::string hex(const Descriptor &d) {
  constexpr char digits[]="0123456789abcdef";
  std::string out; out.reserve(64);
  for (auto b:d.digest) { out.push_back(digits[b>>4]); out.push_back(digits[b&15]); }
  return out;
}
// The recorder writes descriptors under memory pressure: raw descriptors and
// stack paths only, because fopen() aborts when newlib cannot allocate its
// stream lock and a std::string allocation may fail.
constexpr std::size_t kPathBytes = 240;
inline bool catalogPath(const char *path, char *out, std::size_t capacity,
                        bool temporary = false) {
  const int length=std::snprintf(out,capacity,temporary ? "%s.cat2.tmp" : "%s.cat2",path);
  return length>0 && static_cast<std::size_t>(length)<capacity;
}
template<class Storage> bool read(Storage &storage, const char *path, uint32_t boot,
                                 uint32_t chunk, uint32_t bytes, Descriptor &d) {
  char catalog[kPathBytes];
  if (!catalogPath(path,catalog,sizeof(catalog)) || storage.size(catalog)!=kBytes) return false;
  const int f=storage.openDescriptor(catalog,O_RDONLY); if (f<0) return false;
  std::array<uint8_t,kBytes> data{};
  const auto evidence=storage.readDescriptor(f,data.data(),data.size());
  const bool closed=storage.closeDescriptor(f)==0;
  return closed && !evidence.error && decode(data.data(),evidence.returned,d) &&
         d.boot==boot && d.chunk==chunk && d.bytes==bytes;
}
template<class Storage> bool write(Storage &storage, const char *path, const Descriptor &d) {
  char catalog[kPathBytes], temporary[kPathBytes];
  if (!catalogPath(path,catalog,sizeof(catalog)) ||
      !catalogPath(path,temporary,sizeof(temporary),true)) return false;
  const auto data=encode(d);
  const int f=storage.openDescriptor(temporary,O_WRONLY|O_CREAT|O_TRUNC); if (f<0) return false;
  const bool written=storage.writeDescriptor(f,data.data(),data.size())==data.size();
  // close() commits the FAT entry, which is what fflush() plus fclose() did.
  const bool closed=storage.closeDescriptor(f)==0;
  if (!written || !closed || std::rename(temporary,catalog)!=0) {
    (void)storage.remove(temporary); return false;
  }
  return true;
}
} // namespace ride_diagnostics::catalog_v2
