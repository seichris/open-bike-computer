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
MAIN_SOURCE = (ROOT / "src/main.cpp").read_text(encoding="utf-8")


class DeviceTransferTLSContractTests(unittest.TestCase):
    def test_tls_handshake_precedes_http_parsing(self):
        worker = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::runWorker()") :
            HTTP_SOURCE.index("void HttpTransferServer::workerTaskThunk")
        ]
        self.assertLess(worker.index("client.begin("), worker.index("handleClient(client)"))
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
            "tls_handshake_timeout",
            "tls_handshake_allocation_failed",
            "tls_handshake_failed",
        ):
            self.assertIn(code, TLS_SOURCE)
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
            "reserveRestored=",
        ):
            self.assertIn(field, worker)
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

    def test_tls_psram_hole_is_reserved_before_renderer_and_leased_only_to_tls(self):
        self.assertIn(
            "TLS_HANDSHAKE_PSRAM_RESERVE_BYTES = 64U * 1024U", TLS_HEADER
        )
        self.assertIn("void *tlsHandshakePsramReserve_ = nullptr;", HTTP_HEADER)
        configure = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::configure(uint16_t") :
            HTTP_SOURCE.index("bool HttpTransferServer::registerHandler")
        ]
        self.assertIn("ensureTlsHandshakeReserve()", configure)
        self.assertLess(
            MAIN_SOURCE.index("deviceTransferHttp.configure("),
            MAIN_SOURCE.index("mapView.initMap("),
        )
        self.assertLess(
            MAIN_SOURCE.index("deviceTransferHttp.configure("),
            MAIN_SOURCE.index("initLVGL();"),
        )

        enable = HTTP_SOURCE[
            HTTP_SOURCE.index("bool HttpTransferServer::setEnabled(bool enabled,") :
            HTTP_SOURCE.index("void HttpTransferServer::setLastError")
        ]
        self.assertLess(
            enable.index("waitUntilStopped(2000)"),
            enable.index("!ensureTlsHandshakeReserve()"),
        )

        worker = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::runWorker()") :
            HTTP_SOURCE.index("void HttpTransferServer::workerTaskThunk")
        ]
        self.assertLess(
            worker.index("releaseTlsHandshakeReserve()"),
            worker.index("client.begin("),
        )
        self.assertIn(
            "!ensureTlsHandshakeReserve() || !releaseTlsHandshakeReserve()",
            worker,
        )
        self.assertIn(
            "const bool reserveRestored = ensureTlsHandshakeReserve()", worker
        )
        self.assertIn("stopClientAndRestoreTlsHandshakeReserve(client)", worker)

        handler = HTTP_SOURCE[
            HTTP_SOURCE.index("void HttpTransferServer::handleClient") :
            HTTP_SOURCE.index("HttpRequestHandler *\nHttpTransferServer::handlerForPath")
        ]
        self.assertLess(
            handler.index("stopClientAndRestoreTlsHandshakeReserve(client)"),
            handler.index("handler->responseDidComplete"),
        )

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

    def test_all_hotspots_are_protected_and_status_advertises_https(self):
        self.assertIn("apPassphrase_ = generateSessionToken().substr(0, 24);", HTTP_SOURCE)
        self.assertIn(
            "WiFi.softAP(apSsid.c_str(), apPassphrase.c_str())", HTTP_SOURCE
        )
        self.assertNotIn("WiFi.softAP(apSsid.c_str());", HTTP_SOURCE)
        self.assertIn('std::string("https://")', HTTP_SOURCE)


if __name__ == "__main__":
    unittest.main()
