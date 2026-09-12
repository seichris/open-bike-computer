#include "../../lib/map_transfer/map_file_io.hpp"

#include <cassert>
#include <cstdlib>
#include <iostream>
#include <type_traits>
#include <unistd.h>
#include <vector>

int main() {
  using namespace map_transfer;
  static_assert(!std::is_copy_constructible<MapReadFile>::value);
  static_assert(!std::is_copy_constructible<MapWriteFile>::value);
  char directory[] = "/tmp/map-file-io-XXXXXX";
  assert(::mkdtemp(directory) != nullptr);
  const std::string path = std::string(directory) + "/binary";
  std::string expected(4097, 'x');
  expected[2] = '\0';
  {
    MapWriteFile output(path);
    assert(output.good());
    output.write(expected.data(), expected.size());
    output.flush();
    assert(output.good());
    output.close();
    assert(output.good()); // close preserves success but captures flush errors
    output.write("x", 1);
    assert(output.fail());
  }
  {
    MapReadFile input(path, true);
    assert(input.tell() == static_cast<off_t>(expected.size()));
    input.seek(0);
    std::vector<char> bytes(expected.size());
    input.read(bytes.data(), bytes.size());
    assert(input.good() && !input.eof());
    assert(input.gcount() == bytes.size());
    assert(std::string(bytes.begin(), bytes.end()) == expected);
    input.read(bytes.data(), 1);
    assert(!input.good() && input.eof() && input.gcount() == 0);
    input.clear();
    input.seek(2);
    input.read(bytes.data(), 1);
    assert(input.good() && bytes[0] == '\0');
    input.seek(-1);
    assert(!input.good());
    input.clear();
    input.seek(0);
    std::string text;
    assert(input.readAll(text, expected.size()));
    assert(text == expected);
  }
  {
    MapReadFile input(path);
    std::string text;
    assert(!input.readAll(text, expected.size() - 1));
    assert(text.size() <= expected.size() - 1);
  }
  {
    MapReadFile missing(path + "/missing");
    assert(!missing.good() && !missing.eof());
    missing.clear();
    assert(!missing.good());
    std::string text;
    assert(!missing.readAll(text, 100));
    MapWriteFile invalid(path + "/missing");
    assert(invalid.fail());
    invalid.flush();
    invalid.close();
    assert(invalid.fail());
    MapReadFile directoryInput(directory);
    assert(!directoryInput.readAll(text, 100));
  }
  {
    MapWriteFile truncate(path);
    truncate.close();
    assert(truncate.good());
    MapReadFile empty(path);
    std::string text = "old";
    assert(empty.readAll(text, 0));
    assert(text.empty());
  }
  {
    // An exception still closes and flushes the locally owned handle.
    try {
      MapWriteFile output(path);
      output.write("abc", 3);
      throw 1;
    } catch (int) {
    }
    MapReadFile input(path);
    std::string text;
    assert(input.readAll(text, 3) && text == "abc");
  }
#ifdef __linux__
  {
    MapWriteFile full("/dev/full");
    assert(full.good());
    full.write("buffered", 8);
    full.flush();
    assert(full.fail());
    full.close();
    assert(full.fail());
    MapWriteFile closeFailure("/dev/full");
    closeFailure.write("buffered", 8);
    closeFailure.close();
    assert(closeFailure.fail());
  }
#endif
  assert(std::remove(path.c_str()) == 0);
  assert(::rmdir(directory) == 0);
  std::cout << "map file I/O tests passed\n";
}
