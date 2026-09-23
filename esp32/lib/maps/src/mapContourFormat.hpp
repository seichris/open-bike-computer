#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace map_contour_format {
constexpr uint32_t kMaximumRecords = 4096;
constexpr uint32_t kMaximumPoints = 65536;
constexpr uint16_t kMaximumRecordPoints = 256;

// Streaming validation needs only one bounded prior record for lexicographic
// canonical-order comparison, never the complete section or decoded geometry.
class Validator {
public:
  bool feed(uint8_t byte) {
    if (failed_ || state_ == State::Complete) return failed_ = true, false;
    if (state_ == State::Points) {
      if (pointByte_ >= previousPoints_.size()) return failed_ = true, false;
      if (order_ == 0) {
        if (pointByte_ >= previousLength_) order_ = 1;
        else if (byte != previousPoints_[pointByte_])
          order_ = byte < previousPoints_[pointByte_] ? -1 : 1;
      }
      previousPoints_[pointByte_++] = byte;
    }
    record_[collected_++] = byte;
    const size_t required = state_ == State::Header ? 12 : state_ == State::Record ? 14 : 4;
    if (collected_ != required) return true;
    collected_ = 0;
    const bool valid = state_ == State::Header ? header() : state_ == State::Record ? record() : point();
    if (!valid) failed_ = true;
    return valid;
  }
  bool finish() const { return !failed_ && state_ == State::Complete && pointsSeen_ == declaredPoints_; }
private:
  enum class State { Header, Record, Points, Complete };
  State state_ = State::Header;
  bool failed_ = false, havePrevious_ = false;
  uint8_t record_[14]{};
  size_t collected_ = 0, pointByte_ = 0, previousLength_ = 0;
  uint16_t minor_ = 0, index_ = 0, recordsRemaining_ = 0, pointCount_ = 0, pointsRemaining_ = 0;
  uint32_t declaredPoints_ = 0, pointsSeen_ = 0;
  std::array<int32_t, 6> key_{}, previousKey_{};
  std::array<int32_t, 4> bounds_{};
  std::array<uint8_t, kMaximumRecordPoints * 4> previousPoints_{};
  int32_t x_ = 0, y_ = 0;
  int order_ = 1;
  uint16_t u16(size_t i) const { return uint16_t(record_[i]) | (uint16_t(record_[i + 1]) << 8); }
  int16_t s16(size_t i) const { return static_cast<int16_t>(u16(i)); }
  bool header() {
    minor_ = u16(2); index_ = u16(4); recordsRemaining_ = u16(6);
    declaredPoints_ = uint32_t(u16(8)) | (uint32_t(u16(10)) << 16);
    if (record_[0] != 1 || record_[1] ||
        !((minor_ == 20 && index_ == 100) || (minor_ == 50 && index_ == 250)) ||
        recordsRemaining_ > kMaximumRecords || declaredPoints_ > kMaximumPoints) return false;
    state_ = recordsRemaining_ ? State::Record : State::Complete;
    return true;
  }
  bool record() {
    key_ = {s16(0), record_[2], s16(6), s16(8), s16(10), s16(12)};
    pointCount_ = pointsRemaining_ = u16(4);
    if (key_[0] < -12000 || key_[0] > 10000 || key_[0] % minor_ ||
        (record_[2] & ~7U) || record_[3] ||
        bool(record_[2] & 1U) != (key_[0] % index_ == 0) ||
        pointCount_ < 2 || pointCount_ > kMaximumRecordPoints ||
        pointCount_ > declaredPoints_ - pointsSeen_) return false;
    order_ = !havePrevious_ ? 1 : key_ < previousKey_ ? -1 : key_ > previousKey_ ? 1 : 0;
    if (order_ < 0) return false;
    pointByte_ = 0; x_ = y_ = 0;
    bounds_ = {4096, 4096, 0, 0};
    state_ = State::Points;
    return true;
  }
  bool point() {
    const int32_t dx = s16(0), dy = s16(2);
    if (pointsRemaining_ != pointCount_ &&
        ((dx == 0 && dy == 0) || int64_t(dx) * dx + int64_t(dy) * dy > 512LL * 512LL)) return false;
    x_ += dx; y_ += dy;
    if (x_ < 0 || x_ > 4096 || y_ < 0 || y_ > 4096) return false;
    bounds_[0] = std::min(bounds_[0], x_); bounds_[1] = std::min(bounds_[1], y_);
    bounds_[2] = std::max(bounds_[2], x_); bounds_[3] = std::max(bounds_[3], y_);
    ++pointsSeen_;
    if (--pointsRemaining_) return true;
    if (!std::equal(bounds_.begin(), bounds_.end(), key_.begin() + 2) ||
        order_ < 0 || (order_ == 0 && pointByte_ <= previousLength_)) return false;
    previousKey_ = key_; previousLength_ = pointByte_; havePrevious_ = true;
    state_ = --recordsRemaining_ ? State::Record : State::Complete;
    return true;
  }
};
} // namespace map_contour_format
