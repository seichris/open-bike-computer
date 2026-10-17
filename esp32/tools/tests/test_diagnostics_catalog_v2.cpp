#include "../../lib/ride_diagnostics/catalog_v2.hpp"
#include <cassert>
#include <iostream>
using namespace ride_diagnostics;
int main() {
  catalog_v2::Descriptor input; input.boot=7; input.chunk=2; input.bytes=1024;
  input.firstSequence=40; input.lastSequence=60; input.digest.fill(0xab);
  auto encoded=catalog_v2::encode(input);
  catalog_v2::Descriptor output;
  assert(catalog_v2::decode(encoded.data(),encoded.size(),output));
  assert(output.boot==7 && output.chunk==2 && output.bytes==1024);
  assert(output.firstSequence==40 && output.lastSequence==60);
  assert(catalog_v2::hex(output)==std::string("abababababababababababababababababababababababababababababababab"));
  assert(!catalog_v2::decode(encoded.data(),encoded.size()-1,output));
  encoded[40]^=1;
  assert(!catalog_v2::decode(encoded.data(),encoded.size(),output));
  input.bytes=0; encoded=catalog_v2::encode(input);
  assert(!catalog_v2::decode(encoded.data(),encoded.size(),output));
  std::cout << "Diagnostic seal descriptor, corruption and torn metadata tests passed\n";
}
