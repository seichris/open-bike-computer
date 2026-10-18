#include "../../lib/status_json/json_builder.hpp"

#include <cstdint>
#include <cstdio>
#include <limits>
#include <string_view>

int main() {
  status_json::JsonBuilder body;
  body << "{\"unsigned\":" << std::numeric_limits<uint64_t>::max()
       << ",\"signed\":" << std::numeric_limits<int64_t>::min()
       << ",\"byte\":" << uint8_t{255}
       << ",\"text\":\""
       << status_json::JsonBuilder::EscapedText{"\"\\\b\f\n\r\t\x01" "é"}
       << "\",\"nullText\":\""
       << status_json::JsonBuilder::EscapedText{nullptr}
       << "\",\"view\":\"" << std::string_view("prefix-suffix", 6)
       << "\",\"requestId\":" << std::numeric_limits<uint32_t>::max() << '}';
  const std::string json = body.take();
  std::puts(json.c_str());
}
