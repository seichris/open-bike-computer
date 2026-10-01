#include "../../lib/ride_diagnostics/diagnostics_tail_policy.hpp"
#include <cassert>
#include <cstring>
int main() {
  using namespace bicino_diagnostics;
  TailRequest r;
  assert(parseTailRequest("tail|2|0|0|8", r));
  for (auto bad : {"tail|2|0|0|0", "tail|2|0|0|9", "tail|2|01|0|8", "tail|2|4294967296|0|8", "tail|2|0|0|8|"}) assert(!parseTailRequest(bad, r));
  TailRing<4> ring; ring.begin(7); TailRing<4>::Page page;
  ring.page({0,0,8}, page); assert(page.count==0 && page.bootChanged);
  for (uint32_t n=0; n<10; ++n) assert(ring.append(n,"{}\n",3));
  ring.page({0,0,2},page); assert(page.count==2 && page.events[0].sequence==6 && page.next==7 && page.more && page.bootChanged);
  ring.page({7,7,2},page); assert(page.count==2 && page.next==9 && !page.more && !page.gap);
  ring.page({7,0,8},page); assert(page.gap && page.count==4);
  ring.page({7,9,8},page); assert(page.count==0 && page.next==9);
  ring.begin(8); assert(ring.append(0,"{}\n",3));
  ring.page({7,9,8},page); assert(page.bootChanged && page.events[0].sequence==0);
  assert(!ring.append(1,"secret",6));
}
