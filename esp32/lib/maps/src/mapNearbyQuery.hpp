#pragma once

#include "mapPoiIndex.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#ifdef ARDUINO
#include "../../utils/src/psram_allocator.hpp"
template <typename T> using MapNearbyVector = std::vector<T, PsramAllocator<T>>;
#else
template <typename T> using MapNearbyVector = std::vector<T>;
#endif

// Pure, bounded search mechanics. SD reads and publication belong to the one
// map worker; this helper never opens a file or touches LVGL.
namespace map_nearby_query {
constexpr double kMercatorRadiusM = 6378137.0;
constexpr double kWgs84MinimumRadiusM = 6335439.0;
constexpr double kPi = 3.14159265358979323846;
constexpr double kBlockSizeM = 4096.0;
constexpr double kBlockCenterDistanceUpperBoundM = 4200.0;
constexpr size_t kMaximumResults = 10;
constexpr size_t kMaximumBatchRecords = 256;

struct Position {
  double latitude = 0.0;
  double longitude = 0.0;
};

inline bool valid(Position position) {
  return std::isfinite(position.latitude) &&
         std::isfinite(position.longitude) &&
         position.latitude >= -90.0 && position.latitude <= 90.0 &&
         position.longitude >= -180.0 && position.longitude <= 180.0;
}

inline double degreesToRadians(double degrees) {
  return degrees * kPi / 180.0;
}

inline double centralAngle(Position first, Position second) {
  const double latitudeDelta = degreesToRadians(second.latitude - first.latitude);
  const double longitudeDelta =
      degreesToRadians(std::remainder(second.longitude - first.longitude, 360.0));
  const double firstLatitude = degreesToRadians(first.latitude);
  const double secondLatitude = degreesToRadians(second.latitude);
  const double sineLatitude = std::sin(latitudeDelta * 0.5);
  const double sineLongitude = std::sin(longitudeDelta * 0.5);
  const double haversine = sineLatitude * sineLatitude +
                           std::cos(firstLatitude) * std::cos(secondLatitude) *
                               sineLongitude * sineLongitude;
  return 2.0 * std::asin(std::sqrt(std::max(0.0, std::min(1.0, haversine))));
}

// Vincenty's inverse formula gives the rider-facing direct WGS-84 distance.
// Nearby only ranks points within 25 km, where the iteration converges rapidly.
inline double distanceMeters(Position first, Position second) {
  if (!valid(first) || !valid(second)) return INFINITY;
  if (first.latitude == second.latitude &&
      std::remainder(first.longitude - second.longitude, 360.0) == 0.0)
    return 0.0;
  constexpr double a = 6378137.0;
  constexpr double f = 1.0 / 298.257223563;
  constexpr double b = a * (1.0 - f);
  const double U1 = std::atan((1.0 - f) * std::tan(degreesToRadians(first.latitude)));
  const double U2 = std::atan((1.0 - f) * std::tan(degreesToRadians(second.latitude)));
  const double sinU1 = std::sin(U1), cosU1 = std::cos(U1);
  const double sinU2 = std::sin(U2), cosU2 = std::cos(U2);
  const double L = degreesToRadians(
      std::remainder(second.longitude - first.longitude, 360.0));
  double lambda = L;
  double sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0;
  double sinAlpha = 0.0, cosSqAlpha = 0.0, cos2SigmaM = 0.0;
  bool converged = false;
  for (unsigned iteration = 0; iteration < 32; ++iteration) {
    const double sinLambda = std::sin(lambda);
    const double cosLambda = std::cos(lambda);
    const double firstTerm = cosU2 * sinLambda;
    const double secondTerm =
        cosU1 * sinU2 - sinU1 * cosU2 * cosLambda;
    sinSigma = std::hypot(firstTerm, secondTerm);
    if (sinSigma == 0.0) return 0.0;
    cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
    sigma = std::atan2(sinSigma, cosSigma);
    sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma;
    cosSqAlpha = 1.0 - sinAlpha * sinAlpha;
    cos2SigmaM = cosSqAlpha > 0.0
                     ? cosSigma - 2.0 * sinU1 * sinU2 / cosSqAlpha
                     : 0.0;
    const double C = f / 16.0 * cosSqAlpha *
                     (4.0 + f * (4.0 - 3.0 * cosSqAlpha));
    const double next = L + (1.0 - C) * f * sinAlpha *
                                (sigma + C * sinSigma *
                                             (cos2SigmaM + C * cosSigma *
                                                (-1.0 + 2.0 * cos2SigmaM *
                                                            cos2SigmaM)));
    if (std::fabs(next - lambda) < 1e-12) {
      converged = true;
      lambda = next;
      break;
    }
    lambda = next;
  }
  if (!converged)
    return kMercatorRadiusM * centralAngle(first, second);
  const double uSq = cosSqAlpha * (a * a - b * b) / (b * b);
  const double A = 1.0 + uSq / 16384.0 *
                             (4096.0 + uSq * (-768.0 +
                                               uSq * (320.0 - 175.0 * uSq)));
  const double B = uSq / 1024.0 *
                   (256.0 + uSq * (-128.0 +
                                   uSq * (74.0 - 47.0 * uSq)));
  const double deltaSigma = B * sinSigma *
      (cos2SigmaM + B / 4.0 *
          (cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM) -
           B / 6.0 * cos2SigmaM * (-3.0 + 4.0 * sinSigma * sinSigma) *
               (-3.0 + 4.0 * cos2SigmaM * cos2SigmaM)));
  return b * A * (sigma - deltaSigma);
}

