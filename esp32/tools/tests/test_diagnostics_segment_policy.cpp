#include "../../lib/ride_diagnostics/diagnostics_segment_policy.hpp"
#include <cassert>
int main() {
  using namespace bicino_diagnostics;
  SegmentDescriptor descriptor;
  descriptor.boot = 1; descriptor.chunk = 2; descriptor.bytes = 12345;
  std::memset(descriptor.sha256, 'a', 64);
  assert(descriptor.valid());
  SegmentDescriptor decoded;
  assert(decodeSegmentDescriptor(descriptor.encode(), decoded));
  assert(!decodeSegmentDescriptor(descriptor.encode() + "x", decoded));
  assert(!decodeSegmentDescriptor("", decoded));
  assert(!decodeSegmentDescriptor("BDG2 01 2 12345 " + std::string(64, 'a') + "\n", decoded));
  SegmentRange range;
  const std::string prefix = "/device-diagnostics/v2/range/1/2/" + std::string(64, 'a') + "/";
  assert(parseSegmentRange(prefix + "0/16384", range));
  assert(!parseSegmentRange(prefix + "0/0", range));
  assert(!parseSegmentRange(prefix + "0/16385", range));
  assert(!parseSegmentRange(prefix + "262140/20", range));
  assert(!parseSegmentRange(prefix + "-1/1", range));
  assert(!parseSegmentRange(prefix + "01/1", range));
  assert(!parseSegmentRange(prefix + "0/1/", range));
}
