// Compile the actual recorder maintenance functions with real host files and
// inject a snapshot lease after each possible directory/size operation.
#include "../../lib/ride_diagnostics/ride_diagnostics.hpp"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <sys/stat.h>

using namespace ride_diagnostics;
std::atomic<uint32_t> retentionLeaseDeadlineMs{0};
std::atomic<bool> sealRequested{false};
std::atomic<uint32_t> bootSequence{100};
uint32_t activeChunk = 1;
uint32_t millis() { return 100; }
int operations = 0, injectAfter = 0, openDirectories = 0, deleted = 0;
bool releaseDuringClose = false;
void completedOperation() {
  if (++operations == injectAfter) retentionLeaseDeadlineMs.store(5000);
}
void beforeOperation() { assert(retentionLeaseDeadlineMs.load() == 0); }
DIR *testOpenDirectory(const char *path) {
  beforeOperation();
  DIR *value = opendir(path);
  if (value) ++openDirectories;
  completedOperation();
  return value;
}
dirent *testReadDirectory(DIR *directory) {
  beforeOperation();
  dirent *value = readdir(directory);
  completedOperation();
  return value;
}
int testCloseDirectory(DIR *directory) {
  --openDirectories;
  if (releaseDuringClose) retentionLeaseDeadlineMs.store(0);
  return closedir(directory);
}
enum class StorageBackend { InternalFFat, SD };
class Storage {
public:
  std::string root;
  const char *diagnosticsRootPath() { return root.c_str(); }
  bool getDiagnosticsSdLoaded() { return true; }
  size_t size(const char *path) {
    beforeOperation();
    size_t result = std::filesystem::file_size(path);
    completedOperation();
    return result;
  }
  bool remove(const char *path) {
    beforeOperation();
    bool result = std::filesystem::remove(path);
    if (result) ++deleted;
    return result;
  }
  bool rmdir(const char *path) { return remove(path); }
  uint64_t diagnosticsSdFreeBytes() { return 64ULL * 1024 * 1024; }
  StorageBackend storageBackend() { return StorageBackend::SD; }
};
Storage *storage = nullptr;
const char *diagnosticsRoot() { return storage->diagnosticsRootPath(); }
struct ChunkFile { uint32_t boot, chunk, bytes; time_t modifiedAt; };
constexpr std::size_t kMaximumRetainedFiles = 256, kFilePruneBatch = 16;
ChunkFile retentionFiles[kMaximumRetainedFiles], filePruneCandidates[kFilePruneBatch];
int retentionMutex = 0;
struct SemaphoreGuard { explicit SemaphoreGuard(int) {} ~SemaphoreGuard() {} };
void vTaskDelay(int) {}
bool parseUnsigned(const char *value, uint32_t &out);
#define opendir testOpenDirectory
#define readdir testReadDirectory
#define closedir testCloseDirectory
// PRODUCTION_FUNCTIONS
#undef opendir
#undef readdir
#undef closedir

int main(int argc, char **argv) {
  assert(argc == 2);
  Storage backend{argv[1]};
  storage = &backend;
  const auto boots = std::filesystem::path(backend.root) / "BICINO/DIAGNOSTICS/v1/boots";
  std::filesystem::create_directories(boots / "1");
  for (int chunk = 1; chunk <= 257; ++chunk) {
    char name[64];
    snprintf(name, sizeof(name), "events-%06d.jsonl", chunk);
    std::ofstream(boots / "1" / name) << "test\n";
  }
  ChunkFile files[256], candidates[16];
  const auto baseline = collectChunkFiles(files, 256, candidates, 16);
  assert(!baseline.interrupted && baseline.totalCount == 257);
  const int scanOperations = operations;
  assert(openDirectories == 0);
  for (int boundary = 1; boundary <= scanOperations; ++boundary) {
    retentionLeaseDeadlineMs.store(0);
    operations = deleted = 0;
    injectAfter = boundary;
    pruneRetention();
    assert(operations == boundary);
    assert(openDirectories == 0 && deleted == 0);
    assert(std::filesystem::exists(boots / "1" / "events-000001.jsonl"));
  }
  // A failed/cancelled start may release the lease during close. Partial
  // inventory remains unusable even after the transient request disappears.
  releaseDuringClose = true;
  operations = deleted = 0;
  injectAfter = scanOperations / 2;
  retentionLeaseDeadlineMs.store(0);
  pruneRetention();
  assert(openDirectories == 0 && deleted == 0);
  releaseDuringClose = false;
  retentionLeaseDeadlineMs.store(0);
  injectAfter = operations = 0;
  pruneRetention();
  assert(deleted == 1 && openDirectories == 0);

  std::filesystem::remove_all(boots / "1");
  std::filesystem::create_directories(boots / "2");
  operations = deleted = 0;
  removeEmptyBootDirectories();
  const int cleanupOperations = operations;
  assert(deleted == 1 && openDirectories == 0);
  for (int boundary = 1; boundary <= cleanupOperations; ++boundary) {
    std::filesystem::create_directories(boots / "2");
    retentionLeaseDeadlineMs.store(0);
    operations = deleted = 0;
    injectAfter = boundary;
    removeEmptyBootDirectories();
    assert(openDirectories == 0 && deleted <= 1);
    // A deletion before the lease arrived is legitimate; beforeOperation()
    // rejects every directory read or deletion after its publication.
  }
  retentionLeaseDeadlineMs.store(0);
  injectAfter = operations = deleted = 0;
  // Numeric aliases can parse successfully while exceeding the fixed path
  // buffer. Never prune from an inventory that cannot represent such a path.
  const auto longBoot = boots / (std::string(200, '0') + "1");
  std::filesystem::create_directories(longBoot);
  std::ofstream(longBoot / "events-000001.jsonl") << "test\n";
  const auto incomplete = collectChunkFiles(files, 256, candidates, 16);
  assert(incomplete.interrupted && openDirectories == 0);
  pruneRetention();
  assert(deleted == 0 && openDirectories == 0);
}
