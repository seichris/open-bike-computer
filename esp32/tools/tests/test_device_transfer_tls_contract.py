from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
TLS_HEADER = (
    ROOT / "lib/device_transfer/device_transfer_tls.hpp"
).read_text(encoding="utf-8")
TLS_SOURCE = (
    ROOT / "lib/device_transfer/device_transfer_tls.cpp"
).read_text(encoding="utf-8")
HTTP_SOURCE = (
    ROOT / "lib/device_transfer/device_transfer_http.cpp"
).read_text(encoding="utf-8")
HTTP_HEADER = (
    ROOT / "lib/device_transfer/device_transfer_http.hpp"
).read_text(encoding="utf-8")
DEBUG_HTTP_SOURCE = (
    ROOT / "lib/device_debug/device_debug_http.cpp"
).read_text(encoding="utf-8")


class DeviceTransferTLSContractTests(unittest.TestCase):
    def test_tls_handshake_precedes_http_parsing(self):
        worker = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::runWorker()") :
            HTTP_SOURCE.index("void HttpTransferServer::workerTaskThunk")
        ]
        self.assertLess(
            worker.index("client.begin("),
            worker.index("handleClient(client, requestIndex)"),
        )
        begin = TLS_SOURCE[
            TLS_SOURCE.index("bool TransferClient::begin") :
            TLS_SOURCE.index("int TransferClient::available")
        ]
        self.assertLess(
            begin.index("socketOwner_ = accepted"),
            begin.index("accepted = WiFiClient()"),
        )
        self.assertLess(
            begin.index("accepted = WiFiClient()"),
            begin.index("esp_tls_server_session_create"),
        )
        self.assertNotIn("::dup", begin)
        self.assertNotIn("accepted.stop()", begin)
        self.assertIn("WiFiClient socketOwner_;", TLS_HEADER)
        self.assertIn("TransferClient &client", HTTP_HEADER)

    def test_tls_handshake_failures_preserve_safe_error_and_heap_evidence(self):
        begin = TLS_SOURCE[
            TLS_SOURCE.index("bool TransferClient::begin") :
            TLS_SOURCE.index("int TransferClient::available")
        ]
        self.assertIn("esp_tls_get_error_handle", begin)
        self.assertIn("esp_tls_get_and_clear_last_error", begin)
        self.assertLess(
            begin.index("esp_tls_get_and_clear_last_error"),
            begin.index("esp_tls_server_session_delete"),
        )
        self.assertIn("heap_caps_get_free_size(kInternalCaps)", TLS_SOURCE)
        self.assertIn("heap_caps_get_largest_free_block(kInternalCaps)", TLS_SOURCE)
        self.assertIn("heap_caps_get_free_size(MALLOC_CAP_DMA)", TLS_SOURCE)
        self.assertIn("heap_caps_get_largest_free_block(MALLOC_CAP_DMA)", TLS_SOURCE)
        self.assertIn("heap_caps_get_free_size(MALLOC_CAP_SPIRAM)", TLS_SOURCE)
        self.assertIn(
            "heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM)", TLS_SOURCE
        )
        for code in (
            "tls_context_allocation_failed",
            "tls_setup_allocation_failed",
            "tls_setup_failed",
            "tls_handshake_timeout",
            "tls_handshake_allocation_failed",
            "tls_handshake_failed",
        ):
            self.assertIn(code, TLS_SOURCE)
        self.assertIn("ESP_ERR_MBEDTLS_SSL_SETUP_FAILED", begin)
        self.assertLess(
            begin.index("esp_tls_get_and_clear_last_error"),
            begin.index("ESP_ERR_MBEDTLS_SSL_SETUP_FAILED"),
        )
        worker = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::runWorker()") :
            HTTP_SOURCE.index("void HttpTransferServer::workerTaskThunk")
        ]
        self.assertIn("client.handshakeDiagnostics()", worker)
        self.assertIn("setLastError(transferTlsFailureCode(diagnostics), message)", worker)
        for field in (
            "psramBefore=",
            "psramLargestBefore=",
            "psramAfter=",
            "psramLargestAfter=",
        ):
            self.assertIn(field, worker)
        self.assertNotIn("reserveRestored=", worker)
        for forbidden in (
            "certificatePem",
            "privateKeyPem",
            "sessionToken",
            "apPassphrase",
        ):
            diagnostic_block = worker[
                worker.index("const TransferTlsHandshakeDiagnostics") :
                worker.index("vTaskDelay(pdMS_TO_TICKS(2))")
            ]
            self.assertNotIn(forbidden, diagnostic_block)

        status_snapshot = HTTP_SOURCE[
            HTTP_SOURCE.index(
                "HttpTransferStatus HttpTransferServer::status() const"
            ) :
            HTTP_SOURCE.index("bool HttpTransferServer::isRequestAuthorized")
        ]
        self.assertIn("result.errorSequence = errorSequence", status_snapshot)

        ble_source = (
            ROOT / "lib/ble_navigation/ble_navigation.cpp"
        ).read_text(encoding="utf-8")
        transfer_status = ble_source[
            ble_source.index("static std::string genericTransferStatusJson()") :
            ble_source.index("static void notifyMapTransferStatus")
        ]
        self.assertIn('\\"sequence\\":', transfer_status)
        self.assertIn("transferStatus.errorSequence", transfer_status)

    def test_tls_does_not_claim_a_psram_hole_that_cannot_fix_internal_crypto(self):
        self.assertNotIn("TLS_HANDSHAKE_PSRAM_RESERVE_BYTES", TLS_HEADER)
        self.assertNotIn("tlsHandshakePsramReserve_", HTTP_HEADER)
        self.assertNotIn("ensureTlsHandshakeReserve", HTTP_SOURCE)

    def test_leaf_fingerprint_is_sha256_over_certificate_der(self):
        fingerprint = TLS_SOURCE[
            TLS_SOURCE.index("bool certificateFingerprint") :
            TLS_SOURCE.index("bool keyMatchesCertificate")
        ]
        self.assertIn("certificate.raw.p", fingerprint)
        self.assertIn("certificate.raw.len", fingerprint)
        self.assertIn("mbedtls_sha256(", fingerprint)
        self.assertIn("mbedtls_pk_check_pair", TLS_SOURCE)

    def test_identity_selector_is_one_atomic_nvs_value(self):
        self.assertIn('constexpr char kSelectorKey[] = "selector";', TLS_SOURCE)
        self.assertIn("putUShort(kSelectorKey, encodeSelector(0)) == 2", TLS_SOURCE)
        self.assertIn("putUShort(kSelectorKey, encodeSelector(nextSlot)) == 2", TLS_SOURCE)
        self.assertNotIn("kSchemaKey", TLS_SOURCE)
        self.assertNotIn("kActiveSlotKey", TLS_SOURCE)

    def test_identity_corruption_fails_closed(self):
        load = TLS_SOURCE[
            TLS_SOURCE.index("bool TransferTlsIdentityStore::load()") :
            TLS_SOURCE.index("bool TransferTlsIdentityStore::generate")
        ]
        self.assertIn("namespaceContainsIdentityState", load)
        self.assertIn("selector == 0xffff && validSlots[0] && !validSlots[1]", load)
        self.assertIn('lastError_ = "tls_identity_invalid";', load)
        self.assertNotIn("generate(1, generated)", load[load.index("if (schema !="):])

    def test_rotation_is_two_phase_and_fingerprint_bound(self):
        self.assertIn("prepareRotation()", TLS_HEADER)
        self.assertIn("commitRotation(", TLS_HEADER)
        commit = TLS_SOURCE[
            TLS_SOURCE.index("bool TransferTlsIdentityStore::commitRotation") :
            TLS_SOURCE.index("bool TransferTlsIdentityStore::cancelRotation")
        ]
        self.assertIn("expectedCertificateSha256 != pending_.certificateSha256", commit)
        self.assertLess(commit.index("putUShort(kSelectorKey"), commit.index("clearSlot(oldSlot)"))

    def test_tls_close_notify_is_the_response_completion_boundary(self):
        finish = TLS_SOURCE[
            TLS_SOURCE.index("bool TransferClient::finishResponse") :
            TLS_SOURCE.index("void TransferClient::stop")
        ]
        self.assertIn("mbedtls_ssl_close_notify", finish)
        self.assertIn("esp_tls_conn_read", finish)
        self.assertIn("client.finishResponse(timeoutMs)", HTTP_SOURCE)

    def test_remote_debug_reuses_only_bounded_authenticated_tls_connections(self):
        worker = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::runWorker()") :
            HTTP_SOURCE.index("void HttpTransferServer::workerTaskThunk")
        ]
        self.assertIn("HTTP_MAX_REQUESTS_PER_TLS_CONNECTION", worker)
        self.assertIn("client.resetHttpResponsePolicy(", worker)
        self.assertIn("activeClient_ = &client;", worker)
        self.assertIn("activeClient_ = nullptr;", worker)
        self.assertIn("client.httpResponseKeepAlive()", HTTP_SOURCE)
        self.assertIn("client.httpResponseConnectionValue()", HTTP_SOURCE)
        self.assertIn("client.requestHttpResponseKeepAlive();", DEBUG_HTTP_SOURCE)
        self.assertIn("server_->isRequestAuthorized(request)", DEBUG_HTTP_SOURCE)
        exit_policy = DEBUG_HTTP_SOURCE[
            DEBUG_HTTP_SOURCE.index("// Every request remains independently") :
            DEBUG_HTTP_SOURCE.index(
                'if (request.method == "GET" && request.path == "/device-debug/v1/info")'
            )
        ]
        self.assertIn('/device-debug/v1/session/exit', exit_policy)

    def test_idle_reused_connection_cannot_starve_a_new_pinned_client(self):
        handle_client = HTTP_SOURCE[
            HTTP_SOURCE.index("bool HttpTransferServer::handleClient") :
            HTTP_SOURCE.index("HttpRequestHandler *\nHttpTransferServer::handlerForPath")
        ]
        self.assertIn("httpRequestLineTimeoutMs(requestIndex)", handle_client)
        self.assertIn(
            "requestLineResult == ReadLineResult::Disconnected &&",
            handle_client,
        )
        self.assertIn("headerBudget.totalBytes == 0", handle_client)
        self.assertLess(
            handle_client.index("headerBudget.totalBytes == 0"),
            handle_client.index('sendError(client, 400, "bad_request"'),
        )

    def test_ble_and_mode_revocation_interrupt_the_active_tls_socket(self):
        clear_ble = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::clearAuthenticatedBleSession") :
            HTTP_SOURCE.index("bool HttpTransferServer::prepareTlsIdentityRotation")
        ]
        disable = HTTP_SOURCE[
            HTTP_SOURCE.index("bool HttpTransferServer::setEnabled(bool enabled, std::string mode)") :
            HTTP_SOURCE.index("void HttpTransferServer::setLastError")
        ]
        self.assertIn("interruptActiveClientLocked();", clear_ble)
        self.assertIn("interruptActiveClientLocked();", disable)
        self.assertIn("::shutdown(socket_, SHUT_RDWR);", TLS_SOURCE)
        self.assertIn("activeClient_->interruptSocket();", HTTP_SOURCE)

    def test_all_hotspots_are_protected_and_status_advertises_https(self):
        self.assertIn("apPassphrase_ = generateSessionToken().substr(0, 24);", HTTP_SOURCE)
        self.assertIn(
            "WiFi.softAP(apSsid.c_str(), apPassphrase.c_str())", HTTP_SOURCE
        )
        self.assertNotIn("WiFi.softAP(apSsid.c_str());", HTTP_SOURCE)
        self.assertIn('std::string("https://")', HTTP_SOURCE)


if __name__ == "__main__":
    unittest.main()
