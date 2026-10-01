#include "../../lib/ride_diagnostics/diagnostics_capture_policy.hpp"
#include <cassert>
#include <string>
using namespace bicino_diagnostics;
int main() {
  const std::string id = "123e4567-e89b-12d3-a456-426614174000";
  const auto levels = std::string(contract::kDomainCount, '0');
  CaptureRequest request;
  assert(parseCaptureRequest("capture|2|" + id + "|1|900|1790900000|" + levels, request));
  for (const auto &bad : {"capture|2|" + id + "|0|900|1790900000|" + levels,
      "capture|2|" + id + "|01|900|1790900000|" + levels,
      "capture|2|" + id + "|1|14401|1790900000|" + levels,
      "capture|2|" + id + "|1|0|1790900000|" + levels,
      "capture|2|" + id + "|1|900|1790900000|" + levels + "|extra"}) {
    CaptureRequest invalid;
    assert(!parseCaptureRequest(bad, invalid));
  }
  CapturePolicy policy;
  assert(!policy.admit(Severity::Trace,"ble",100,0));
  assert(policy.apply(request,UINT32_MAX-1000U) == ApplyResult::Applied);
  assert(policy.admit(Severity::Trace,"ble",100,UINT32_MAX-999U));
  assert(policy.apply(request,500U) == ApplyResult::Duplicate);
  assert(policy.remainingSeconds(500U) == 899U); // replay does not renew
  CaptureRequest conflict=request; conflict.durationSeconds=901;
  assert(policy.apply(conflict,501) == ApplyResult::Conflict);
  for (unsigned i=0;i<100;++i) (void)policy.admit(Severity::Trace,"ble",100,501);
  assert(policy.counters().rateLimited > 0);
  assert(policy.admit(Severity::Error,"ble",768,501));
  assert(policy.admit(Severity::Info,"logger",768,501));
  assert(policy.expire(900000U));
  assert(!policy.admit(Severity::Trace,"ble",100,900001));
  request.generation=2; request.durationSeconds=0; request.expiresAtEpoch=0; request.levels.fill(2);
  assert(policy.apply(request,900002) == ApplyResult::Applied);
  request.generation=1;
  assert(policy.apply(request,900003) == ApplyResult::Stale);
}
