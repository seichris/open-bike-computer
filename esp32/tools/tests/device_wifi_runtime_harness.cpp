// Production runtime header/methods are inserted by the host contract test.
// Only IDF APIs are faked. This exercises real lifecycle control, not RF/DHCP.
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstring>
#include "../../lib/device_transfer/device_transfer_network_owner.hpp"
using esp_err_t = int;
using esp_event_base_t = const char *;
using esp_event_handler_instance_t = void *;
using wifi_mode_t = int;
struct esp_netif_t { uint32_t address; };
struct esp_netif_config_t { bool station; };
struct esp_netif_ip_info_t { struct { uint32_t addr; } ip; };
struct wifi_init_config_t { int static_tx_buf_num, dynamic_tx_buf_num, tx_buf_type, cache_tx_buf_num, static_rx_buf_num, dynamic_rx_buf_num; };
struct wifi_sta_config_t {
  uint8_t ssid[32], password[64]; int scan_method, sort_method;
  struct { int rssi, authmode; } threshold;
  struct { bool capable; } pmf_cfg;
};
struct wifi_ap_config_t { uint8_t ssid[32], password[64]; uint8_t ssid_len, channel, max_connection; int authmode, pairwise_cipher; uint16_t beacon_interval; };
union wifi_config_t { wifi_sta_config_t sta; wifi_ap_config_t ap; };
struct wifi_ap_record_t {};
struct wifi_sta_list_t { uint8_t num; };
struct wifi_event_sta_disconnected_t { int reason; };
struct ip_event_got_ip_t { esp_netif_t *esp_netif; };
constexpr int ESP_OK = 0, ESP_FAIL = -1, ESP_ERR_NO_MEM = 1,
  ESP_ERR_INVALID_STATE = 2, ESP_ERR_WIFI_NOT_INIT = 3,
  ESP_ERR_INVALID_ARG = 4, ESP_ERR_WIFI_NOT_STARTED = 5;
constexpr int WIFI_MODE_NULL = 0, WIFI_MODE_STA = 1, WIFI_MODE_AP = 2,
  WIFI_MODE_APSTA = 3, WIFI_IF_STA = 0, WIFI_IF_AP = 1,
  WIFI_STORAGE_RAM = 1, WIFI_AUTH_WPA2_PSK = 3, ESP_EVENT_ANY_ID = -1,
  WIFI_EVENT_STA_DISCONNECTED = 1, WIFI_REASON_NO_AP_FOUND = 2,
  WIFI_REASON_AUTH_FAIL = 3, WIFI_REASON_AUTH_EXPIRE = 4,
  WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT = 5, WIFI_REASON_HANDSHAKE_TIMEOUT = 6;
constexpr int WIFI_FAST_SCAN = 0, WIFI_CONNECT_AP_BY_SIGNAL = 0,
  WIFI_AUTH_OPEN = 0, WIFI_CIPHER_TYPE_CCMP = 4;
constexpr esp_event_base_t WIFI_EVENT = "wifi";
constexpr esp_event_base_t IP_EVENT = "ip";
constexpr int IP_EVENT_STA_GOT_IP = 1;
#define WIFI_INIT_CONFIG_DEFAULT() wifi_init_config_t{}
#define ESP_NETIF_DEFAULT_WIFI_AP() esp_netif_config_t{false}
#define ESP_NETIF_DEFAULT_WIFI_STA() esp_netif_config_t{true}

