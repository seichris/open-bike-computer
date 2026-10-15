#include "../../lib/ride_diagnostics/capture_policy_v2.hpp"
#include <cassert>
#include <iostream>
using namespace ride_diagnostics;
int main() {
  policy_v2::State state;
  policy_v2::Request request;
  std::string id="123e4567-e89b-12d3-a456-426614174000";
  std::string command="policy|2|"+id+"|1|"+std::to_string(registry::domainMask("ble"))+"|0|10|2048|"+registry::kSha256;
  assert(policy_v2::parse(command,request));
  assert(!policy_v2::parse(command+"|",request));
  assert(!policy_v2::parse(command+"x",request));
  assert(policy_v2::parse(command,request));
  assert(!policy_v2::apply(state,request,UINT32_MAX-2000,"different"));
  assert(policy_v2::apply(state,request,UINT32_MAX-2000,id.c_str()));
  assert(policy_v2::admit(state,0,registry::domainMask("ble"),1000,id.c_str(),768));
  const auto remaining=state.remaining;
  assert(policy_v2::apply(state,request,1000,id.c_str()));
  assert(state.remaining==remaining); // retry cannot extend budget or deadline
  assert(!policy_v2::admit(state,0,registry::domainMask("map"),1000,id.c_str(),768));
  assert(policy_v2::admit(state,1,registry::domainMask("ble"),1000,id.c_str(),768));
  assert(!policy_v2::admit(state,0,registry::domainMask("ble"),1000,id.c_str(),768));
  assert(policy_v2::admit(state,5,0,20000,id.c_str(),768)); // critical survives exhausted trace
  assert(!policy_v2::active(state,8000,id.c_str())); // unsigned millis wrap
  request.generation=2;
  assert(policy_v2::apply(state,request,30000,id.c_str()));
  request.generation=1;
  assert(!policy_v2::apply(state,request,31000,id.c_str()));
  request.mask=~registry::kInstrumentedMask;
  assert(!policy_v2::valid(request));
  std::cout << "Bounded capture policy, replay, domain and wrap tests passed\n";
}
