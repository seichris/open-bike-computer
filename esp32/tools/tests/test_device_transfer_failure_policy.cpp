#include "../../lib/device_transfer/device_transfer_failure_policy.hpp"

#include <cassert>
#include <cstdint>

using namespace device_transfer::failure_policy;

int main() {
  constexpr int32_t wantRead = -0x6900;
  constexpr int32_t wantWrite = -0x6880;
  assert(classifyTlsWrite(wantRead, 4096, wantRead, wantWrite) ==
         TlsWriteOutcome::WantRead);
  assert(classifyTlsWrite(wantWrite, 4096, wantRead, wantWrite) ==
         TlsWriteOutcome::WantWrite);
  assert(classifyTlsWrite(0, 4096, wantRead, wantWrite) ==
         TlsWriteOutcome::RawZero);
  assert(classifyTlsWrite(-0x7000, 4096, wantRead, wantWrite) ==
         TlsWriteOutcome::Fatal);
  assert(classifyTlsWrite(1024, 4096, wantRead, wantWrite) ==
         TlsWriteOutcome::PositivePartial);
  assert(classifyTlsWrite(4096, 4096, wantRead, wantWrite) ==
         TlsWriteOutcome::PositiveComplete);

  // A positive partial write is progress. Only real elapsed time since the
  // latest progress determines the terminal timeout, including clock wrap.
  uint32_t lastProgress = 100;
  assert(!noProgressExpired(5099, lastProgress, 5000));
  assert(noProgressExpired(5100, lastProgress, 5000));
  lastProgress = UINT32_MAX - 10;
  assert(!noProgressExpired(8, lastProgress, 20));
  assert(noProgressExpired(9, lastProgress, 20));

  assert(fileReadFailed(0, false)); // EOF before declared length.
  assert(fileReadFailed(0, true));  // Read error.
  assert(fileReadFailed(2048, true)); // Positive short read with ferror.
  assert(!fileReadFailed(2048, false)); // Positive short read may be valid.

  assert(authorizationBits(true, true, true, true, true, true) == 63);
  assert(authorizationBits(true, true, false, true, true, false) == 27);
  assert(authorizationBits(false, true, false, false, false, false) == 2);
}
