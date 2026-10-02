#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace ride_automation {

constexpr uint32_t elapsedMs(uint32_t nowMs, uint32_t sinceMs) {
  return nowMs - sinceMs;
}

// Fixed-size one-second buckets. Repeated updates within a bucket are merged,
// while time jumps explicitly create unknown buckets rather than treating
// missing evidence as stopped evidence.
template <std::size_t Capacity> class EvidenceWindow {
  static_assert(Capacity > 0, "EvidenceWindow needs at least one bucket");

public:
  struct Counts {
    uint8_t positive = 0;
    uint8_t contradictory = 0;
    uint8_t known = 0;
  };

  void reset() {
    initialized_ = false;
    newest_ = 0;
    buckets_.fill({});
  }

  void observe(uint32_t nowMs, bool known, bool positive,
               bool contradictory = false) {
    advanceTo(nowMs);
    Bucket &bucket = buckets_[newest_];
    bucket.known = bucket.known || known;
    bucket.positive = bucket.positive || (known && positive);
    bucket.contradictory =
        bucket.contradictory || (known && contradictory);
  }

  Counts counts(uint32_t nowMs, uint8_t seconds) const {
    Counts result;
    if (!initialized_ || seconds == 0)
      return result;

    const std::size_t requested = static_cast<std::size_t>(seconds) + 1U;
    const std::size_t limit = requested < Capacity ? requested : Capacity;
    for (std::size_t offset = 0; offset < limit; ++offset) {
      const std::size_t index =
          (newest_ + Capacity - offset) % Capacity;
      const Bucket &bucket = buckets_[index];
      const uint32_t ageMs = elapsedMs(nowMs, bucket.startedAtMs);
      if (!bucket.used || ageMs < kBucketMs ||
          elapsedMs(nowMs, bucket.startedAtMs + kBucketMs) >=
              static_cast<uint32_t>(seconds) * kBucketMs)
        continue;
      result.known += bucket.known ? 1 : 0;
      result.positive += bucket.positive ? 1 : 0;
      result.contradictory += bucket.contradictory ? 1 : 0;
    }
    return result;
  }

private:
  static constexpr uint32_t kBucketMs = 1'000;

  struct Bucket {
    uint32_t startedAtMs = 0;
    bool used = false;
    bool known = false;
    bool positive = false;
    bool contradictory = false;
  };

  void advanceTo(uint32_t nowMs) {
    if (!initialized_) {
      initialized_ = true;
      buckets_[0] = Bucket{nowMs, true, false, false, false};
      newest_ = 0;
      return;
    }

    const uint32_t deltaMs = elapsedMs(nowMs, buckets_[newest_].startedAtMs);
    const uint32_t deltaBuckets = deltaMs / kBucketMs;
    if (deltaBuckets == 0)
      return;

    if (deltaBuckets >= Capacity) {
      buckets_.fill({});
      newest_ = 0;
      buckets_[newest_] = Bucket{nowMs, true, false, false, false};
      return;
    }

    for (uint32_t step = 0; step < deltaBuckets; ++step) {
      newest_ = (newest_ + 1) % Capacity;
      buckets_[newest_] =
          Bucket{buckets_[(newest_ + Capacity - 1) % Capacity].startedAtMs +
                     kBucketMs,
                 true, false, false, false};
    }
  }

  bool initialized_ = false;
  std::size_t newest_ = 0;
  std::array<Bucket, Capacity> buckets_{};
};

// A continuous condition latch that remains correct across millis() wrap.
class DurationLatch {
public:
  bool update(uint32_t nowMs, bool condition, uint32_t requiredMs) {
    if (!condition) {
      reset();
      return false;
    }
    if (!active_) {
      active_ = true;
      beganAtMs_ = nowMs;
      lastUpdatedAtMs_ = nowMs;
      accumulatedMs_ = 0;
      accumulating_ = true;
      return requiredMs == 0;
    }
    if (accumulating_)
      accumulatedMs_ = saturatingAdd(accumulatedMs_,
                                     elapsedMs(nowMs, lastUpdatedAtMs_));
    lastUpdatedAtMs_ = nowMs;
    accumulating_ = true;
    return accumulatedMs_ >= requiredMs;
  }

