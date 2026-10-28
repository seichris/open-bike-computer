#pragma once

#include "../utils/src/descriptor_file.hpp"
#include <string>

namespace map_transfer {

// Binary files use checked POSIX I/O: newlib stream-lock allocation can abort
// under internal-memory pressure. Preserve sticky errors and exact EOF rules.
class MapReadFile {
public:
  explicit MapReadFile(const std::string &path, bool atEnd = false)
      : file_(path.c_str(), O_RDONLY), failed_(!file_) {
    if (file_ && atEnd && ::lseek(file_.get(), 0, SEEK_END) < 0)
      failed_ = true;
  }
  MapReadFile(const MapReadFile &) = delete;
  MapReadFile &operator=(const MapReadFile &) = delete;

  explicit operator bool() const { return good(); }
  bool good() const { return !failed_; }
  bool eof() const { return eof_ && !ioError_; }
  size_t gcount() const { return count_; }
  void read(char *bytes, size_t size) {
    count_ = 0;
    if (failed_) return;
    while (count_ < size) {
      const ssize_t count = descriptor_file::readSome(
          file_.get(), bytes + count_, size - count_);
      if (count <= 0) {
        eof_ = count == 0;
        ioError_ = count < 0;
        failed_ = true;
        return;
      }
      count_ += static_cast<size_t>(count);
    }
  }
  void clear() {
    if (file_) { failed_ = false; eof_ = false; ioError_ = false; }
  }
  void seek(off_t offset) {
    if (!failed_) {
      if (::lseek(file_.get(), offset, SEEK_SET) < 0) failed_ = true;
      else eof_ = false;
    }
  }
  off_t tell() const {
    return failed_ ? static_cast<off_t>(-1) : ::lseek(file_.get(), 0, SEEK_CUR);
  }
  // One exact allocation; reject short data, I/O errors and growth after stat.
  bool readAll(std::string &text, size_t expectedBytes) {
    text.clear();
    if (!good()) return false;
    text.resize(expectedBytes);
    if (expectedBytes != 0) read(&text[0], expectedBytes);
    if (!good()) return false;
    char trailing = 0;
    const ssize_t extra = descriptor_file::readSome(file_.get(), &trailing, 1);
    eof_ = extra == 0;
    ioError_ = extra < 0;
    if (ioError_) failed_ = true;
    return extra == 0;
  }

private:
  descriptor_file::File file_;
  bool failed_ = false, eof_ = false, ioError_ = false;
  size_t count_ = 0;
};

class MapWriteFile {
public:
  explicit MapWriteFile(const std::string &path)
      : file_(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC), failed_(!file_) {}
  MapWriteFile(const MapWriteFile &) = delete;
  MapWriteFile &operator=(const MapWriteFile &) = delete;

  explicit operator bool() const { return good(); }
  bool good() const { return !failed_; }
  bool fail() const { return failed_; }
  void write(const char *bytes, size_t size) {
    if (!file_ || failed_ || !descriptor_file::writeAll(file_.get(), bytes, size))
      failed_ = true;
  }
  void flush() {
    // There is no userspace buffer. Prior writes reached VFS synchronously;
    // FAT close commits the entry, as with the previous fflush + fclose path.
    if (!file_) failed_ = true;
  }
  void close() {
    if (file_.close() != 0) failed_ = true;
  }

private:
  descriptor_file::File file_;
  bool failed_ = false;
};

} // namespace map_transfer
