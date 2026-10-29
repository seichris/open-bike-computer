// Production writable probe, Storage descriptor methods, catalog writes and
// recorder chunk open/close against real host files. The test driver renames
// their global POSIX calls (::open, ::write, ::read, ::fsync, ::close and
// ::unlink) to the fault points below, which fail one chosen call with ENOMEM
// or EIO, as an SDMMC bounce or FatFs allocation failure would on the board.
// stdio is poisoned: newlib's fopen() aborts when it cannot allocate a stream
// lock from internal RAM, so none of these paths may reach it.
#include "../../lib/storage/storage_stream_admission.hpp"
#include "../../lib/ride_diagnostics/catalog_v2.hpp"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #condition);                                                \
      std::exit(42);                                                           \
    }                                                                          \
  } while (0)

int failAt = 0, failErrno = ENOMEM, calls = 0, openDescriptors = 0;
std::size_t maximumTransfer = SIZE_MAX;
bool failNow() {
  ++calls;
  if (failAt == 0 || calls != failAt)
    return false;
  errno = failErrno;
  return true;
}
int faultOpen(const char *path, int flags, int mode) {
  if (failNow()) return -1;
  const int descriptor = ::open(path, flags, mode);
  if (descriptor >= 0) ++openDescriptors;
  return descriptor;
}
ssize_t faultWrite(int descriptor, const void *data, size_t size) {
  if (failNow()) return -1;
  return ::write(descriptor, data, std::min(size, maximumTransfer));
}
ssize_t faultRead(int descriptor, void *data, size_t size) {
  if (failNow()) return -1;
  return ::read(descriptor, data, std::min(size, maximumTransfer));
}
int faultFsync(int descriptor) {
  if (failNow()) return -1;
  return ::fsync(descriptor);
}
// Like POSIX close() after EIO, a failed close still releases the descriptor.
int faultClose(int descriptor) {
  const bool fail = failNow();
  const int result = ::close(descriptor);
  if (result == 0) --openDescriptors;
  if (!fail) return result;
  errno = failErrno;
  return -1;
}
int faultUnlink(const char *path) {
  if (failNow()) return -1;
  return ::unlink(path);
}

namespace power_management {
enum class LockDomain { Storage };
struct ScopedLock {
  explicit ScopedLock(LockDomain) {}
};
} // namespace power_management

// PRODUCTION_EVIDENCE

class Storage {
public:
  storage_shutdown::StreamAdmission streamAdmission_;
  std::atomic<bool> shutdownAdmissionClosed_{false};
  std::string root;
  int openDescriptor(const char *path, int flags);
  int closeDescriptor(int descriptor);
  size_t writeDescriptor(int descriptor, const uint8_t *buffer, size_t size);
  StorageReadEvidence readDescriptor(int descriptor, uint8_t *buffer,
                                     size_t size);
  int syncDescriptor(int descriptor);
  // Host helpers outside this test's scope.
  bool getDiagnosticsSdLoaded() const { return true; }
  bool mkdir(const char *path) { return ::mkdir(path, 0777) == 0; }
  size_t size(const char *path) {
    struct stat metadata = {};
    return ::stat(path, &metadata) == 0 ? static_cast<size_t>(metadata.st_size) : 0;
  }
  bool remove(const char *path) { return std::remove(path) == 0; }
};

Storage *storage = nullptr;
int activeDescriptor = -1;
std::atomic<uint32_t> nextSequence{0}, bootSequence{7}, activeChunkSnapshot{1};
uint32_t activeChunk = 1, activeFileBytes = 0;
char activePath[192] = {};
constexpr std::size_t kMaximumRetainedFiles = 256;
int activeHash = 0;
bool activeHashValid = false;
void mbedtls_sha256_free(int *) {}
void mbedtls_sha256_init(int *) {}
int mbedtls_sha256_starts(int *, int) { return 0; }
const char *diagnosticsRoot() { return storage->root.c_str(); }

#pragma GCC poison fopen freopen fdopen

namespace {
// PRODUCTION_PROBE
} // namespace

// PRODUCTION_DESCRIPTORS

