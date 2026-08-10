#include "../../lib/ride_automation/ride_automation_protocol.hpp"

#include <cassert>
#include <cstdint>
#include <cstring>

int main() {
  using namespace ride_automation_protocol;
  Frame input;
  input.kind = Kind::Decision;
  input.transition = Transition::Pause;
  input.origin = Origin::Automatic;
  input.rideGeneration = 0x01020304;
  input.decisionSequence = 0x11223344;
  input.evidenceMask = 0x55AA;
  input.profileVersion = 1;
  input.sessionID = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                     0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF};
  input.watermarkOrConfigGeneration = 7;
  input.startMode = 1;
  input.autoPauseEnabled = true;
  input.alertMode = 2;
  input.candidateBeganSeconds = 88;
  input.monotonicSeconds = 99;
  input.sourceHealthMask = 0x000F;

  uint8_t bytes[FRAME_SIZE]{};
  assert(encode(input, bytes, sizeof(bytes)));
  const uint8_t golden[FRAME_SIZE] = {
      2,    1,    2,    2,    0,    1,    1,    2,
      0x04, 0x03, 0x02, 0x01, 0x44, 0x33, 0x22, 0x11,
      0xAA, 0x55, 0x01, 0x00, 0x00, 0x11, 0x22, 0x33,
      0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB,
      0xCC, 0xDD, 0xEE, 0xFF,
      0x07, 0x00, 0x00, 0x00, 0x58, 0x00, 0x00, 0x00,
      0x63, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00,
  };
  assert(std::memcmp(bytes, golden, sizeof(golden)) == 0);

  Frame decoded;
  assert(decode(bytes, sizeof(bytes), decoded));
  assert(decoded.kind == input.kind);
  assert(decoded.transition == input.transition);
  assert(decoded.origin == input.origin);
  assert(decoded.rideGeneration == input.rideGeneration);
  assert(decoded.decisionSequence == input.decisionSequence);
  assert(decoded.evidenceMask == input.evidenceMask);
  assert(decoded.profileVersion == input.profileVersion);
  assert(decoded.sessionID == input.sessionID);
  assert(decoded.watermarkOrConfigGeneration == 7);
  assert(decoded.autoPauseEnabled);
  assert(decoded.candidateBeganSeconds == 88);
  assert(decoded.monotonicSeconds == 99);
  assert(decoded.sourceHealthMask == 0x000F);
  assert(decoded.acknowledgedKind == 0);

  assert(!decode(bytes, FRAME_SIZE - 1, decoded));
  bytes[0] = 1;
  assert(!decode(bytes, FRAME_SIZE, decoded));
  bytes[0] = PROTOCOL_VERSION;
  bytes[1] = 99;
  assert(!decode(bytes, FRAME_SIZE, decoded));
  bytes[1] = static_cast<uint8_t>(Kind::Decision);
  bytes[12] = bytes[13] = bytes[14] = bytes[15] = 0;
  assert(!decode(bytes, FRAME_SIZE, decoded));

  Frame configuration;
  configuration.kind = Kind::Configuration;
  configuration.rideGeneration = 1;
  configuration.profileVersion = 1;
  configuration.watermarkOrConfigGeneration = 9;
  configuration.startMode = 2;
  assert(encode(configuration, bytes, sizeof(bytes)));
  assert(decode(bytes, sizeof(bytes), decoded));
  assert(decoded.decisionSequence == 0);

  Frame promptResponse = input;
  promptResponse.kind = Kind::PromptResponse;
  promptResponse.transition = Transition::Start;
  promptResponse.result = Result::Accepted;
  assert(encode(promptResponse, bytes, sizeof(bytes)));
  assert(decode(bytes, sizeof(bytes), decoded));
  assert(decoded.kind == Kind::PromptResponse);
  assert(decoded.result == Result::Accepted);
  promptResponse.decisionSequence = 0;
  assert(!decode(bytes, FRAME_SIZE - 1, decoded));
  assert(!encode(promptResponse, bytes, sizeof(bytes)));

  Frame invalidEnum = configuration;
  invalidEnum.kind = static_cast<Kind>(99);
  assert(!encode(invalidEnum, bytes, sizeof(bytes)));
  invalidEnum = configuration;
  invalidEnum.transition = static_cast<Transition>(99);
  assert(!encode(invalidEnum, bytes, sizeof(bytes)));

  Frame malformedDecision = input;
  malformedDecision.transition = Transition::None;
  assert(!encode(malformedDecision, bytes, sizeof(bytes)));
  malformedDecision = input;
  malformedDecision.origin = Origin::Manual;
  assert(!encode(malformedDecision, bytes, sizeof(bytes)));

  Frame confirmation = input;
  confirmation.kind = Kind::Confirmation;
  confirmation.result = Result::Accepted;
  assert(encode(confirmation, bytes, sizeof(bytes)));
  bytes[2] = static_cast<uint8_t>(Transition::None);
  assert(!decode(bytes, sizeof(bytes), decoded));
  bytes[2] = static_cast<uint8_t>(Transition::Pause);
  bytes[3] = static_cast<uint8_t>(Origin::Manual);
  assert(!decode(bytes, sizeof(bytes), decoded));

  Frame decisionAcknowledgement = input;
  decisionAcknowledgement.kind = Kind::Acknowledgement;
  decisionAcknowledgement.result = Result::Accepted;
  decisionAcknowledgement.acknowledgedKind =
      static_cast<uint8_t>(Kind::Decision);
  assert(encode(decisionAcknowledgement, bytes, sizeof(bytes)));
  assert(decode(bytes, sizeof(bytes), decoded));
  assert(decoded.acknowledgedKind ==
         static_cast<uint8_t>(Kind::Decision));

  Frame promptAcknowledgement = decisionAcknowledgement;
  promptAcknowledgement.transition = Transition::Start;
  promptAcknowledgement.acknowledgedKind =
      static_cast<uint8_t>(Kind::PromptResponse);
  assert(encode(promptAcknowledgement, bytes, sizeof(bytes)));
  assert(decode(bytes, sizeof(bytes), decoded));
  promptAcknowledgement.transition = Transition::Pause;
  assert(!encode(promptAcknowledgement, bytes, sizeof(bytes)));
  decisionAcknowledgement.acknowledgedKind = 0;
  assert(!encode(decisionAcknowledgement, bytes, sizeof(bytes)));

  Frame badConfiguration = configuration;
  badConfiguration.watermarkOrConfigGeneration = 0;
  assert(!encode(badConfiguration, bytes, sizeof(bytes)));

  Frame cancellation = input;
  cancellation.kind = Kind::Cancellation;
  cancellation.result = Result::Stale;
  assert(encode(cancellation, bytes, sizeof(bytes)));
  assert(decode(bytes, sizeof(bytes), decoded));
  cancellation.result = Result::Accepted;
  assert(!encode(cancellation, bytes, sizeof(bytes)));

  cancellation.result = Result::Stale;
  cancellation.sourceHealthMask = 0x0010;
  assert(!encode(cancellation, bytes, sizeof(bytes)));
  cancellation.sourceHealthMask = 0x000F;
  assert(encode(cancellation, bytes, sizeof(bytes)));
  bytes[51] = 1;
  assert(!decode(bytes, sizeof(bytes), decoded));

  static_assert(FALLBACK_PREFIX_SIZE == 4);
  static_assert(FALLBACK_PREFIX[0] == 'R' && FALLBACK_PREFIX[3] == 'T');
  static_assert(serialNumberNewer(2, 1));
  static_assert(serialNumberNewer(1, UINT32_MAX));
  static_assert(!serialNumberNewer(1, 1));
  static_assert(!serialNumberNewer(UINT32_MAX, 1));
  static_assert(!serialNumberNewer(0x80000001U, 1));

  constexpr auto initialAccept = resolvePromptResponse(
      false, false, Result::Accepted);
  static_assert(initialAccept.accepted);
  static_assert(initialAccept.acknowledgement == Result::Accepted);
  static_assert(!initialAccept.shouldSnooze);
  constexpr auto notNowWins = resolvePromptResponse(
      true, false, Result::Accepted);
  static_assert(!notNowWins.accepted);
  static_assert(notNowWins.acknowledgement == Result::Rejected);
  static_assert(notNowWins.shouldSnooze);
  constexpr auto laterNotNow = resolvePromptResponse(
      true, true, Result::Rejected);
  static_assert(!laterNotNow.accepted);
  static_assert(laterNotNow.acknowledgement == Result::Accepted);
  static_assert(laterNotNow.shouldSnooze);

  Frame response = input;
  response.kind = Kind::Acknowledgement;
  response.result = Result::Accepted;
  response.acknowledgedKind = static_cast<uint8_t>(Kind::Decision);
  assert(matchesOutstandingResponse(true, input, response));
  response.sessionID[15] ^= 0x01;
  assert(!matchesOutstandingResponse(true, input, response));
  response.sessionID = input.sessionID;
  assert(!matchesOutstandingResponse(false, input, response));

  assert(!isDuplicateOrOutOfOrderInbound(false, response, response));
  assert(isDuplicateOrOutOfOrderInbound(true, response, response));
  Frame olderResponse = response;
  olderResponse.decisionSequence = response.decisionSequence - 1;
  assert(isDuplicateOrOutOfOrderInbound(true, response, olderResponse));
  Frame newerResponse = response;
  newerResponse.decisionSequence = response.decisionSequence + 1;
  assert(!isDuplicateOrOutOfOrderInbound(true, response, newerResponse));
  Frame promptRetry = response;
  promptRetry.kind = Kind::PromptResponse;
  promptRetry.transition = Transition::Start;
  promptRetry.acknowledgedKind = 0;
  assert(!isDuplicateOrOutOfOrderInbound(true, promptRetry, promptRetry));
  assert(outstandingDecisionWatermark(false, input) == 0);
  assert(outstandingDecisionWatermark(true, input) ==
         input.decisionSequence);
  return 0;
}
