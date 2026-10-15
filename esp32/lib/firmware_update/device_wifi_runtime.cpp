#include "device_wifi_runtime.hpp"
#include <cstring>
#include <esp_wifi_default.h>
#include <esp_netif_defaults.h>
#include <esp_timer.h>

namespace firmware_update {
namespace {
void eraseConfig(wifi_config_t &config) {
  volatile unsigned char *bytes = reinterpret_cast<volatile unsigned char *>(&config);
  for (size_t i = 0; i < sizeof(config); ++i) bytes[i] = 0;
}
uint32_t interfaceAddress(esp_netif_t *netif) {
  esp_netif_ip_info_t info{};
  return netif != nullptr && esp_netif_get_ip_info(netif, &info) == ESP_OK ? info.ip.addr : 0;
}
} // namespace

esp_err_t DeviceWiFiRuntime::initialize() {
  if (initializationFailed_) return ESP_ERR_INVALID_STATE;
  if (initialized_) return ESP_OK;
  // Partial initialization is terminal for this boot. Do not repeatedly
  // allocate/deallocate, or take ownership of a different Wi-Fi consumer.
  initializationFailed_ = true;
  wifi_mode_t existing;
  if (esp_wifi_get_mode(&existing) != ESP_ERR_WIFI_NOT_INIT) return ESP_ERR_INVALID_STATE;
  esp_err_t error = esp_netif_init();
  if (error != ESP_OK) return error;
  error = esp_event_loop_create_default();
  if (error != ESP_OK && error != ESP_ERR_INVALID_STATE) return error;
  wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
  // Match the pinned Arduino dynamic-buffer configuration; no larger buffers
  // or new PSRAM/cache assumptions are introduced by native ownership.
  config.static_tx_buf_num = 0;
  config.dynamic_tx_buf_num = 32;
  config.tx_buf_type = 1;
  config.cache_tx_buf_num = 4;
  config.static_rx_buf_num = 4;
  config.dynamic_rx_buf_num = 32;
  error = esp_wifi_init(&config);
  if (error != ESP_OK) return error;
  initialized_ = true;
  error = esp_wifi_set_storage(WIFI_STORAGE_RAM);
  if (error != ESP_OK) return error;
  ramStorageReady_ = true;
  // The convenience create_default helpers abort on allocation/attach errors.
  // Use their checked constituents so pressure remains a typed failure.
  esp_netif_config_t apConfig = ESP_NETIF_DEFAULT_WIFI_AP();
  esp_netif_t *ap = esp_netif_new(&apConfig);
  if (ap == nullptr) return ESP_ERR_NO_MEM;
  error = esp_netif_attach_wifi_ap(ap);
  if (error != ESP_OK) return error;
  error = esp_wifi_set_default_wifi_ap_handlers();
  if (error != ESP_OK) return error;
  apNetif_.store(ap, std::memory_order_release);
  esp_netif_config_t staConfig = ESP_NETIF_DEFAULT_WIFI_STA();
  esp_netif_t *sta = esp_netif_new(&staConfig);
  if (sta == nullptr) return ESP_ERR_NO_MEM;
  error = esp_netif_attach_wifi_station(sta);
  if (error != ESP_OK) return error;
  error = esp_wifi_set_default_wifi_sta_handlers();
  if (error != ESP_OK) return error;
  stationNetif_.store(sta, std::memory_order_release);
  error = esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, event, this, &events_);
  if (error != ESP_OK) return error;
  error = esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID, event, this, &ipEvents_);
  if (error != ESP_OK) return error;
  error = clearCredentials();
  if (error != ESP_OK) return error;
  initializationFailed_ = false;
  return ESP_OK;
}

esp_err_t DeviceWiFiRuntime::clearCredentials() {
  wifi_config_t empty{};
  esp_err_t error = esp_wifi_set_mode(WIFI_MODE_APSTA);
  if (error == ESP_OK) error = esp_wifi_set_config(WIFI_IF_STA, &empty);
  empty.ap.channel = 1;
  empty.ap.max_connection = 4;
  empty.ap.beacon_interval = 100;
  if (error == ESP_OK) error = esp_wifi_set_config(WIFI_IF_AP, &empty);
  if (error == ESP_OK) error = esp_wifi_set_mode(WIFI_MODE_NULL);
  return error;
}