// PRODUCTION_RECORDER

namespace {
std::string root;

bool exists(const std::string &path) {
  struct stat metadata = {};
  return ::stat(path.c_str(), &metadata) == 0;
}
void arm(int step, int error) {
  calls = 0;
  failAt = step;
  failErrno = error;
}
void disarm() { failAt = 0; }
bool drained(Storage &owner) {
  owner.streamAdmission_.closeAdmission();
  return owner.streamAdmission_.quiescent();
}

void probeFailsSafelyAtEveryStep() {
  const std::string probe = root + "/.bicino-diag-probe";
  arm(0, 0);
  CHECK(writableProbeSucceeded(root.c_str()));
  CHECK(calls == 5 && openDescriptors == 0 && !exists(probe));
  for (int error : {ENOMEM, EIO}) {
    for (int step = 1; step <= 5; ++step) {
      arm(step, error);
      CHECK(!writableProbeSucceeded(root.c_str()));
      CHECK(openDescriptors == 0);
      // Only a failed unlink may leave the probe behind.
      CHECK(exists(probe) == (step == 5));
      disarm();
      ::unlink(probe.c_str());
    }
  }
  // An over-long root never reaches the filesystem.
  arm(0, 0);
  const std::string longRoot(200, 'x');
  CHECK(!writableProbeSucceeded(longRoot.c_str()) && calls == 0);
}

void descriptorsKeepAdmissionExact() {
  const std::string path = root + "/descriptor.bin";
  {
    Storage owner;
    arm(1, ENOMEM);
    CHECK(owner.openDescriptor(path.c_str(), O_WRONLY | O_CREAT) < 0);
    CHECK(errno == ENOMEM && openDescriptors == 0 && drained(owner));
  }
  {
    // A foreign descriptor is refused, never closed beneath its owner.
    Storage owner;
    disarm();
    const int foreign = ::open(path.c_str(), O_WRONLY | O_CREAT, 0644);
    CHECK(foreign >= 0);
    CHECK(owner.closeDescriptor(foreign) < 0 && errno == EINVAL);
    CHECK(::fcntl(foreign, F_GETFD) != -1);
    ::close(foreign);
    CHECK(drained(owner));
  }
  {
    Storage owner;
    disarm();
    maximumTransfer = 3;
    const int descriptor =
        owner.openDescriptor(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC);
    CHECK(descriptor >= 0);
    const uint8_t data[10] = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9'};
    CHECK(owner.writeDescriptor(descriptor, data, sizeof(data)) == sizeof(data));
    arm(3, EIO); // the third short write fails
    CHECK(owner.writeDescriptor(descriptor, data, sizeof(data)) == 6);
    arm(1, ENOMEM);
    CHECK(owner.syncDescriptor(descriptor) < 0 && errno == ENOMEM);
    disarm();
    CHECK(owner.syncDescriptor(descriptor) == 0);
    CHECK(owner.closeDescriptor(descriptor) == 0 && openDescriptors == 0);
    CHECK(drained(owner));
  }
  {
    Storage owner;
    disarm();
    const int descriptor = owner.openDescriptor(path.c_str(), O_RDONLY);
    CHECK(descriptor >= 0);
    uint8_t buffer[32] = {};
    const StorageReadEvidence full =
        owner.readDescriptor(descriptor, buffer, sizeof(buffer));
    CHECK(full.returned == 16 && full.eof && !full.error);
    CHECK(std::memcmp(buffer, "0123456789012345", 16) == 0);
    CHECK(::lseek(descriptor, 0, SEEK_SET) == 0);
    arm(2, EIO); // fails after one successful short read
    const StorageReadEvidence partial =
        owner.readDescriptor(descriptor, buffer, sizeof(buffer));
    CHECK(partial.returned == 3 && partial.error && !partial.eof);
    CHECK(partial.errorNumber == EIO);
    arm(1, EIO); // close reports failure but still releases its descriptor
    CHECK(owner.closeDescriptor(descriptor) < 0 && openDescriptors == 0);
    // The uncertain close is latched for the shutdown barrier.
    CHECK(!drained(owner));
    maximumTransfer = SIZE_MAX;
  }
  {
    Storage owner;
    disarm();
    owner.streamAdmission_.closeAdmission();
    CHECK(owner.openDescriptor(path.c_str(), O_RDONLY) < 0 && errno == EBUSY);
    CHECK(openDescriptors == 0);
  }
}

void catalogFailuresLeaveNoPartialDescriptor() {
  Storage owner;
  storage = &owner;
  const std::string chunk = root + "/events-000001.jsonl";
  const std::string catalog = chunk + ".cat2";
  ride_diagnostics::catalog_v2::Descriptor written;
  written.boot = 7;
  written.chunk = 1;
  written.bytes = 640;
  written.firstSequence = 3;
  written.lastSequence = 9;
  written.digest.fill(0x5a);
  for (int error : {ENOMEM, EIO}) {
    for (int step = 1; step <= 3; ++step) { // open, write, close
      arm(step, error);
      CHECK(!ride_diagnostics::catalog_v2::write(owner, chunk.c_str(), written));
      disarm();
      CHECK(openDescriptors == 0 && !exists(catalog) && !exists(catalog + ".tmp"));
    }
  }
  disarm();
  CHECK(ride_diagnostics::catalog_v2::write(owner, chunk.c_str(), written));
  CHECK(exists(catalog) && !exists(catalog + ".tmp"));
  ride_diagnostics::catalog_v2::Descriptor loaded;
  for (int step = 1; step <= 3; ++step) { // open, read, close
    arm(step, EIO);
    CHECK(!ride_diagnostics::catalog_v2::read(owner, chunk.c_str(), 7, 1, 640, loaded));
    CHECK(openDescriptors == 0);
  }
  disarm();
  CHECK(ride_diagnostics::catalog_v2::read(owner, chunk.c_str(), 7, 1, 640, loaded));
  CHECK(loaded.lastSequence == 9 && loaded.digest == written.digest);
  CHECK(drained(owner) == false); // read close failure above stays latched
}

void chunkLifecycleReleasesDescriptors() {
  Storage owner;
  owner.root = root;
  storage = &owner;
  arm(0, 0);
  // ensurePaths creates five directories (stat/mkdir are not faulted), then
  // openActiveFile opens the chunk: that open is the first faulted call.
  arm(1, ENOMEM);
  CHECK(!openActiveFile() && activeDescriptor < 0 && openDescriptors == 0);
  disarm();
  CHECK(openActiveFile() && activeDescriptor >= 0 && openDescriptors == 1);
  CHECK(std::strstr(activePath, "/BICINO/DIAGNOSTICS/v1/boots/7/events-000001.jsonl"));
  const uint8_t line[] = "{}\n";
  CHECK(owner.writeDescriptor(activeDescriptor, line, 3) == 3);
  arm(1, ENOMEM); // fsync
  CHECK(closeActiveFile() == ActiveFileCloseResult::FlushFailed);
  CHECK(activeDescriptor < 0 && openDescriptors == 0);
  disarm();
  activeChunk = 2;
  CHECK(openActiveFile() && openDescriptors == 1);
  arm(2, EIO); // fsync succeeds, close fails
  CHECK(closeActiveFile() == ActiveFileCloseResult::CloseFailed);
  CHECK(activeDescriptor < 0 && openDescriptors == 0);
  disarm();
  activeChunk = 3;
  CHECK(openActiveFile());
  CHECK(closeActiveFile() == ActiveFileCloseResult::Ready && openDescriptors == 0);
}
} // namespace

int main(int argc, char **argv) {
  CHECK(argc == 2);
  root = argv[1];
  CHECK(::mkdir(root.c_str(), 0777) == 0);
  probeFailsSafelyAtEveryStep();
  descriptorsKeepAdmissionExact();
  catalogFailuresLeaveNoPartialDescriptor();
  chunkLifecycleReleasesDescriptors();
  std::puts("Probe, descriptors, catalog and chunk lifecycle fail with errors, never stdio, and release every descriptor");
}
