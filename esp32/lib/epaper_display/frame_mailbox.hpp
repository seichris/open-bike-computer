#pragma once
#include <cstdint>
#include <utility>

namespace epaper {
// Caller serializes the short metadata operations. Conversion and SPI run
// outside that lock on separately owned slots. No allocation or borrowed LVGL
// memory crosses the mailbox; there is exactly one replaceable pending frame.
class FrameMailbox {
public:
  struct Frame { uint8_t *pixels; uint32_t generation, pairing, context; };
  void bind(uint8_t *desired, uint8_t *flight, uint8_t *shown) {
    desired_ = desired; flight_ = flight; shown_ = shown;
  }
  uint8_t *beginWrite() {
    if (writing_) return nullptr;
    writing_ = true;
    return desired_;
  }
  uint32_t publish(uint32_t pairing, uint32_t context = 0) {
    if (!writing_) return 0;
    if (++generation_ == 0) ++generation_;
    pairing_ = pairing;
    context_ = context;
    writing_ = false; pending_ = true;
    return generation_;
  }
  Frame claim() {
    if (writing_ || !pending_ || inFlight_) return {nullptr, 0, 0, 0};
    std::swap(desired_, flight_);
    inFlight_ = true; pending_ = false;
    return {flight_, generation_, pairing_, context_};
  }
  void finish(bool visible) {
    if (!inFlight_) return;
    if (visible) std::swap(flight_, shown_);
    inFlight_ = false;
  }
  const uint8_t *shown() const { return shown_; }
private:
  uint8_t *desired_ = nullptr, *flight_ = nullptr, *shown_ = nullptr;
  uint32_t generation_ = 0, pairing_ = 0, context_ = 0;
  bool writing_ = false, pending_ = false, inFlight_ = false;
};
} // namespace epaper