device_transfer::NetworkStartResult DeviceWiFiRuntime::start(
    bool station, const char *ssid, const char *password, MemoryReader memory) {
  using device_transfer::NetworkStartStep;
  device_transfer::NetworkStartResult result;
  auto fail = [&](NetworkStartStep step, esp_err_t error,
                  const device_transfer::NetworkTransitionMemory &transition) {
    result.failedStep = step;
    result.espError = error;
    result.before = transition.before;
    result.after = transition.after;
    return result;
  };
  result.mode.before = memory();
  if (!initialized_ && !device_transfer::wifiStartupMemoryAboveObservedFailure(result.mode.before)) {
    result.mode.after = result.mode.before;
    return fail(NetworkStartStep::Memory, ESP_ERR_NO_MEM, result.mode);
  }
  if (radioStarted_.load(std::memory_order_acquire)) {
    result.mode.after = memory();
    return fail(NetworkStartStep::Mode, ESP_ERR_INVALID_STATE, result.mode);
  }
  result.mode.attempted = true;
  esp_err_t error = initialize();
  if (error == ESP_OK) error = esp_wifi_set_mode(station ? WIFI_MODE_STA : WIFI_MODE_AP);
  result.mode.after = memory();
  if (error != ESP_OK) return fail(NetworkStartStep::Mode, error, result.mode);
  result.ramStorage.attempted = true;
  result.ramStorage.before = memory();
  error = esp_wifi_set_storage(WIFI_STORAGE_RAM);
  result.ramStorage.after = memory();
  if (error != ESP_OK) return fail(NetworkStartStep::RamStorage, error, result.ramStorage);
  result.accessPoint.attempted = true;
  result.accessPoint.before = memory();
  wifi_config_t config{};
  const size_t ssidLength = std::strlen(ssid), passwordLength = std::strlen(password);
  if (ssidLength == 0 || ssidLength > 32 || passwordLength > 64 ||
      (!station && (passwordLength < 8 || passwordLength > 63))) {
    error = ESP_ERR_INVALID_ARG;
  } else if (station) {
    std::memcpy(config.sta.ssid, ssid, ssidLength);
    std::memcpy(config.sta.password, password, passwordLength);
    config.sta.scan_method = WIFI_FAST_SCAN;
    config.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;
    config.sta.threshold.rssi = -127;
    config.sta.threshold.authmode = passwordLength == 0 ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK;
    config.sta.pmf_cfg.capable = true;
    error = esp_wifi_set_config(WIFI_IF_STA, &config);
  } else {
    std::memcpy(config.ap.ssid, ssid, ssidLength);
    std::memcpy(config.ap.password, password, passwordLength);
    config.ap.ssid_len = ssidLength;
    config.ap.channel = 1;
    config.ap.max_connection = 4;
    config.ap.authmode = WIFI_AUTH_WPA2_PSK;
    config.ap.pairwise_cipher = WIFI_CIPHER_TYPE_CCMP;
    config.ap.beacon_interval = 100;
    error = esp_wifi_set_config(WIFI_IF_AP, &config);
  }
  eraseConfig(config);
  apEventStarted_.store(false, std::memory_order_release);
  disconnectReason_.store(0, std::memory_order_release);
  stationHasIP_.store(false, std::memory_order_release);
  stationRequested_.store(station, std::memory_order_release);
  if (error == ESP_OK) {
    error = esp_wifi_start();
    if (error == ESP_OK) radioStarted_.store(true, std::memory_order_release);
  }
  if (error == ESP_OK && station) error = esp_wifi_connect();
  result.accessPoint.after = memory();
  if (error != ESP_OK) return fail(NetworkStartStep::AccessPoint, error, result.accessPoint);
  result.before = result.accessPoint.before;
  result.after = result.accessPoint.after;
  return result;
}

esp_err_t DeviceWiFiRuntime::stop() {
  stationRequested_.store(false, std::memory_order_release);
  stationHasIP_.store(false, std::memory_order_release);
  if (!initialized_) return ESP_OK;
  const esp_err_t error = esp_wifi_stop();
  if (error != ESP_OK && error != ESP_ERR_WIFI_NOT_STARTED) return error;
  radioStarted_.store(false, std::memory_order_release);
  if (!ramStorageReady_) return ESP_ERR_INVALID_STATE;
  // Keep driver/netifs resident, but no session credentials or active mode.
  // Clearing failure blocks release; a timed-out owner still fails closed.
  return clearCredentials();
}

