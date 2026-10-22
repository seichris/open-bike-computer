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
struct RiderMetadata {
  bool present = false, imageReady = false;
  uint32_t sequence = 0, received = 0;
  uint16_t age = 0, accuracy = 0, course = 65535;
  int32_t latitude = 0, longitude = 0;
  char initials[5] = {};
  std::array<uint8_t, 32> hash{}, imageHash{};
  uint32_t ageMs(uint32_t now) const { return uint32_t(age) * 1000 + uint32_t(now - received); }
};
struct Rider : RiderMetadata { std::array<uint8_t, IMAGE_BYTES> image{}; };
inline bool copySnapshot(const Rider &source, Rider &destination) {
  const bool copy = source.imageReady && source.imageHash != destination.imageHash;
  static_cast<RiderMetadata &>(destination) = static_cast<const RiderMetadata &>(source);
  if (copy) destination.image = source.image;
  return copy;
}
inline uint16_t u16(const uint8_t *p) { return p[0] | (uint16_t(p[1]) << 8); }
inline uint32_t u32(const uint8_t *p) { return u16(p) | (uint32_t(u16(p+2)) << 16); }
// One combined friend-marker size (map setting 39): portraits, initials,
// distances and grouped counts scale together. Percent of the normal size.
constexpr uint8_t MARKER_SCALE_SETTING_ID = 39;
constexpr uint16_t MIN_MARKER_SCALE = 100, MAX_MARKER_SCALE = 300;
constexpr int PORTRAIT_SIZE = 40, MAX_PORTRAIT_SIZE = PORTRAIT_SIZE * MAX_MARKER_SCALE / 100;
inline uint16_t clampMarkerScale(int32_t percent) {
  return uint16_t(std::clamp<int32_t>(percent, MIN_MARKER_SCALE, MAX_MARKER_SCALE));
}
inline int scaled(int normal, uint16_t percent) { return (normal * int(percent) + 50) / 100; }
// Largest enabled Montserrat size that still fits the scaled text box.
inline int fontPixels(int normal, uint16_t percent) {
  constexpr int sizes[] = {12, 14, 16, 18, 24, 32, 38, 48};
  const int target = normal * int(percent) / 100;
  int chosen = sizes[0];
  for (int size : sizes) if (size <= target) chosen = size;
  return chosen;
}
// Normal footprint 64x62, centred on the rider: a 44 px portrait frame with a
// 40 px image, the "+N" count at its upper right and the label below it.
struct BadgeGeometry {
  int width, height, frame, frameX, portrait, inset, countX, labelY;
  int initialsFont, countFont, labelFont;
  double halfWidth() const { return width / 2.0; }
  double halfHeight() const { return height / 2.0; }
};
inline BadgeGeometry badgeGeometry(uint16_t percent) {
  percent = clampMarkerScale(percent);
  BadgeGeometry g{};
  g.width = scaled(64, percent); g.height = scaled(62, percent);
  g.frame = scaled(44, percent); g.frameX = (g.width - g.frame) / 2;
  g.portrait = scaled(PORTRAIT_SIZE, percent); g.inset = (g.frame - g.portrait) / 2;
  g.countX = scaled(38, percent); g.labelY = scaled(44, percent);
  g.initialsFont = fontPixels(14, percent); g.countFont = fontPixels(14, percent);
  g.labelFont = fontPixels(12, percent);
  return g;
}
// Bilinear RGB565 (little endian) resample of the square 40x40 portrait into a
// size x size destination. The normal size is an exact copy.
inline void scalePortrait(const uint8_t *source, uint8_t *destination, int size) {
  if (size == PORTRAIT_SIZE) { memcpy(destination, source, IMAGE_BYTES); return; }
  auto pixel = [&](int x, int y) { return u16(source + 2 * (y * PORTRAIT_SIZE + x)); };
  for (int y = 0; y < size; ++y) {
    const double sy = std::clamp((y + 0.5) * PORTRAIT_SIZE / size - 0.5, 0.0, double(PORTRAIT_SIZE - 1));
    const int y0 = int(sy), y1 = std::min(y0 + 1, PORTRAIT_SIZE - 1); const double fy = sy - y0;
    for (int x = 0; x < size; ++x) {
      const double sx = std::clamp((x + 0.5) * PORTRAIT_SIZE / size - 0.5, 0.0, double(PORTRAIT_SIZE - 1));
      const int x0 = int(sx), x1 = std::min(x0 + 1, PORTRAIT_SIZE - 1); const double fx = sx - x0;
      const uint16_t c[4] = {pixel(x0, y0), pixel(x1, y0), pixel(x0, y1), pixel(x1, y1)};
      auto channel = [&](int shift, int mask) {
        const double top = ((c[0] >> shift) & mask) * (1 - fx) + ((c[1] >> shift) & mask) * fx;
        const double bottom = ((c[2] >> shift) & mask) * (1 - fx) + ((c[3] >> shift) & mask) * fx;
        return uint16_t(std::lround(top * (1 - fy) + bottom * fy)) & mask;
      };
      const uint16_t value = uint16_t(channel(11, 31) << 11 | channel(5, 63) << 5 | channel(0, 31));
      destination[2 * (y * size + x)] = uint8_t(value & 0xff);
      destination[2 * (y * size + x) + 1] = uint8_t(value >> 8);
    }
  }
}
// Portraits are RGB565A8 (colour plane, then alpha plane) so the frame's circle
// is part of the image. LVGL corner clipping would need a draw layer as large as
// the frame, which the fixed LVGL pool cannot provide at large marker sizes.
inline size_t portraitBytes(int size) { return size_t(size) * size * 3; }
inline uint8_t circleCoverage(int x, int y, int size, double radius) {
  const double centre = size / 2.0, distance = std::hypot(x + 0.5 - centre, y + 0.5 - centre);
  return uint8_t(std::lround(std::clamp(radius - distance + 0.5, 0.0, 1.0) * 255));
}
inline void maskPortrait(uint8_t *alpha, int size, double radius) {
  for (int y = 0; y < size; ++y)
    for (int x = 0; x < size; ++x) alpha[y * size + x] = circleCoverage(x, y, size, radius);
}
struct BadgePresentation {
  int x=0,y=0; bool stale=false,portrait=false; uint16_t scale=MIN_MARKER_SCALE;
  std::array<char,24> label{}; std::array<char,5> initials{};
  std::array<uint8_t,32> hash{};
  bool operator==(const BadgePresentation &b) const {
    return x==b.x && y==b.y && stale==b.stale && portrait==b.portrait && scale==b.scale &&
           label==b.label && initials==b.initials && hash==b.hash;
  }
};
class PresentationCache {
  bool visible=false; BadgePresentation previous{};
public:
  bool apply(const BadgePresentation &next) {
    const bool changed=!visible || !(previous==next); previous=next;visible=true;return changed;
  }
  bool hide() { const bool changed=visible;visible=false;return changed; }
};
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
      if (r.present && seq < r.sequence) return 1;
      if (r.present && seq == r.sequence) {
        // A lost ACK must permit the next portrait operation, without renewing age.
        return r.latitude==lat && r.longitude==lon && r.age==u16(p+23) &&
            r.accuracy==u16(p+25) && r.course==u16(p+27) &&
            !memcmp(r.initials,p+29,4) && !memcmp(r.hash.data(),p+33,32) ? 0 : 1;
      }
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
// Whether a footprint centred at (x, y) lies inside the screen with a 4 px
// margin; a round panel constrains every corner to the circle.
inline bool fits(double x, double y, double width, double height, bool round,
                 double halfWidth, double halfHeight) {
  if (x < halfWidth || y < halfHeight || x > width-halfWidth || y > height-halfHeight) return false;
  if (!round) return true;
  bool inside=true;
  for (double cx:{-halfWidth,halfWidth}) for (double cy:{-halfHeight,halfHeight})
    inside &= std::hypot(x-width/2+cx,y-height/2+cy)<=std::min(width,height)/2-4;
  return inside;
}
// Center of the complete footprint (normal 64x62). A binary search constrains
// ALL corners to the circle, including the distance below the portrait.
inline Position edge(double dx, double dy, double width, double height, bool round,
                     double halfWidth = 32, double halfHeight = 31) {
  double norm=std::hypot(dx,dy); if (!std::isfinite(norm) || norm<1e-9) return {width/2,height/2};
  dx/=norm;dy/=norm;double low=0,high=std::max(width,height);
  const double radius=std::min(width,height)/2-4;
  for (int i=0;i<24;++i) {
    const double mid=(low+high)/2; bool fits=true;
    for (double x:{-halfWidth,halfWidth}) for (double y:{-halfHeight,halfHeight}) {
      double px=dx*mid+x,py=dy*mid+y;
      fits &= round ? px*px+py*py<=radius*radius : std::abs(px)<=width/2-4 && std::abs(py)<=height/2-4;
    }
    if(fits)low=mid;else high=mid;
  }
  return {width/2+dx*low,height/2+dy*low};
}
}
