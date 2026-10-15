#include "../../lib/ble_navigation/map_transfer_status_chunk_session.hpp"

#include <cassert>
#include <cstdlib>
#include <new>

namespace {
struct alignas(std::max_align_t) Allocation { size_t bytes; };
size_t liveBytes = 0;
size_t allocations = 0;
size_t requireZeroBytes = 0;
}

void *operator new(size_t bytes) {
  auto *allocation = static_cast<Allocation *>(std::malloc(sizeof(Allocation) + bytes));
  if (allocation == nullptr) throw std::bad_alloc();
  allocation->bytes = bytes;
  liveBytes += bytes;
  ++allocations;
  return allocation + 1;
}
void operator delete(void *pointer) noexcept {
  if (pointer == nullptr) return;
  auto *allocation = static_cast<Allocation *>(pointer) - 1;
  if (requireZeroBytes != 0) {
    assert(allocation->bytes >= requireZeroBytes);
    const auto *bytes = static_cast<const unsigned char *>(pointer);
    for (size_t index = 0; index < requireZeroBytes; ++index) assert(bytes[index] == 0);
  }
  liveBytes -= allocation->bytes;
  std::free(allocation);
}
#if defined(__cpp_sized_deallocation)
void operator delete(void *pointer, size_t) noexcept { ::operator delete(pointer); }
#endif

int main() {
  using namespace map_transfer_status_protocol;
  assert(!fitsAuthenticatedNotification(1, 25, 256));
  assert(fitsAuthenticatedNotification(160, 185, 256));
  assert(!fitsAuthenticatedNotification(161, 185, 256));
  assert(fitsAuthenticatedNotification(234, 512, 256));
  assert(!fitsAuthenticatedNotification(235, 512, 256));
  ChunkTransmission sender;
  const size_t baseline = liveBytes;
  std::string body(3000, 'a');
  const size_t oneBody = liveBytes;
  size_t before = allocations;
  assert(sender.beginStable(std::move(body), 128));
  assert(allocations == before && liveBytes == oneBody); // ownership, not a copy
  const uint8_t first = static_cast<uint8_t>(sender.nextFrame("DSTC")[4]);
  while (sender.active()) sender.advance();
  sender.finishStable();

  std::string same(3000, 'a');
  before = allocations;
  assert(sender.beginStable(std::move(same), 128));
  assert(allocations == before && liveBytes == oneBody);
  assert(static_cast<uint8_t>(sender.nextFrame("DSTC")[4]) == first);
  std::string changed(3000, 'a');
  changed.back() = 'b';
  assert(!sender.beginStable(std::move(changed), 128)); // preserve in-flight body
  assert(changed.size() == 3000);
  while (sender.active()) sender.advance();
  sender.finishStable();
  assert(!sender.beginStable(std::move(changed), 0));
  assert(changed.size() == 3000);
  assert(sender.beginStable(std::move(changed), 128));
  const uint8_t second = static_cast<uint8_t>(sender.nextFrame("DSTC")[4]);
  assert(second != first); // exact last-byte change creates a new stream
  requireZeroBytes = 3000;
  sender.discardStable();
  requireZeroBytes = 0;
  assert(!sender.active() && sender.bodySize() == 0 && liveBytes == baseline);
  std::string next(3000, 'c');
  assert(sender.beginStable(std::move(next), 128));
  assert(static_cast<uint8_t>(sender.nextFrame("DSTC")[4]) != second);
  requireZeroBytes = 3000;
  sender.discardStable();
  requireZeroBytes = 0;
  assert(liveBytes == baseline); // mode/auth boundary returns retained memory
}
