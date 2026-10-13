#include "../../lib/ride_diagnostics/live_tail_v2.hpp"
#include <cassert>
int main() {
  ride_diagnostics::live_v2::Ring ring;
  std::string out;
  out.reserve(2304);
  ring.json(7,0,0,out);
  assert(out.find("\"events\":[]")!=std::string::npos);
  for (uint32_t i=0;i<20;++i) ring.append(i,"{\"event\":\"test\"}\n",17);
  assert(ring.count==16 && ring.at(0).sequence==4);
  ring.json(7,7,0,out);
  assert(out.find("\"gap\":true")!=std::string::npos);
  assert(out.find("\"nextSequence\":5")!=std::string::npos);
  ring.json(7,0,0,out);
  assert(out.find("\"nextSequence\":19")!=std::string::npos);
  assert(out.find("\"more\":false")!=std::string::npos);
  ring.json(7,7,19,out);
  assert(out.find("\"events\":[]")!=std::string::npos);
  ring.json(8,7,19,out);
  assert(out.find("\"gap\":true")!=std::string::npos);
  assert(out.size()<2304);
}
