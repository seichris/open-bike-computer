#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <algorithm>

// Owner-authenticated, negotiated GRUP v1. All integers little endian.
// Fixed memory: eight riders and one staging image. No URLs, UID, or tokens.
namespace social_riders {
constexpr size_t CAPACITY = 8, IMAGE_BYTES = 40 * 40 * 2;
constexpr uint32_t EXPIRE_MS = 60000, STALE_MS = 15000;
struct Rider {
  bool present = false, imageReady = false;
  uint32_t sequence = 0, received = 0;
  uint16_t age = 0, accuracy = 0, course = 65535;
  int32_t latitude = 0, longitude = 0;
  char initials[5] = {};
  std::array<uint8_t, 32> hash{}, imageHash{};
  std::array<uint8_t, IMAGE_BYTES> image{};
  uint32_t ageMs(uint32_t now) const { return uint32_t(age) * 1000 + uint32_t(now - received); }
};
inline uint16_t u16(const uint8_t *p) { return p[0] | (uint16_t(p[1]) << 8); }
inline uint32_t u32(const uint8_t *p) { return u16(p) | (uint32_t(u16(p+2)) << 16); }
using Hash = void (*)(const uint8_t *, size_t, uint8_t *);
class State {
public:
  std::array<Rider, CAPACITY> riders{};
  uint32_t epoch = 0;
  uint16_t offset = 0;
  uint8_t stagingSlot = 255;
  std::array<uint8_t, IMAGE_BYTES> staging{};
  std::array<uint8_t, 32> stagingHash{};
  static void clearRider(Rider &r) {
    r.present=false;r.imageReady=false;r.sequence=0;r.received=0;r.age=0;r.accuracy=0;r.course=65535;
    r.latitude=0;r.longitude=0;memset(r.initials,0,sizeof(r.initials));r.hash.fill(0);r.imageHash.fill(0);r.image.fill(0);
  }
  void clear() { for (auto &r: riders) clearRider(r); epoch = 0; stagingSlot = 255; offset = 0; staging.fill(0); }
  // ACK result: 0 applied; 1 stale/session; 2 malformed; 3 hash mismatch.
  uint8_t ingest(const uint8_t *p, size_t n, uint32_t now, Hash hash) {
    if (n < 10 || memcmp(p,"GRUP",4) || p[4] != 1) return 2;
    const auto incoming = u32(p+6);
    if (!incoming) return 2;
    if (p[5] == 0) {
      if (n != 10) return 2;
      if (epoch == incoming) return 0; // Retry must not erase following frames.
      clear(); epoch = incoming; return 0;
    }
    if (incoming != epoch) return 1;
    if (n < 11 || p[10] >= CAPACITY) return 2;
    auto &r = riders[p[10]];
    switch (p[5]) {
    case 1: {
      if (n != 65) return 2;
      const auto seq = u32(p+11);
      const int32_t lat = int32_t(u32(p+15)), lon = int32_t(u32(p+19));
      if (std::abs(int64_t(lat)) > 90000000 || std::abs(int64_t(lon)) > 180000000 ||
          u16(p+23) >= 60 || u16(p+25) > 100 || (u16(p+27) != 65535 && u16(p+27) >= 360)) return 2;
      if (r.present && seq <= r.sequence) return 1;
      for (int i=0;i<4;++i) if (p[29+i] && (p[29+i] < 32 || p[29+i] > 126)) return 2;
      r.present=true; r.sequence=seq; r.latitude=lat; r.longitude=lon;
      r.received=now; r.age=u16(p+23); r.accuracy=u16(p+25); r.course=u16(p+27);
      memcpy(r.initials,p+29,4); r.initials[4]=0; memcpy(r.hash.data(),p+33,32);
      r.imageReady=r.hash==r.imageHash && std::any_of(r.hash.begin(),r.hash.end(),[](uint8_t v){return v!=0;});
      return 0;
    }
    case 2:
      if (n != 11) return 2;
      clearRider(r); if (stagingSlot==p[10]) { stagingSlot=255; offset=0; } return 0;
    case 3:
      if (n != 43 || !r.present || memcmp(r.hash.data(),p+11,32)) return 2;
      if (stagingSlot==p[10] && !memcmp(stagingHash.data(),p+11,32)) return 0;
      stagingSlot=p[10]; offset=0; memcpy(stagingHash.data(),p+11,32); return 0;
    case 4: {
      if (n < 14 || n > 125 || stagingSlot!=p[10]) return 2;
      const auto at=u16(p+11); const auto count=n-13;
      if (at+count > IMAGE_BYTES) return 2;
      if (at < offset && at+count <= offset && !memcmp(staging.data()+at,p+13,count)) return 0;
      if (at != offset) return 1;
      memcpy(staging.data()+at,p+13,count); offset+=count; return 0;
    }
    case 5: {
      if (n!=11) return 2;
      if (r.imageReady && r.imageHash==r.hash) return 0;
      if (stagingSlot!=p[10] || offset!=IMAGE_BYTES || r.hash!=stagingHash) return 2;
      std::array<uint8_t,32> actual{}; hash(staging.data(),IMAGE_BYTES,actual.data());
      if (actual!=stagingHash) { offset=0; stagingSlot=255; return 3; }
      r.image=staging; r.imageHash=actual; r.imageReady=true; stagingSlot=255; return 0;
    }
    default: return 2;
    }
  }
};
struct Position { double x, y; };
// Center of the complete 64x62 footprint. A binary search constrains ALL
// corners to the circle, including the distance below the portrait.
inline Position edge(double dx, double dy, double width, double height, bool round) {
  double norm=std::hypot(dx,dy); if (!std::isfinite(norm) || norm<1e-9) return {width/2,height/2};
  dx/=norm;dy/=norm;double low=0,high=std::max(width,height);
  const double radius=std::min(width,height)/2-4;
  for (int i=0;i<24;++i) {
    const double mid=(low+high)/2; bool fits=true;
    for (double x:{-32.0,32.0}) for (double y:{-31.0,31.0}) {
      double px=dx*mid+x,py=dy*mid+y;
      fits &= round ? px*px+py*py<=radius*radius : std::abs(px)<=width/2-4 && std::abs(py)<=height/2-4;
    }
    if(fits)low=mid;else high=mid;
  }
  return {width/2+dx*low,height/2+dy*low};
}
}