void DeviceWiFiRuntime::event(void *context, esp_event_base_t base, int32_t id, void *data) {
  auto *runtime = static_cast<DeviceWiFiRuntime *>(context);
  bool observed = true;
  if (base == WIFI_EVENT && id == WIFI_EVENT_AP_START) {
    runtime->apEventStarted_.store(true, std::memory_order_release);
    runtime->apStarts_.fetch_add(1, std::memory_order_relaxed);
  } else if (base == WIFI_EVENT && id == WIFI_EVENT_AP_STOP) {
    runtime->apEventStarted_.store(false, std::memory_order_release);
    runtime->apStops_.fetch_add(1, std::memory_order_relaxed);
  } else if (base == WIFI_EVENT && id == WIFI_EVENT_AP_STACONNECTED) {
    runtime->clientJoins_.fetch_add(1, std::memory_order_relaxed);
  } else if (base == WIFI_EVENT && id == WIFI_EVENT_AP_STADISCONNECTED) {
    runtime->clientLeaves_.fetch_add(1, std::memory_order_relaxed);
  } else if (base == IP_EVENT && id == IP_EVENT_AP_STAIPASSIGNED) {
    runtime->dhcpLeases_.fetch_add(1, std::memory_order_relaxed);
  } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_CONNECTED) {
    // Association is separate from the subsequent IP event.
  } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED && data != nullptr &&
      runtime->stationRequested_.load(std::memory_order_acquire)) {
    runtime->stationHasIP_.store(false, std::memory_order_release);
    runtime->disconnectReason_.store(static_cast<wifi_event_sta_disconnected_t *>(data)->reason, std::memory_order_release);
  } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP && data != nullptr &&
             runtime->stationRequested_.load(std::memory_order_acquire) &&
             static_cast<ip_event_got_ip_t *>(data)->esp_netif == runtime->stationNetif_.load(std::memory_order_acquire)) {
    runtime->stationHasIP_.store(true, std::memory_order_release);
  } else {
    observed = false;
  }
  if (observed) {
    // No recorder, locks, formatting, MAC/IP/SSID or allocation in callbacks.
    runtime->eventUptimeMs_.store(static_cast<uint32_t>(esp_timer_get_time() / 1000), std::memory_order_relaxed);
    runtime->eventSequence_.fetch_add(1, std::memory_order_release);
  }
}

device_transfer::StationState DeviceWiFiRuntime::stationState() const {
  using device_transfer::StationState;
  if (!stationRequested_.load(std::memory_order_acquire) ||
      !radioStarted_.load(std::memory_order_acquire)) return StationState::Connecting;
  wifi_ap_record_t ap{};
  if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) return StationState::Connected;
  const int reason = disconnectReason_.load(std::memory_order_acquire);
  if (reason == WIFI_REASON_NO_AP_FOUND) return StationState::NoSSID;
  if (reason == WIFI_REASON_AUTH_FAIL || reason == WIFI_REASON_AUTH_EXPIRE ||
      reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT || reason == WIFI_REASON_HANDSHAKE_TIMEOUT)
    return StationState::AuthenticationFailed;
  return StationState::Connecting;
}
uint32_t DeviceWiFiRuntime::stationIPAddress() const {
  return stationHasIP_.load(std::memory_order_acquire) && stationState() == device_transfer::StationState::Connected
      ? interfaceAddress(stationNetif_.load(std::memory_order_acquire)) : 0;
}
uint32_t DeviceWiFiRuntime::accessPointIPAddress() const {
  return radioStarted_.load(std::memory_order_acquire) && !stationRequested_.load(std::memory_order_acquire)
      ? interfaceAddress(apNetif_.load(std::memory_order_acquire)) : 0;
}
uint8_t DeviceWiFiRuntime::accessPointClientCount() const {
  wifi_sta_list_t clients{};
  return accessPointIPAddress() != 0 && esp_wifi_ap_get_sta_list(&clients) == ESP_OK ? clients.num : 0;
}
device_transfer::NetworkReadinessSnapshot DeviceWiFiRuntime::readiness() const {
  device_transfer::NetworkReadinessSnapshot result;
  result.available = initialized_.load(std::memory_order_acquire);
  result.radioStarted = radioStarted_.load(std::memory_order_acquire);
  wifi_mode_t mode = WIFI_MODE_NULL;
  result.station = esp_wifi_get_mode(&mode) == ESP_OK && mode == WIFI_MODE_STA;
  result.apEventStarted = apEventStarted_.load(std::memory_order_acquire);
  result.eventSequence = eventSequence_.load(std::memory_order_acquire);
  result.eventUptimeMs = eventUptimeMs_.load(std::memory_order_relaxed);
  result.apStarts = apStarts_.load(std::memory_order_relaxed);
  result.apStops = apStops_.load(std::memory_order_relaxed);
  result.clientJoins = clientJoins_.load(std::memory_order_relaxed);
  result.clientLeaves = clientLeaves_.load(std::memory_order_relaxed);
  result.dhcpLeases = dhcpLeases_.load(std::memory_order_relaxed);
  result.disconnectReason = disconnectReason_.load(std::memory_order_acquire);
  esp_netif_t *netif = result.station ? stationNetif_.load(std::memory_order_acquire)
                                     : apNetif_.load(std::memory_order_acquire);
  result.netifUp = netif != nullptr && esp_netif_is_netif_up(netif);
  result.hasIP = result.station ? stationIPAddress() != 0 : accessPointIPAddress() != 0;
  if (!result.station && netif != nullptr) {
    esp_netif_dhcp_status_t dhcp{};
    result.dhcpError = esp_netif_dhcps_get_status(netif, &dhcp);
    if (result.dhcpError == ESP_OK) result.dhcpStatus = static_cast<int32_t>(dhcp);
  }
  result.clients = result.station ? 0 : accessPointClientCount();
  return result;
}
} // namespace firmware_update
