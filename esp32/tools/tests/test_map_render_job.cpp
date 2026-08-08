#include "../../lib/maps/src/mapRenderJob.hpp"

#include <cassert>
#include <cstdint>
#include <initializer_list>

int main() {
  using namespace map_render_job;

  assert(!cancellationRequested(7, 7));
  assert(cancellationRequested(7, 8));
  assert(!shouldCancelWorkerOperation(false, false, 7, 7));
  assert(shouldCancelWorkerOperation(false, false, 7, 8));
  assert(!shouldCancelWorkerOperation(false, true, 7, 8));
  assert(shouldCancelWorkerOperation(true, true, 7, 7));

  LatestWins jobs;
  Version first{1, 10, 20, 30, 40, 50};
  assert(jobs.submit(first) == first);
  assert(jobs.beginLatest());
  assert(jobs.state() == State::Rendering);
  assert(jobs.checkpoint() == StopReason::None);

  // A newer route window does not cancel the active base frame because route
  // geometry is a live foreground input.
  Version second{2, 11, 20, 30, 40, 50};
  jobs.submit(second);
  assert(jobs.checkpoint() == StopReason::None);
  for (uint32_t elapsed : {120U, 450U, 900U, 1500U})
    jobs.noteSlice(elapsed, 2000);
  assert(!jobs.sliceBudgetExceeded());
  assert(jobs.completeActive());
  assert(jobs.state() == State::Ready);

  Version published;
  assert(jobs.takeReady(published));
  assert(published == first);
  assert(jobs.diagnostics().published == 1);
  assert(jobs.beginLatest());
  assert(jobs.completeActive());
  assert(jobs.takeReady(published));
  assert(published == second);

  // Position-only supersession must not cancel a complete overscanned frame:
  // the UI can present it with the live pose while the newest request waits
  // behind the ready-surface publication.
  Version positionOne{8, 12, 22, 30, 40, 50};
  jobs.submit(positionOne);
  assert(jobs.beginLatest());
  Version positionTwo{9, 12, 22, 30, 40, 50};
  jobs.submit(positionTwo);
  assert(jobs.checkpoint() == StopReason::None);
  assert(jobs.completeActive());
  assert(jobs.state() == State::Ready);
  assert(!jobs.beginLatest());
  assert(jobs.takeReady(published));
  assert(published == positionOne);
  assert(jobs.beginLatest());
  jobs.cancelActive();

  // Completion is not permission to publish: semantic state may change before
  // the next UI tick.
  Version third{3, 11, 21, 30, 40, 50};
  jobs.submit(third);
  assert(jobs.beginLatest());
  assert(jobs.completeActive());
  Version fourth{4, 11, 21, 31, 40, 50};
  jobs.submit(fourth);
  assert(!jobs.takeReady(published));
  assert(jobs.diagnostics().stalePublications == 1);

  assert(jobs.beginLatest());
  assert(jobs.completeActive());
  jobs.rejectReadyAsInvariant();
  assert(jobs.state() == State::Idle);
  assert(jobs.diagnostics().invariantFailures == 1);

  assert(jobs.beginLatest());
  jobs.noteSlice(2501, 2000);
  assert(jobs.sliceBudgetExceeded());
  assert(jobs.checkpoint(true) == StopReason::Shutdown);
  jobs.cancelActive();

  // Sequence generation remains monotonic even if a caller accidentally
  // reuses an old number.
  const Version normalized = jobs.submit({1, 0, 0, 0, 0, 0});
  assert(normalized.sequence == 12);

  // Screen recreation invalidates active work without resetting the sequence;
  // a newly submitted request can never collide with the cancelled token.
  assert(jobs.beginLatest());
  const Version invalidated = jobs.invalidate();
  assert(invalidated.sequence == 13);
  assert(jobs.state() == State::Idle);
  const Version afterRecreation = jobs.submit({1, 0, 0, 0, 0, 0});
  assert(afterRecreation.sequence == 14);
  assert(jobs.diagnostics().cancelled >= 3);
  return 0;
}
