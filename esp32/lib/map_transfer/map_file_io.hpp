#pragma once

#include <array>
#include <cstdio>
#include <string>
#include <sys/types.h>

namespace map_transfer {

// Map files are binary byte streams: locale/conversion-aware C++ file buffers
// are unnecessary here and consume scarce production OTA space. Keep resource
// ownership and sticky error state explicit, including errors discovered when
// buffered output is flushed or closed.
class MapReadFile {
public:
  explicit MapReadFile(const std::string &path, bool atEnd = false)
      : file_(std::fopen(path.c_str(), "rb")), failed_(file_ == nullptr) {
    if (file_ != nullptr && atEnd && ::fseeko(file_, 0, SEEK_END) != 0)
      failed_ = true;
  }
  ~MapReadFile() {
    if (file_ != nullptr)
      std::fclose(file_);
  }
  MapReadFile(const MapReadFile &) = delete;
  MapReadFile &operator=(const MapReadFile &) = delete;

  explicit operator bool() const { return good(); }
  bool good() const { return !failed_; }
  bool eof() const {
    return file_ != nullptr && std::feof(file_) != 0 && std::ferror(file_) == 0;
  }
  size_t gcount() const { return count_; }
  void read(char *bytes, size_t size) {
    count_ = 0;
    if (failed_)
      return;
    count_ = std::fread(bytes, 1, size, file_);
    failed_ = count_ != size || std::ferror(file_) != 0;
  }
  void clear() {
    if (file_ != nullptr) {
      std::clearerr(file_);
      failed_ = false;
    }
  }
  void seek(off_t offset) {
    if (!failed_ && ::fseeko(file_, offset, SEEK_SET) != 0)
      failed_ = true;
  }
  off_t tell() const {
    return failed_ ? static_cast<off_t>(-1) : ::ftello(file_);
  }
  bool readAll(std::string &text, size_t maximumBytes) {
    text.clear();
    std::array<char, 1024> buffer{};
    while (good()) {
      read(buffer.data(), buffer.size());
      if (gcount() > maximumBytes - text.size())
        return false;
      text.append(buffer.data(), gcount());
    }
    return eof() && std::ferror(file_) == 0;
  }

private:
  FILE *file_ = nullptr;
  bool failed_ = false;
  size_t count_ = 0;
};

class MapWriteFile {
public:
  explicit MapWriteFile(const std::string &path)
      : file_(std::fopen(path.c_str(), "wb")), failed_(file_ == nullptr) {}
  ~MapWriteFile() {
    if (file_ != nullptr)
      std::fclose(file_);
  }
  MapWriteFile(const MapWriteFile &) = delete;
  MapWriteFile &operator=(const MapWriteFile &) = delete;

  explicit operator bool() const { return good(); }
  bool good() const { return !failed_; }
  bool fail() const { return failed_; }
  void write(const char *bytes, size_t size) {
    if (file_ == nullptr || failed_) {
      failed_ = true;
      return;
    }
    if (std::fwrite(bytes, 1, size, file_) != size || std::ferror(file_) != 0)
      failed_ = true;
  }
  void flush() {
    if (file_ == nullptr || std::fflush(file_) != 0)
      failed_ = true;
  }
  void close() {
    if (file_ == nullptr) {
      failed_ = true;
      return;
    }
    if (std::fclose(file_) != 0)
      failed_ = true;
    file_ = nullptr;
  }

private:
  FILE *file_ = nullptr;
  bool failed_ = false;
};

} // namespace map_transfer
