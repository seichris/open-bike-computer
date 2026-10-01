#pragma once

#include <cstdint>

// Pure, host-tested policy. A deadline NEVER grants permission. A failed boot
// remains closed to new transfers; continuing ordinary UI work cannot reset it.
namespace shutdown_barrier {
enum class Stage : uint8_t { Idle, Drain, Renderer, Diagnostics, Storage, Ready, Deferred };
class Barrier {
public:
  void request(uint32_t now) {
    if (stage_ != Stage::Idle) return;
    stage_ = Stage::Drain;
    started_ = progress_ = now;
  }
  Stage stage() const { return stage_; }
  bool requested() const { return stage_ != Stage::Idle; }
  bool permit() const { return stage_ == Stage::Ready; }
  Stage failedStage() const { return failed_; }
  void noteProgress(uint32_t now) {
    if (stage_ == Stage::Drain) progress_ = now;
  }
  void poll(uint32_t now, bool drained, bool rendererStopped,
            bool diagnosticsSealed, bool storageStopped, bool acceptedWork) {
    if (stage_ == Stage::Idle || stage_ == Stage::Ready || stage_ == Stage::Deferred)
      return;
    const uint32_t budget = acceptedWork ? 30000U : 5000U;
    if (static_cast<uint32_t>(now - started_) >= 600000U ||
        static_cast<uint32_t>(now - progress_) >= budget) {
      failed_ = stage_;
      stage_ = Stage::Deferred;
      return;
    }
    const Stage previous = stage_;
    if (stage_ == Stage::Drain && drained) stage_ = Stage::Renderer;
    else if (stage_ == Stage::Renderer && rendererStopped) stage_ = Stage::Diagnostics;
    else if (stage_ == Stage::Diagnostics && diagnosticsSealed) stage_ = Stage::Storage;
    else if (stage_ == Stage::Storage && storageStopped) stage_ = Stage::Ready;
    if (stage_ != previous) progress_ = now;
  }
private:
  Stage stage_ = Stage::Idle;
  Stage failed_ = Stage::Idle;
  uint32_t started_ = 0;
  uint32_t progress_ = 0;
};
} // namespace shutdown_barrier
