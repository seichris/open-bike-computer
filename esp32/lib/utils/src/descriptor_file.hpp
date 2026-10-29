#pragma once

#include <cerrno>
#include <cstddef>
#include <fcntl.h>
#include <unistd.h>

// Task-owned byte files. ESP-IDF newlib fopen can abort allocating its internal
// stream lock; POSIX descriptors report allocation/I/O errors instead. These
// helpers add no buffer, heap allocation, lock or storage ownership policy.
namespace descriptor_file {
inline ssize_t readSome(int fd, void *buffer, size_t size) {
  ssize_t result;
  do { result = ::read(fd, buffer, size); } while (result < 0 && errno == EINTR);
  return result;
}
inline bool readExact(int fd, void *buffer, size_t size) {
  auto *bytes = static_cast<unsigned char *>(buffer);
  size_t done = 0;
  while (done < size) {
    const ssize_t count = readSome(fd, bytes + done, size - done);
    if (count <= 0) return false;
    done += static_cast<size_t>(count);
  }
  return true;
}
inline bool writeAll(int fd, const void *buffer, size_t size) {
  const auto *bytes = static_cast<const unsigned char *>(buffer);
  size_t done = 0;
  while (done < size) {
    ssize_t count;
    do { count = ::write(fd, bytes + done, size - done); }
    while (count < 0 && errno == EINTR);
    if (count <= 0) return false;
    done += static_cast<size_t>(count);
  }
  return true;
}

class File {
public:
  File() = default;
  File(const char *path, int flags) : fd_(::open(path, flags, 0644)) {}
  ~File() { reset(); }
  File(const File &) = delete;
  File &operator=(const File &) = delete;
  File(File &&other) noexcept : fd_(other.release()) {}
  File &operator=(File &&other) noexcept {
    if (this != &other) { reset(); fd_ = other.release(); }
    return *this;
  }
  explicit operator bool() const { return fd_ >= 0; }
  int get() const { return fd_; }
  int release() { const int fd = fd_; fd_ = -1; return fd; }
  // The pinned FAT VFS retires the handle even if close reports a flush error.
  // Never retry close on a descriptor that another task might have reused.
  int close() { return fd_ < 0 ? -1 : ::close(release()); }
  void reset() { if (fd_ >= 0) (void)close(); }
private:
  int fd_ = -1;
};
} // namespace descriptor_file
