#include "../../lib/ride_diagnostics/ride_diagnostics_control.hpp"
#include "../../lib/ride_diagnostics/ride_diagnostics_transfer_policy.hpp"

#include <cassert>
#include <iostream>

int main() {
  using namespace ride_diagnostics::control;

  CaptureBinding binding;
  assert(parseCaptureBinding(
      "capture|1|standard|123e4567-e89b-12d3-a456-426614174000",
      binding));
  assert(binding.mode == CaptureMode::Standard);
  assert(parseCaptureBinding(
      "capture|1|detailed|123e4567-e89b-12d3-a456-426614174001",
      binding));
  assert(binding.mode == CaptureMode::Detailed);
  assert(!parseCaptureBinding("capture|2|standard|id", binding));
  assert(!parseCaptureBinding("capture|1|unknown|id", binding));

  IssueMarker marker;
  assert(parseIssueMarker("mark|1|7|connection_drop", marker));
  assert(marker.sequence == 7);
  assert(marker.code == "connection_drop");
  assert(!parseIssueMarker("mark|1|0|connection_drop", marker));
  assert(!parseIssueMarker("mark|1|7|connection|drop", marker));
  assert(!parseIssueMarker("mark|2|7|connection_drop", marker));

  constexpr char captureA[] = "123e4567-e89b-12d3-a456-426614174000";
  constexpr char captureB[] = "123e4567-e89b-12d3-a456-426614174001";
  assert(!bindingRequiresChunkBoundary(
      captureA, CaptureMode::Standard, captureA, CaptureMode::Standard));
  assert(bindingRequiresChunkBoundary(
      captureA, CaptureMode::Standard, captureB, CaptureMode::Standard));
  assert(bindingRequiresChunkBoundary(
      captureA, CaptureMode::Standard, captureA, CaptureMode::Detailed));
  assert(bindingRequiresChunkBoundary(
      nullptr, CaptureMode::Standard, captureA, CaptureMode::Standard));

  assert(markerSequenceCanAdvance(0, 1));
  assert(markerSequenceCanAdvance(7, 8));
  assert(!markerSequenceCanAdvance(7, 7));
  assert(!markerSequenceCanAdvance(7, 6));
  assert(!markerSequenceCanAdvance(7, 0));
  assert(markerSequenceAfterBinding(captureA, captureA, 7) == 7);
  assert(markerSequenceAfterBinding(captureA, captureB, 7) == 0);
  assert(markerSequenceAfterBinding(nullptr, captureB, 7) == 0);

  using namespace ride_diagnostics::transfer_policy;
  assert(storageReady(StoragePreparation::ReadyRemovable));
  assert(storageReady(StoragePreparation::ReadyInternalFallback));
  assert(usingInternalFallback(StoragePreparation::ReadyInternalFallback));
  assert(!storageReady(StoragePreparation::CardMissing));
  assert(std::string(storageFailure(StoragePreparation::MountFailed).code) ==
         "diagnostics_mount_failed");
  assert(std::string(storageFailure(StoragePreparation::CardMissing).code) ==
         "diagnostics_card_missing");
  assert(std::string(
             storageFailure(StoragePreparation::WritableProbeFailed).code) ==
         "diagnostics_writable_probe_failed");
  assert(std::string(sealFailure(SealPreparation::FlushFailed).code) ==
         "diagnostics_flush_failed");
  assert(std::string(sealFailure(SealPreparation::CloseFailed).code) ==
         "diagnostics_close_failed");
  assert(std::string(sealFailure(SealPreparation::DrainTimeout).code) ==
         "diagnostics_seal_timeout");
  assert(std::string(sealFailure(SealPreparation::SealFailed).code) ==
         "diagnostics_seal_failed");

  std::cout << "ride diagnostics control tests passed\n";
  return 0;
}
