#include "mapBlockFormat.hpp"
#include "mapContourBlock.hpp"
#include <iostream>
#include <string>
#include <vector>

int main() {
  std::string line;
  while (std::getline(std::cin, line)) {
    std::vector<uint8_t> bytes;
    for (size_t index = 0; index < line.size(); index += 2)
      bytes.push_back(static_cast<uint8_t>(std::stoul(line.substr(index, 2), nullptr, 16)));
    const bool whole = map_block_format::validate(bytes.data(), bytes.size());
    map_contour_block::Block decoded;
    if (map_contour_block::decode(bytes.data(), bytes.size(), decoded) != whole) return 3;
    if (map_contour_block::decode(bytes.data(), bytes.size(), decoded, [] { return true; })) return 4;
    if (!decoded.records.empty() || !decoded.points.empty()) return 5;
    for (size_t chunk : {1U, 7U, 64U}) {
      map_block_format::StreamValidator validator("block.fmb");
      bool accepted = true;
      for (size_t offset = 0; offset < bytes.size() && accepted; offset += chunk)
        accepted = validator.feed(bytes.data() + offset, std::min(chunk, bytes.size() - offset));
      if ((accepted && validator.finish()) != whole) return 2;
    }
    std::cout << (whole ? "1" : "0") << '\n';
  }
}