inline bool mercatorPosition(double x, double y, Position &result) {
  // One block of quantization margin is allowed at the anti-meridian; all
  // farther coordinates are malformed map data, not a second wrapped world.
  const double extent = kPi * kMercatorRadiusM + kBlockSizeM;
  if (!std::isfinite(x) || !std::isfinite(y) ||
      std::fabs(x) > extent || std::fabs(y) > extent) return false;
  result.latitude =
      std::atan(std::sinh(y / kMercatorRadiusM)) * 180.0 / kPi;
  result.longitude =
      std::remainder(x / kMercatorRadiusM * 180.0 / kPi, 360.0);
  return valid(result);
}

struct FrontierItem {
  uint16_t index = 0;
  uint32_t lowerBoundCentimetres = 0;
  double lowerBoundM() const {
    return static_cast<double>(lowerBoundCentimetres) / 100.0;
  }
};

// Surface metric on WGS-84 is everywhere no smaller than a sphere with the
// minimum meridional radius. A centre-to-record path along the block's
// meridian and parallel is below 1.004 * (2048 + 2048) metres; 4200 m is a
// deliberate conservative upper bound. Thus this lower bound cannot prune a
// nearer block, including near the poles or anti-meridian.
inline double blockLowerBoundMeters(Position rider,
                                   const map_poi_index::Entry &entry) {
  Position center;
  const double x = (double(entry.blockX) + 0.5) * kBlockSizeM;
  const double y = (double(entry.blockY) + 0.5) * kBlockSizeM;
  if (!valid(rider) || !mercatorPosition(x, y, center)) return INFINITY;
  return std::max(0.0, kWgs84MinimumRadiusM *
                           centralAngle(rider, center) -
                           kBlockCenterDistanceUpperBoundM);
}

inline bool prepareFrontier(const map_poi_index::Entry *entries, size_t count,
                            Position rider, uint32_t selectedMask,
                            double radiusM,
                            MapNearbyVector<FrontierItem> &frontier) {
  frontier.clear();
  if ((entries == nullptr && count != 0) ||
      count > map_poi_index::kMaximumEntries || !valid(rider) ||
      (selectedMask & ~0x1fU) != 0 || selectedMask == 0 ||
      !std::isfinite(radiusM) || radiusM <= 0.0 || radiusM > 25000.0)
    return false;
  for (size_t index = 0; index < count; ++index) {
    if ((entries[index].categoryMask & selectedMask) == 0) continue;
    const double bound = blockLowerBoundMeters(rider, entries[index]);
    if (!std::isfinite(bound)) return false;
    if (bound > radiusM) continue;
    // Round down, never up: pruning must remain conservative after the
    // compact frontier quantization.
    frontier.push_back({static_cast<uint16_t>(index),
                        static_cast<uint32_t>(std::floor(bound * 100.0))});
  }
  std::sort(frontier.begin(), frontier.end(),
            [&](const FrontierItem &left, const FrontierItem &right) {
    if (left.lowerBoundCentimetres != right.lowerBoundCentimetres)
      return left.lowerBoundCentimetres < right.lowerBoundCentimetres;
    const auto &a = entries[left.index];
    const auto &b = entries[right.index];
    return a.blockX != b.blockX ? a.blockX < b.blockX
                               : a.blockY < b.blockY;
  });
  return true;
}