bool initialized = false, radio = false, ram = false, connected = false;
int mode = WIFI_MODE_NULL, initializes = 0, interfaces = 0, starts = 0;
int initFailure = 0, storageFailure = 0, stopFailure = 0, configFailure = 0;
int connectFailure = 0, startFailure = 0, interfaceFailure = 0;
wifi_config_t stored[2]{};
esp_netif_t nets[2]{{0x0100000a}, {0x0104a8c0}};
device_transfer::NetworkMemorySnapshot headroom{80000, 40000, 70000, 40000};
device_transfer::NetworkMemorySnapshot memory() { return headroom; }
esp_err_t esp_wifi_get_mode(wifi_mode_t *out) { *out = mode; return initialized ? ESP_OK : ESP_ERR_WIFI_NOT_INIT; }
esp_err_t esp_netif_init() { return ESP_OK; }
esp_err_t esp_event_loop_create_default() { return ESP_ERR_INVALID_STATE; }
esp_err_t esp_wifi_init(wifi_init_config_t *config) {
  ++initializes;
  assert(config->static_rx_buf_num == 4 && config->dynamic_rx_buf_num == 32);
  assert(config->static_tx_buf_num == 0 && config->dynamic_tx_buf_num == 32);
  assert(config->tx_buf_type == 1 && config->cache_tx_buf_num == 4);
  if (initFailure) return ESP_ERR_NO_MEM;
  initialized = true;
  return ESP_OK;
}
esp_err_t esp_wifi_set_storage(int storage) { assert(storage == WIFI_STORAGE_RAM); if (storageFailure) return ESP_FAIL; ram = true; return ESP_OK; }
esp_netif_t *esp_netif_new(esp_netif_config_t *config) { ++interfaces; return interfaceFailure ? nullptr : &nets[config->station ? 0 : 1]; }
esp_err_t esp_netif_attach_wifi_ap(esp_netif_t *) { return ESP_OK; }
esp_err_t esp_netif_attach_wifi_station(esp_netif_t *) { return ESP_OK; }
esp_err_t esp_wifi_set_default_wifi_ap_handlers() { return ESP_OK; }
esp_err_t esp_wifi_set_default_wifi_sta_handlers() { return ESP_OK; }
void (*handler)(void *, esp_event_base_t, int32_t, void *) = nullptr;
void *handlerContext = nullptr;
void (*ipHandler)(void *, esp_event_base_t, int32_t, void *) = nullptr;
esp_err_t esp_event_handler_instance_register(esp_event_base_t base, int, decltype(handler) callback, void *context, void **instance) {
  if (base == IP_EVENT) ipHandler = callback;
  else handler = callback;
  handlerContext = context; *instance = context; return ESP_OK;
}
esp_err_t esp_wifi_set_mode(int value) { assert(initialized && !radio); mode = value; return ESP_OK; }
esp_err_t esp_wifi_set_config(int interface, wifi_config_t *config) {
  assert(initialized && ram && !radio);
  if (configFailure) return ESP_FAIL;
  if (interface == WIFI_IF_AP) assert(config->ap.channel == 1 && config->ap.max_connection == 4 && config->ap.beacon_interval == 100);
  stored[interface] = *config;
  return ESP_OK;
}
esp_err_t esp_wifi_start() { assert(initialized && !radio && ram); if (startFailure) return ESP_FAIL; ++starts; radio = true; return ESP_OK; }
esp_err_t esp_wifi_connect() { assert(radio && mode == WIFI_MODE_STA); if (connectFailure) return ESP_FAIL; connected = true; return ESP_OK; }
esp_err_t esp_wifi_stop() { if (stopFailure) return ESP_FAIL; radio = false; connected = false; return ESP_OK; }
esp_err_t esp_wifi_sta_get_ap_info(wifi_ap_record_t *) { return connected ? ESP_OK : ESP_FAIL; }
esp_err_t esp_netif_get_ip_info(esp_netif_t *net, esp_netif_ip_info_t *info) { info->ip.addr = net->address; return ESP_OK; }
esp_err_t esp_wifi_ap_get_sta_list(wifi_sta_list_t *list) { list->num = 2; return ESP_OK; }

// PRODUCTION_HEADER
// PRODUCTION_METHODS

