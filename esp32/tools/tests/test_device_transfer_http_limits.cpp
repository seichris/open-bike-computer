#include "../../lib/device_transfer/device_transfer_http_limits.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>

int main() {
  device_transfer::HttpHeaderBudget budget;
  for (size_t index = 0; index < device_transfer::HTTP_MAX_LINE_BYTES; index++)
    assert(budget.acceptDataByte());
  assert(!budget.acceptDataByte());

  budget = {};
  for (size_t line = 0; line < device_transfer::HTTP_MAX_HEADER_LINES; line++) {
    assert(budget.acceptDataByte());
    assert(budget.finishLine());
  }
  assert(!budget.finishLine());

  budget = {};
  for (size_t index = 0; index < device_transfer::HTTP_MAX_HEADER_BYTES;
       index++)
    assert(budget.acceptDelimiterByte());
  assert(!budget.acceptDelimiterByte());
  assert(device_transfer::HttpHeaderBudget::timedOut(
      device_transfer::HTTP_REQUEST_HEADER_TIMEOUT_MS));

  uint32_t generation = device_transfer::nextHttpTransferGeneration(0);
  assert(generation == 1);
  assert(device_transfer::isHttpTransferGenerationCurrent(true, generation,
                                                           generation));
  generation = device_transfer::nextHttpTransferGeneration(generation);
  assert(!device_transfer::isHttpTransferGenerationCurrent(true, generation,
                                                            generation - 1));
  assert(!device_transfer::isHttpTransferGenerationCurrent(false, generation,
                                                            generation));
  assert(device_transfer::nextHttpTransferGeneration(UINT32_MAX) == 1);
  assert(device_transfer::shouldReuseAuthenticatedHttpConnection(
      true, true, false, true, true));
  assert(!device_transfer::shouldReuseAuthenticatedHttpConnection(
      false, true, false, true, true));
  assert(!device_transfer::shouldReuseAuthenticatedHttpConnection(
      true, false, false, true, true));
  assert(!device_transfer::shouldReuseAuthenticatedHttpConnection(
      true, true, true, true, true));
  assert(!device_transfer::shouldReuseAuthenticatedHttpConnection(
      true, true, false, false, true));
  assert(!device_transfer::shouldReuseAuthenticatedHttpConnection(
      true, true, false, true, false));
  const device_transfer::HttpResponseCompletionToken responseToken{
      generation, "PUT", "/map-transfer/sessions/session-1/install-stream"};
  assert(responseToken.matches(
      generation, "PUT", "/map-transfer/sessions/session-1/install-stream"));
  assert(!responseToken.matches(
      generation + 1, "PUT",
      "/map-transfer/sessions/session-1/install-stream"));
  assert(!responseToken.matches(
      generation, "POST",
      "/map-transfer/sessions/session-1/install-stream"));
  assert(!responseToken.matches(
      generation, "PUT", "/map-transfer/sessions/session-2/install-stream"));
  assert(device_transfer::validHttpHeaderName("Content-Length"));
  assert(device_transfer::validHttpHeaderName("x-bike_token.v2"));
  assert(!device_transfer::validHttpHeaderName("Content Length"));
  assert(!device_transfer::validHttpHeaderName("Content-Length\t"));

  uint64_t parsed = 0;
  assert(device_transfer::parseHttpUint64("18446744073709551615", parsed));
  assert(parsed == UINT64_MAX);
  assert(!device_transfer::parseHttpUint64("18446744073709551616", parsed));
  assert(!device_transfer::parseHttpUint64("12x", parsed));
  assert(!device_transfer::parseHttpUint64("", parsed));

  device_transfer::HttpSecurityHeaders headers;
  assert(!headers.hasContentLength);
  headers.accept("content-length", "10");
  headers.accept("content-length", "10");
  assert(!headers.hasContentLength);
  assert(headers.contentLength == 0);
  headers.accept("content-type", "application/test");
  headers.accept("content-type", "application/test");
  assert(headers.contentType.empty());
  headers.accept("x-bikecomputer-transfer-token", "secret");
  headers.accept("x-bikecomputer-transfer-token", "secret");
  assert(headers.transferToken.empty());
  headers.accept("transfer-encoding", "chunked");
  assert(headers.hasAmbiguousFraming());

  device_transfer::HttpSecurityHeaders persistentHeaders;
  assert(!persistentHeaders.connectionClose);
  persistentHeaders.accept("connection", "Keep-Alive, upgrade");
  assert(!persistentHeaders.connectionClose);
  device_transfer::HttpSecurityHeaders closeHeaders;
  closeHeaders.accept("connection", "keep-alive, CLOSE");
  assert(closeHeaders.connectionClose);
  device_transfer::HttpSecurityHeaders duplicateConnectionHeaders;
  duplicateConnectionHeaders.accept("connection", "keep-alive");
  duplicateConnectionHeaders.accept("connection", "keep-alive");
  assert(duplicateConnectionHeaders.connectionClose);
  assert(device_transfer::HTTP_MAX_REQUESTS_PER_TLS_CONNECTION >= 512);

  std::cout << "device transfer HTTP limit tests passed\n";
  return 0;
}
