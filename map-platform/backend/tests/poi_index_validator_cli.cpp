#include "mapPoiIndex.hpp"
#include <algorithm>
#include <iostream>
#include <string>
#include <vector>

int main() {
  std::string line;
  while (std::getline(std::cin, line)) {
    std::vector<uint8_t> bytes;
    for (size_t offset = 0; offset + 1 < line.size(); offset += 2)
      bytes.push_back(static_cast<uint8_t>(std::stoul(line.substr(offset, 2), nullptr, 16)));
    // Deliberately cross both header and record boundaries at varying sizes.
    bool valid = line.size() % 2 == 0;
    map_poi_index::StreamValidator validator;
    for (size_t offset = 0; offset < bytes.size() && valid;) {
      const size_t count = std::min(bytes.size() - offset, size_t(1 + offset % 37));
      valid = validator.feed(bytes.data() + offset, count);
      offset += count;
    }
    std::cout << (valid && validator.finish() ? "1" : "0") << '\n';
  }
}
