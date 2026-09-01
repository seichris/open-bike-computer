#include "device_debug_http.hpp"

#include "device_debug_page.hpp"
#include "../display_power/display_power.hpp"
#include "../firmware_metadata/firmware_metadata.hpp"
#include "../renderer_diagnostics/renderer_diagnostics.hpp"
#include "../ui_scheduler/ui_scheduler.hpp"

#include <ArduinoJson.h>
#include <esp_heap_caps.h>
#include <esp_system.h>

#include <array>
#include <cstdio>
#include <cstring>
#include <sstream>

namespace device_debug {

#if DEVICE_REMOTE_DEBUG

namespace {

constexpr uint32_t kFrameResponseMinimumIntervalMs = 80;
constexpr uint32_t kMetricsResponseMinimumIntervalMs = 250;
constexpr uint32_t kRendererWindowMinimumIntervalMs = 1000;

const char *displayStateName(display_power::State state) {
  switch (state) {
  case display_power::State::Active:
    return "active";
  case display_power::State::Dimmed:
    return "dimmed";
  case display_power::State::Off:
    return "off";
  }
  return "unknown";
}

const char *targetName() {
#ifdef WAVESHARE_AMOLED_206
  return "WAVESHARE_AMOLED_206";
#else
  return "WAVESHARE_AMOLED_175";
#endif
}

TargetGeometry targetGeometry() {
#ifdef WAVESHARE_AMOLED_206
  return kWaveshareAmoled206Geometry;
#else
  return kWaveshareAmoled175Geometry;
#endif
}

bool parsePointerPhase(const char *value, PointerPhase &phase) {
  if (value == nullptr)
    return false;
  const std::string text(value);
  if (text == "down")
    phase = PointerPhase::Down;
  else if (text == "move")
    phase = PointerPhase::Move;
  else if (text == "up")
    phase = PointerPhase::Up;
  else if (text == "cancel")
    phase = PointerPhase::Cancel;
  else
    return false;
  return true;
}

const char *pointerErrorCode(PointerQueueResult result) {
  switch (result) {
  case PointerQueueResult::Accepted:
    return "ok";
  case PointerQueueResult::InvalidSchema:
    return "invalid_schema";
  case PointerQueueResult::InvalidPointerId:
    return "invalid_pointer_id";
  case PointerQueueResult::InvalidCoordinate:
    return "invalid_coordinate";
  case PointerQueueResult::DuplicateOrOutOfOrder:
    return "pointer_sequence";
  case PointerQueueResult::InvalidTransition:
    return "pointer_transition";
  case PointerQueueResult::RateLimited:
    return "pointer_rate_limited";
  case PointerQueueResult::QueueFull:
    return "pointer_queue_full";
  }
  return "pointer_rejected";
}

} // namespace

bool DeviceDebugHttp::configure(device_transfer::HttpTransferServer *server) {
#if !DEVICE_REMOTE_DEBUG
  (void)server;
  return false;
#else
  if (server == nullptr)
    return false;
  server_ = server;
  configured_ = server_->registerHandler("/device-debug/", this);
  if (rendererRunQueue_ == nullptr)
    rendererRunQueue_ = xQueueCreate(1, sizeof(RendererRunRequest));
  runtimeReady_ =
      configured_ && rendererRunQueue_ != nullptr && frameStore().prepare() &&
      pointerInput().begin();
  pointerInput().cancelSession();
  return configured_ && runtimeReady_;
#endif
}

FrameStoreStartResult
DeviceDebugHttp::beginSession(bool fullFrameRgb565Available) {
  if (!configured_)
    return FrameStoreStartResult::UnsupportedBuild;
  if (!runtimeReady_ || !pointerInput().begin())
    return FrameStoreStartResult::MutexAllocationFailed;
  const FrameStoreStartResult result =
      frameStore().begin(targetGeometry(), fullFrameRgb565Available);
  if (result != FrameStoreStartResult::Started) {
    pointerInput().cancelSession();
    return result;
  }
  wakeRequested_.store(false, std::memory_order_release);
  bootPressRequested_.clear();
  exitRequested_.store(false, std::memory_order_release);
  exitResponsePending_.store(false, std::memory_order_release);
  lastFrameResponseMs_ = 0;
  lastFrameResponseDurationMs_ = 0;
  maxFrameResponseDurationMs_ = 0;
  lastFrameResponseBytes_ = 0;
  lastMetricsResponseMs_ = 0;
  lastRendererWindowRequestMs_ = 0;
  xQueueReset(rendererRunQueue_);
  return result;
}

void DeviceDebugHttp::cancelSession() {
  pointerInput().cancelSession();
  wakeRequested_.store(false, std::memory_order_release);
  bootPressRequested_.clear();
  exitRequested_.store(false, std::memory_order_release);
  exitResponsePending_.store(false, std::memory_order_release);
  if (rendererRunQueue_ != nullptr)
    xQueueReset(rendererRunQueue_);
}

void DeviceDebugHttp::finishSessionTeardown() { frameStore().end(); }

bool DeviceDebugHttp::requireMode(device_transfer::TransferClient &client) {
  const device_transfer::HttpTransferStatus status = server_->status();
  if (!status.enabled || status.mode != "debug") {
    device_transfer::sendHttpError(client, 409, "debug_session_inactive",
                                   "remote debug transfer mode is not active");
    return false;
  }
  return true;
}

bool DeviceDebugHttp::authorize(const device_transfer::HttpRequest &request,
                                device_transfer::TransferClient &client) {
  if (server_->isRequestAuthorized(request))
    return true;
  device_transfer::sendHttpError(client, 401, "unauthorized",
                                 "valid transfer token required");
  return false;
}

bool DeviceDebugHttp::handleRequest(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
#if !DEVICE_REMOTE_DEBUG
  (void)request;
  (void)client;
  return false;
#else
  if (!requireMode(client))
    return true;
  if (request.method == "GET" && request.path == "/device-debug/") {
    static constexpr device_transfer::HttpResponseHeader kHeaders[] = {
        {"Cache-Control", "no-store"},
        {"Referrer-Policy", "no-referrer"},
        {"X-Content-Type-Options", "nosniff"},
        {"Content-Security-Policy",
         "default-src 'none'; connect-src 'self'; img-src 'self' blob: data:; "
         "style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
         "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"},
    };
    if (!device_transfer::sendHttpHead(
            client, 200, sizeof(kBrowserPage) - 1,
            "text/html; charset=utf-8", kHeaders,
            sizeof(kHeaders) / sizeof(kHeaders[0])))
      return true;
    device_transfer::writeHttpBytes(
        client, reinterpret_cast<const uint8_t *>(kBrowserPage),
        sizeof(kBrowserPage) - 1);
    return true;
  }
  if (!authorize(request, client))
    return true;
  // Every request remains independently token- and generation-authenticated.
  // Reusing the pinned TLS channel only removes handshake churn. Session exit
  // deliberately retains Connection: close as its durable teardown boundary.
  if (!request.connectionClose &&
      !(request.method == "POST" &&
        request.path == "/device-debug/v1/session/exit")) {
    client.requestHttpResponseKeepAlive();
  }
  if (request.method == "GET" && request.path == "/device-debug/v1/info")
    return handleInfo(client);
  if (request.method == "GET" &&
      request.path == "/device-debug/v1/metrics")
    return handleRendererMetrics(client);
  if (request.method == "POST" &&
      request.path == "/device-debug/v1/metrics/window")
    return handleRendererWindow(request, client);
  if (request.method == "GET" &&
      request.path.compare(0, sizeof(kFrameRoutePrefix) - 1,
                           kFrameRoutePrefix) == 0)
    return handleFrame(request, client);
  if (request.method == "POST" &&
      request.path == "/device-debug/v1/pointer")
    return handlePointer(request, client);
  if (request.method == "POST" &&
      request.path == "/device-debug/v1/display/wake")
    return handleWake(client);
  if (request.method == "POST" &&
      request.path == "/device-debug/v1/button/boot")
    return handleBootPress(request, client);
  if (request.method == "POST" &&
      request.path == "/device-debug/v1/session/exit")
    return handleExit(client);
  return false;
#endif
}

bool DeviceDebugHttp::allowShortUnauthenticatedResponseCompletion(
    const device_transfer::HttpRequest &request) const {
#if !DEVICE_REMOTE_DEBUG
  (void)request;
  return false;
#else
  return request.method == "GET" && request.path == "/device-debug/";
#endif
}

bool DeviceDebugHttp::handleInfo(device_transfer::TransferClient &client) {
  const uint32_t nowMs = millis();
  const TargetGeometry geometry = frameStore().geometry();
  const FrameStoreCounters frames = frameStore().counters();
  const FrameStoreMemory memory = frameStore().memory();
  const PointerCounters pointers = pointerInput().counters();
  const device_transfer::HttpTransferStatus transferStatus = server_->status();
  const uint32_t currentFreePsram =
      heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
  const uint32_t currentLargestPsram =
      heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
  updateRendererDebugOverhead();
  char deviceId[17] = {};
  std::snprintf(deviceId, sizeof(deviceId), "%016llx",
                static_cast<unsigned long long>(ESP.getEfuseMac()));
  std::ostringstream body;
  body << "{\"ok\":true,\"schema\":1,\"session\":{\"active\":true,"
          "\"mode\":\"debug\"},\"target\":\""
       << targetName()
       << "\",\"buildProfile\":\"" << firmware_metadata::buildProfile()
       << "\",\"firmware\":" << firmware_metadata::json()
       << ",\"uptimeMs\":" << nowMs << ",\"deviceId\":\"" << deviceId
       << "\",\"width\":"
       << geometry.width << ",\"height\":" << geometry.height
       << ",\"viewRotation\":"
       << static_cast<unsigned>(geometry.panelToLvglRotation)
       << ",\"pixelFormat\":\"rgb565le\",\"displayState\":\""
       << displayStateName(displayPowerManager.state())
       << "\",\"network\":{\"transport\":\""
       << transferStatus.networkTransport
       << "\",\"hotspotFallback\":"
       << (transferStatus.hotspotFallback ? "true" : "false")
       << "},\"frameSequence\":" << frameStore().currentSequence()
       << ",\"counters\":{\"captured\":" << frames.captured
       << ",\"skippedCadence\":" << frames.skippedCadence
       << ",\"skippedLocked\":" << frames.skippedLocked
       << ",\"rejectedFrame\":" << frames.rejectedFrame
       << ",\"captureErrors\":" << frames.captureErrors
       << ",\"lastCopyUs\":" << frames.lastCopyDurationUs
       << ",\"maxCopyUs\":" << frames.maxCopyDurationUs
       << ",\"lastFrameResponseMs\":" << lastFrameResponseDurationMs_
       << ",\"maxFrameResponseMs\":" << maxFrameResponseDurationMs_
       << ",\"lastFrameResponseBytes\":" << lastFrameResponseBytes_
       << ",\"pointerAccepted\":" << pointers.accepted
       << ",\"pointerRejected\":" << pointers.rejected
       << ",\"pointerTimeouts\":" << pointers.timeouts
       << ",\"physicalOverrides\":" << pointers.physicalOverrides
       << ",\"pointerSessionCancels\":" << pointers.sessionCancels
       << ",\"pointerLastSequence\":" << pointers.lastAcceptedSequence
       << ",\"pointerSequenceInitialized\":"
       << (pointers.hasAcceptedSequence ? "true" : "false")
       << "},\"memory\":{\"freeBefore\":" << memory.freeBefore
       << ",\"largestBefore\":" << memory.largestBefore
       << ",\"freeAfterAllocate\":" << memory.freeAfterAllocate
       << ",\"largestAfterAllocate\":" << memory.largestAfterAllocate
       << ",\"currentFree\":" << currentFreePsram
       << ",\"currentLargest\":" << currentLargestPsram
       << ",\"snapshotBytes\":"
       << static_cast<uint32_t>(geometry.width) * geometry.height * 2U
       << "}}";
  return device_transfer::sendHttpJson(client, 200, body.str());
}

void DeviceDebugHttp::updateRendererDebugOverhead() {
  const TargetGeometry geometry = frameStore().geometry();
  const FrameStoreCounters frames = frameStore().counters();
  const FrameStoreMemory memory = frameStore().memory();
  renderer_diagnostics::RemoteDebugOverhead overhead;
  overhead.active = frameStore().active();
  overhead.snapshotBytes =
      static_cast<uint32_t>(geometry.width) * geometry.height * 2U;
  overhead.captured = frames.captured;
  overhead.skippedCadence = frames.skippedCadence;
  overhead.skippedLocked = frames.skippedLocked;
  overhead.captureErrors = frames.captureErrors;
  overhead.lastCopyUs = frames.lastCopyDurationUs;
  overhead.maximumCopyUs = frames.maxCopyDurationUs;
  overhead.lastHttpResponseMs = lastFrameResponseDurationMs_;
  overhead.maximumHttpResponseMs = maxFrameResponseDurationMs_;
  overhead.freeBefore = memory.freeBefore;
  overhead.largestBefore = memory.largestBefore;
  overhead.freeAfterAllocate = memory.freeAfterAllocate;
  overhead.largestAfterAllocate = memory.largestAfterAllocate;
  renderer_diagnostics::noteRemoteDebug(overhead);
}

bool DeviceDebugHttp::handleRendererMetrics(device_transfer::TransferClient &client) {
  const uint32_t nowMs = millis();
  if (lastMetricsResponseMs_ != 0 &&
      !intervalElapsed(nowMs, lastMetricsResponseMs_,
                       kMetricsResponseMinimumIntervalMs)) {
    return device_transfer::sendHttpError(
        client, 429, "metrics_rate_limited",
        "renderer metrics requests are too frequent");
  }
  updateRendererDebugOverhead();
  const std::string body =
      renderer_diagnostics::toJson(renderer_diagnostics::snapshot(nowMs));
  if (body.empty())
    return device_transfer::sendHttpError(
        client, 503, "metrics_memory",
        "renderer metrics could not be serialized safely");
  const bool sent = device_transfer::sendHttpJson(client, 200, body);
  if (sent)
    lastMetricsResponseMs_ = nowMs;
  return sent;
}

bool DeviceDebugHttp::handleRendererWindow(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  const uint32_t nowMs = millis();
  if (lastRendererWindowRequestMs_ != 0 &&
      !intervalElapsed(nowMs, lastRendererWindowRequestMs_,
                       kRendererWindowMinimumIntervalMs)) {
    return device_transfer::sendHttpError(
        client, 429, "renderer_window_rate_limited",
        "renderer window requests are too frequent");
  }
  if (!request.hasContentLength)
    return device_transfer::sendHttpError(
        client, 400, "content_length_required",
        "renderer window body needs Content-Length");
  if (request.contentType != "application/json")
    return device_transfer::sendHttpError(
        client, 415, "content_type",
        "renderer window body must be application/json");
  if (request.contentLength == 0 ||
      request.contentLength > kRendererWindowBodyMaximumBytes)
    return device_transfer::sendHttpError(
        client, 413, "renderer_window_body_size",
        "renderer window body exceeds device limits");
  std::string body;
  if (!device_transfer::readHttpBody(client, request.contentLength,
                                     kRendererWindowBodyMaximumBytes, body))
    return device_transfer::sendHttpError(
        client, 408, "renderer_window_body_timeout",
        "renderer window body was not received");
  if (!server_->isRequestAuthorized(request)) {
    client.requestHttpResponseClose();
    return device_transfer::sendHttpError(client, 401, "session_revoked",
                                          "debug session was revoked");
  }

  JsonDocument document;
  if (deserializeJson(document, body))
    return device_transfer::sendHttpError(
        client, 400, "invalid_json",
        "renderer window body is invalid JSON");
  const JsonObjectConst object = document.as<JsonObjectConst>();
  const JsonObjectConst mapFixture = object["mapFixture"].as<JsonObjectConst>();
  const JsonObjectConst routeFixture =
      object["routeFixture"].as<JsonObjectConst>();
  if (object.size() != 7 || !object["schema"].is<uint8_t>() ||
      object["schema"].as<uint8_t>() != 1 ||
      !object["profile"].is<const char *>() ||
      !object["runId"].is<const char *>() ||
      !object["repeat"].is<uint16_t>() ||
      object["repeat"].as<uint16_t>() == 0 || mapFixture.size() != 2 ||
      routeFixture.size() != 2 || !mapFixture["id"].is<const char *>() ||
      !mapFixture["sha256"].is<const char *>() ||
      !routeFixture["id"].is<const char *>() ||
      !routeFixture["sha256"].is<const char *>() ||
      !object["routeMode"].is<const char *>()) {
    return device_transfer::sendHttpError(
        client, 400, "renderer_window_schema",
        "renderer window fields are invalid");
  }

  const char *profileName = object["profile"].as<const char *>();
  const char *runId = object["runId"].as<const char *>();
  const char *mapId = mapFixture["id"].as<const char *>();
  const char *mapHash = mapFixture["sha256"].as<const char *>();
  const char *routeId = routeFixture["id"].as<const char *>();
  const char *routeHash = routeFixture["sha256"].as<const char *>();
  const char *routeMode = object["routeMode"].as<const char *>();
  renderer_tuning::Profile profile;
  if (!renderer_tuning::parse(profileName, profile) ||
      !validRendererIdentityText(
          runId, renderer_diagnostics::kIdentityTextBytes - 1U) ||
      !validRendererIdentityText(
          mapId, renderer_diagnostics::kIdentityTextBytes - 1U) ||
      !validLowercaseSha256(mapHash) ||
      !validRendererIdentityText(
          routeId, renderer_diagnostics::kIdentityTextBytes - 1U) ||
      !validLowercaseSha256(routeHash) ||
      !validRendererRouteMode(routeMode)) {
    return device_transfer::sendHttpError(
        client, 400, "renderer_window_identity",
        "renderer profile or fixture identity is invalid");
  }

  RendererRunRequest pending;
  uint32_t requestId =
      nextRendererRequestId_.fetch_add(1, std::memory_order_acq_rel) + 1U;
  if (requestId == 0)
    requestId =
        nextRendererRequestId_.fetch_add(1, std::memory_order_acq_rel) + 1U;
  pending.requestId = requestId;
  pending.profile = profile;
  const bool copied = pending.identity.runId.assign(runId) &&
                      pending.identity.mapFixtureId.assign(mapId) &&
                      pending.identity.mapFixtureSha256.assign(mapHash) &&
                      pending.identity.routeFixtureId.assign(routeId) &&
                      pending.identity.routeFixtureSha256.assign(routeHash) &&
                      pending.identity.routeMode.assign(routeMode);
  pending.identity.repeat = object["repeat"].as<uint16_t>();
  if (!copied || rendererRunQueue_ == nullptr ||
      xQueueOverwrite(rendererRunQueue_, &pending) != pdPASS) {
    return device_transfer::sendHttpError(
        client, 503, "renderer_window_queue",
        "renderer window request could not be queued");
  }
  lastRendererWindowRequestMs_ = nowMs;
  ui_scheduler::notify(ui_scheduler::WakeReason::RemoteDebug);
  std::ostringstream response;
  response << "{\"ok\":true,\"requestId\":" << requestId << "}";
  return device_transfer::sendHttpJson(client, 202, response.str());
}

bool DeviceDebugHttp::handleFrame(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  FrameRequestQuery query;
  if (!parseFrameRequestPath(request.path, query))
    return device_transfer::sendHttpError(
        client, 400, "invalid_frame_query",
        "after and capturedAtOrAfter must be uint32 values");
  const uint32_t nowMs = millis();
  if (lastFrameResponseMs_ != 0 &&
      !intervalElapsed(nowMs, lastFrameResponseMs_,
                       kFrameResponseMinimumIntervalMs))
    return device_transfer::sendHttpError(client, 429, "frame_rate_limited",
                                          "frame requests are too frequent");
  if (frameStore().currentSequence() == query.afterSequence) {
    frameStore().requestNextFrame();
    const bool sent = device_transfer::sendHttpHead(client, 204, 0);
    if (sent)
      lastFrameResponseMs_ = nowMs;
    return sent;
  }

  FrameSnapshot snapshot;
  if (!frameStore().acquireSnapshot(query.afterSequence, snapshot)) {
    frameStore().requestNextFrame();
    return device_transfer::sendHttpError(client, 503, "frame_unavailable",
                                          "no complete frame is available yet");
  }
  if (query.hasCapturedAtOrAfter &&
      !timestampAtOrAfter(snapshot.capturedAtMs,
                          query.capturedAtOrAfterMs)) {
    frameStore().releaseSnapshot();
    frameStore().requestNextFrame();
    const bool sent = device_transfer::sendHttpHead(client, 204, 0);
    if (sent)
      lastFrameResponseMs_ = nowMs;
    return sent;
  }
  const uint32_t responseStartedMs = millis();
  const uint32_t checksum = crc32(snapshot.pixels, snapshot.payloadBytes);
  FrameHeader header;
  header.sequence = snapshot.sequence;
  header.capturedAtMs = snapshot.capturedAtMs;
  header.width = snapshot.width;
  header.height = snapshot.height;
  header.strideBytes = snapshot.strideBytes;
  header.payloadBytes = snapshot.payloadBytes;
  header.payloadCrc32 = checksum;
  std::array<uint8_t, kFrameHeaderBytes> encoded{};
  encodeFrameHeader(header, encoded.data(), encoded.size());
  char sequenceHeader[11] = {};
  std::snprintf(sequenceHeader, sizeof(sequenceHeader), "%lu",
                static_cast<unsigned long>(snapshot.sequence));
  const device_transfer::HttpResponseHeader responseHeaders[] = {
      {"Cache-Control", "no-store"},
      {"X-BikeComputer-Frame-Sequence", sequenceHeader},
  };
  bool sent = device_transfer::sendHttpHead(
      client, 200, encoded.size() + snapshot.payloadBytes,
      "application/vnd.bicino.frame+binary", responseHeaders,
      sizeof(responseHeaders) / sizeof(responseHeaders[0]));
  if (sent)
    sent = device_transfer::writeHttpBytes(client, encoded.data(), encoded.size());
  if (sent)
    sent = device_transfer::writeHttpBytes(client, snapshot.pixels,
                                           snapshot.payloadBytes);
  frameStore().releaseSnapshot();
  frameStore().requestNextFrame();
  const uint32_t responseDurationMs = millis() - responseStartedMs;
  lastFrameResponseDurationMs_ = responseDurationMs;
  if (responseDurationMs > maxFrameResponseDurationMs_)
    maxFrameResponseDurationMs_ = responseDurationMs;
  lastFrameResponseBytes_ =
      static_cast<uint32_t>(encoded.size()) + snapshot.payloadBytes;
  if (sent)
    lastFrameResponseMs_ = nowMs;
  return true;
}

bool DeviceDebugHttp::handlePointer(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  if (displayPowerManager.state() == display_power::State::Off)
    return device_transfer::sendHttpError(client, 409, "display_off",
                                          "wake the display before sending input");
  const PointerEnvelopeResult envelope = validatePointerEnvelope(
      request.hasContentLength, request.contentLength, request.contentType);
  if (envelope == PointerEnvelopeResult::MissingContentLength)
    return device_transfer::sendHttpError(client, 400, "content_length_required",
                                          "pointer body needs Content-Length");
  if (envelope == PointerEnvelopeResult::WrongContentType)
    return device_transfer::sendHttpError(client, 415, "content_type",
                                          "pointer body must be application/json");
  if (envelope == PointerEnvelopeResult::InvalidBodyLength)
    return device_transfer::sendHttpError(client, 413, "pointer_body_size",
                                          "pointer body exceeds device limits");
  std::string body;
  if (!device_transfer::readHttpBody(client, request.contentLength,
                                     kPointerBodyMaximumBytes, body))
    return device_transfer::sendHttpError(client, 408, "pointer_body_timeout",
                                          "pointer body was not received");
  if (!server_->isRequestAuthorized(request)) {
    client.requestHttpResponseClose();
    return device_transfer::sendHttpError(client, 401, "session_revoked",
                                          "debug session was revoked");
  }
  if (displayPowerManager.state() == display_power::State::Off)
    return device_transfer::sendHttpError(client, 409, "display_off",
                                          "wake the display before sending input");
  JsonDocument document;
  if (deserializeJson(document, body))
    return device_transfer::sendHttpError(client, 400, "invalid_json",
                                          "pointer body is invalid JSON");
  const JsonObjectConst object = document.as<JsonObjectConst>();
  if (object.size() != 6 || !object["schema"].is<uint8_t>() ||
      !object["eventSequence"].is<uint32_t>() ||
      !object["pointerId"].is<uint8_t>() ||
      !object["phase"].is<const char *>() || !object["x"].is<uint16_t>() ||
      !object["y"].is<uint16_t>())
    return device_transfer::sendHttpError(client, 400, "pointer_schema",
                                          "pointer fields are invalid");
  PointerEvent event;
  event.schema = object["schema"].as<uint8_t>();
  event.eventSequence = object["eventSequence"].as<uint32_t>();
  event.pointerId = object["pointerId"].as<uint8_t>();
  event.point = {object["x"].as<uint16_t>(), object["y"].as<uint16_t>()};
  event.receivedAtMs = millis();
  if (!parsePointerPhase(object["phase"].as<const char *>(), event.phase))
    return device_transfer::sendHttpError(client, 400, "pointer_phase",
                                          "pointer phase is unsupported");
  const PointerQueueResult result = pointerInput().enqueue(event);
  if (result != PointerQueueResult::Accepted) {
    const int status = result == PointerQueueResult::RateLimited
                           ? 429
                           : (result == PointerQueueResult::QueueFull ? 503 : 409);
    return device_transfer::sendHttpError(client, status,
                                          pointerErrorCode(result),
                                          "pointer event was rejected");
  }
  frameStore().requestNextFrame();
  ui_scheduler::notify(ui_scheduler::WakeReason::RemoteDebug);
  return device_transfer::sendHttpJson(client, 202, "{\"ok\":true}");
}

bool DeviceDebugHttp::handleWake(device_transfer::TransferClient &client) {
  wakeRequested_.store(true, std::memory_order_release);
  frameStore().requestNextFrame();
  ui_scheduler::notify(ui_scheduler::WakeReason::RemoteDebug);
  return device_transfer::sendHttpJson(client, 202, "{\"ok\":true}");
}

bool DeviceDebugHttp::handleBootPress(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  if (!server_->isRequestAuthorized(request)) {
    client.requestHttpResponseClose();
    return device_transfer::sendHttpError(client, 401, "session_revoked",
                                          "debug session was revoked");
  }
  if (!bootPressRequested_.request())
    return device_transfer::sendHttpError(
        client, 409, "boot_press_pending",
        "a BOOT short press is already queued");
  frameStore().requestNextFrame();
  ui_scheduler::notify(ui_scheduler::WakeReason::RemoteDebug);
  return device_transfer::sendHttpJson(client, 202, "{\"ok\":true}");
}

bool DeviceDebugHttp::handleExit(device_transfer::TransferClient &client) {
  exitResponsePending_.store(true, std::memory_order_release);
  return device_transfer::sendHttpJson(client, 202, "{\"ok\":true}");
}

void DeviceDebugHttp::responseDidComplete(
    const device_transfer::HttpRequest &request, bool peerClosedCleanly) {
#if !DEVICE_REMOTE_DEBUG
  (void)request;
  (void)peerClosedCleanly;
#else
  if (request.method == "POST" &&
      request.path == "/device-debug/v1/session/exit" &&
      exitResponsePending_.exchange(false, std::memory_order_acq_rel) &&
      peerClosedCleanly) {
    exitRequested_.store(true, std::memory_order_release);
    ui_scheduler::notify(ui_scheduler::WakeReason::RemoteDebug);
  }
#endif
}

bool DeviceDebugHttp::takeWakeRequest() {
  return wakeRequested_.exchange(false, std::memory_order_acq_rel);
}

bool DeviceDebugHttp::bootPressRequested() const {
  return bootPressRequested_.pending();
}

bool DeviceDebugHttp::takeBootPressRequest() {
  return bootPressRequested_.take();
}

bool DeviceDebugHttp::takeAutomaticExitRequest() {
  return exitRequested_.exchange(false, std::memory_order_acq_rel);
}

bool DeviceDebugHttp::takeRendererRunRequest(RendererRunRequest &request) {
  return rendererRunQueue_ != nullptr &&
         xQueueReceive(rendererRunQueue_, &request, 0) == pdTRUE;
}

#else

bool DeviceDebugHttp::configure(device_transfer::HttpTransferServer *server) {
  (void)server;
  return false;
}

FrameStoreStartResult
DeviceDebugHttp::beginSession(bool fullFrameRgb565Available) {
  (void)fullFrameRgb565Available;
  return FrameStoreStartResult::UnsupportedBuild;
}

void DeviceDebugHttp::cancelSession() {}

void DeviceDebugHttp::finishSessionTeardown() {}

bool DeviceDebugHttp::handleRequest(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  (void)request;
  (void)client;
  return false;
}

bool DeviceDebugHttp::allowShortUnauthenticatedResponseCompletion(
    const device_transfer::HttpRequest &request) const {
  (void)request;
  return false;
}

void DeviceDebugHttp::responseDidComplete(
    const device_transfer::HttpRequest &request, bool peerClosedCleanly) {
  (void)request;
  (void)peerClosedCleanly;
}

bool DeviceDebugHttp::takeWakeRequest() { return false; }

bool DeviceDebugHttp::bootPressRequested() const { return false; }

bool DeviceDebugHttp::takeBootPressRequest() { return false; }

bool DeviceDebugHttp::takeAutomaticExitRequest() { return false; }

bool DeviceDebugHttp::takeRendererRunRequest(RendererRunRequest &request) {
  (void)request;
  return false;
}

#endif

} // namespace device_debug