  void freeze(uint32_t nowMs) {
    if (!active_)
      return;
    if (accumulating_)
      accumulatedMs_ = saturatingAdd(accumulatedMs_,
                                     elapsedMs(nowMs, lastUpdatedAtMs_));
    lastUpdatedAtMs_ = nowMs;
    accumulating_ = false;
  }

  void reset() {
    active_ = false;
    accumulating_ = false;
    accumulatedMs_ = 0;
  }
  bool active() const { return active_; }
  uint32_t beganAtMs() const { return beganAtMs_; }
  uint32_t accumulatedMs(uint32_t nowMs) const {
    if (!active_)
      return 0;
    const uint32_t additional =
        accumulating_ ? elapsedMs(nowMs, lastUpdatedAtMs_) : 0;
    return saturatingAdd(accumulatedMs_, additional);
  }

private:
  static constexpr uint32_t saturatingAdd(uint32_t lhs, uint32_t rhs) {
    return UINT32_MAX - lhs < rhs ? UINT32_MAX : lhs + rhs;
  }

  bool active_ = false;
  bool accumulating_ = false;
  uint32_t beganAtMs_ = 0;
  uint32_t lastUpdatedAtMs_ = 0;
  uint32_t accumulatedMs_ = 0;
};

// A source-sample latch. Unlike DurationLatch, this never advances from policy
// loop time or transport heartbeats: only a newer producer sequence extends
// the observed capture-time span.
class SampleSpanLatch {
public:
  bool update(bool known, bool condition, uint16_t epoch, uint32_t sequence,
              uint32_t capturedAtMs, uint32_t requiredMs,
              uint32_t maximumGapMs) {
    if (!known || !condition || epoch == 0 || sequence == 0) {
      reset();
      return false;
    }
    if (!active_ || epoch != epoch_) {
      begin(epoch, sequence, capturedAtMs);
      return requiredMs == 0;
    }

    const uint32_t sequenceDelta = sequence - lastSequence_;
    if (sequenceDelta == 0)
      return spanMs() >= requiredMs;
    if (sequenceDelta >= 0x80000000UL) {
      reset();
      return false;
    }

    const uint32_t gapMs = elapsedMs(capturedAtMs, lastCapturedAtMs_);
    if (gapMs > maximumGapMs || gapMs >= 0x80000000UL) {
      begin(epoch, sequence, capturedAtMs);
      return requiredMs == 0;
    }
    lastSequence_ = sequence;
    lastCapturedAtMs_ = capturedAtMs;
    if (gapMs > largestGapMs_)
      largestGapMs_ = gapMs;
    return spanMs() >= requiredMs;
  }

  void reset() {
    active_ = false;
    epoch_ = 0;
    lastSequence_ = 0;
    beganAtMs_ = 0;
    lastCapturedAtMs_ = 0;
    largestGapMs_ = 0;
  }

  bool active() const { return active_; }
  uint32_t beganAtMs() const { return beganAtMs_; }
  uint32_t spanMs() const {
    return active_ ? elapsedMs(lastCapturedAtMs_, beganAtMs_) : 0;
  }
  uint32_t largestGapMs() const { return largestGapMs_; }

private:
  void begin(uint16_t epoch, uint32_t sequence, uint32_t capturedAtMs) {
    active_ = true;
    epoch_ = epoch;
    lastSequence_ = sequence;
    beganAtMs_ = capturedAtMs;
    lastCapturedAtMs_ = capturedAtMs;
    largestGapMs_ = 0;
  }

  bool active_ = false;
  uint16_t epoch_ = 0;
  uint32_t lastSequence_ = 0;
  uint32_t beganAtMs_ = 0;
  uint32_t lastCapturedAtMs_ = 0;
  uint32_t largestGapMs_ = 0;
};

} // namespace ride_automation