void reset() {
  initialized = radio = ram = connected = false;
  mode = WIFI_MODE_NULL;
  initializes = interfaces = starts = 0;
  initFailure = storageFailure = stopFailure = configFailure = 0;
  connectFailure = startFailure = interfaceFailure = 0;
  stored[0] = {}; stored[1] = {};
  headroom = {80000, 40000, 70000, 40000};
}
void assertQuiescent() {
  assert(!radio && mode == WIFI_MODE_NULL);
  for (int i : {WIFI_IF_STA, WIFI_IF_AP}) {
    for (uint8_t b : stored[i].sta.ssid) assert(b == 0);
    for (uint8_t b : stored[i].sta.password) assert(b == 0);
  }
}
int main() {
  using firmware_update::DeviceWiFiRuntime;
  using device_transfer::NetworkStartStep;
  using device_transfer::StationState;
  reset();
  DeviceWiFiRuntime runtime;
  headroom.internalLargest = headroom.dmaLargest = 28660;
  assert(runtime.start(false, "test-ap", "test-password", memory).failedStep == NetworkStartStep::Memory);
  assert(initializes == 0 && runtime.stop() == ESP_OK);
  headroom = {80000, 40000, 70000, 40000};
  for (int cycle = 0; cycle < 100; ++cycle) {
    assert(runtime.start(false, "test-ap", "test-password", memory).ok());
    assert(radio && mode == WIFI_MODE_AP && stored[1].ap.authmode == WIFI_AUTH_WPA2_PSK && stored[1].ap.pairwise_cipher == WIFI_CIPHER_TYPE_CCMP);
    assert(runtime.accessPointClientCount() == 2 && runtime.accessPointIPAddress() != 0);
    assert(runtime.stop() == ESP_OK); assertQuiescent();
    assert(runtime.accessPointIPAddress() == 0 && runtime.accessPointClientCount() == 0);
    // Later sessions reuse the existing allocation, below first-init floor.
    headroom.internalLargest = headroom.dmaLargest = 28660;
    assert(runtime.start(true, "test-lan", "test-password", memory).ok());
    assert(stored[0].sta.threshold.rssi == -127 && stored[0].sta.threshold.authmode == WIFI_AUTH_WPA2_PSK && stored[0].sta.pmf_cfg.capable);
    assert(runtime.stationState() == StationState::Connected && runtime.stationIPAddress() == 0);
    ip_event_got_ip_t gotIP{&nets[0]};
    ipHandler(handlerContext, IP_EVENT, IP_EVENT_STA_GOT_IP, &gotIP);
    assert(runtime.stationIPAddress() != 0);
    connected = false;
    wifi_event_sta_disconnected_t missing{WIFI_REASON_NO_AP_FOUND};
    handler(handlerContext, WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, &missing);
    assert(runtime.stationState() == StationState::NoSSID);
    missing.reason = WIFI_REASON_AUTH_FAIL;
    handler(handlerContext, WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, &missing);
    assert(runtime.stationState() == StationState::AuthenticationFailed);
    assert(runtime.stop() == ESP_OK); assertQuiescent();
    assert(initializes == 1 && interfaces == 2);
  }
  assert(starts == 200);
  assert(runtime.start(false, "test-ap", "short", memory).failedStep == NetworkStartStep::AccessPoint);
  assert(runtime.stop() == ESP_OK); assertQuiescent();
  assert(runtime.start(false, "test-ap", "test-password", memory).ok());
  stopFailure = 1;
  assert(runtime.stop() == ESP_FAIL && radio);
  assert(!runtime.start(false, "other-ap", "test-password", memory).ok());
  stopFailure = 0;
  assert(runtime.stop() == ESP_OK); assertQuiescent();
  for (int fault = 0; fault < 3; ++fault) {
    reset(); DeviceWiFiRuntime failed;
    initFailure = fault == 0; storageFailure = fault == 1; interfaceFailure = fault == 2;
    assert(!failed.start(false, "test-ap", "test-password", memory).ok());
    initFailure = storageFailure = interfaceFailure = 0;
    assert(!failed.start(false, "test-ap", "test-password", memory).ok());
    assert(initializes == 1); // partial initialization is terminal this boot
    if (fault == 1) { assert(!ram && failed.stop() != ESP_OK); }
  }
  for (int fault = 0; fault < 3; ++fault) {
    reset(); DeviceWiFiRuntime failed;
    assert(failed.start(false, "test-ap", "test-password", memory).ok());
    assert(failed.stop() == ESP_OK);
    configFailure = fault == 0; startFailure = fault == 1; connectFailure = fault == 2;
    assert(!failed.start(true, "test-lan", "test-password", memory).ok());
    configFailure = startFailure = connectFailure = 0;
    assert(failed.stop() == ESP_OK); assertQuiescent();
    assert(initializes == 1);
  }
  reset(); initialized = true; DeviceWiFiRuntime foreign;
  assert(!foreign.start(false, "test-ap", "test-password", memory).ok());
  assert(initializes == 0); // no takeover of another consumer
}