struct Result {
  Position position;
  double directDistanceM = 0.0;
  int32_t blockX = 0;
  int32_t blockY = 0;
  uint16_t recordOrdinal = 0;
  uint8_t category = 0;
};

inline bool better(const Result &left, const Result &right) {
  if (left.directDistanceM != right.directDistanceM)
    return left.directDistanceM < right.directDistanceM;
  if (left.blockX != right.blockX) return left.blockX < right.blockX;
  if (left.blockY != right.blockY) return left.blockY < right.blockY;
  return left.recordOrdinal < right.recordOrdinal;
}

class NearestTen {
 public:
  NearestTen(Position rider, uint32_t selectedMask, double radiusM)
      : rider_(rider), selectedMask_(selectedMask), radiusM_(radiusM) {}

  // Supply at most 256 consecutive eight-byte records from the signed FMB6
  // POI section. The worker owns the one bounded SD read and checks the
  // section's header/count against FPI1 before calling this method.
  bool consume(const map_poi_index::Entry &block, uint16_t firstOrdinal,
               const uint8_t *records, size_t count) {
    if ((records == nullptr && count != 0) ||
        count > kMaximumBatchRecords || !valid(rider_) ||
        selectedMask_ == 0 || (selectedMask_ & ~0x1fU) != 0 ||
        !std::isfinite(radiusM_) || radiusM_ <= 0.0 ||
        radiusM_ > 25000.0 ||
        size_t(firstOrdinal) + count > block.recordCount())
      return false;
    for (size_t index = 0; index < count; ++index) {
      const uint8_t *record = records + index * 8;
      const uint16_t localX = map_poi_index::u16(record);
      const uint16_t localY = map_poi_index::u16(record + 2);
      const uint8_t category = record[4];
      if (localX > 4095 || localY > 4095 || category < 1 || category > 5 ||
          record[5] > 5 || record[6] > 3 || record[7] != 0)
        return false;
      if ((selectedMask_ & (1U << (category - 1U))) == 0) continue;
      Position position;
      const double x = double(block.blockX) * kBlockSizeM + localX;
      const double y = double(block.blockY) * kBlockSizeM + localY;
      if (!mercatorPosition(x, y, position)) return false;
      const double distance = distanceMeters(rider_, position);
      if (!std::isfinite(distance)) return false;
      if (distance > radiusM_) continue;
      Result result{position, distance, block.blockX, block.blockY,
                    static_cast<uint16_t>(firstOrdinal + index), category};
      size_t insert = 0;
      while (insert < size_ && !better(result, results_[insert])) ++insert;
      if (insert >= kMaximumResults) continue;
      if (size_ < kMaximumResults) ++size_;
      for (size_t move = size_ - 1; move > insert; --move)
        results_[move] = results_[move - 1];
      results_[insert] = result;
    }
    return true;
  }

  bool canFinishBefore(double nextBlockLowerBoundM) const {
    if (!std::isfinite(nextBlockLowerBoundM)) return false;
    return nextBlockLowerBoundM > radiusM_ ||
           (size_ == kMaximumResults &&
            nextBlockLowerBoundM > results_[size_ - 1].directDistanceM);
  }

  size_t size() const { return size_; }
  const Result &operator[](size_t index) const { return results_[index]; }

 private:
  Position rider_;
  uint32_t selectedMask_;
  double radiusM_;
  std::array<Result, kMaximumResults> results_{};
  size_t size_ = 0;
};
} // namespace map_nearby_query
