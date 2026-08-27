#!/usr/bin/env python3

import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[2]
SOURCE = (
    PROJECT_DIR / "lib/map_transfer_http/map_transfer_http.cpp"
).read_text(encoding="utf-8")
HEADER = (
    PROJECT_DIR / "lib/map_transfer_http/map_transfer_http.hpp"
).read_text(encoding="utf-8")
DEVICE_TRANSFER_SOURCE = (
    PROJECT_DIR / "lib/device_transfer/device_transfer_http.cpp"
).read_text(encoding="utf-8")


def method_body(name: str) -> str:
    marker = f"MapTransferHttpServer::{name}"
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 0
    for index in range(opening, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[opening : index + 1]
    raise AssertionError(f"unterminated method body for {name}")


class MapActivationHandoffTests(unittest.TestCase):
    def test_response_completion_reuses_transfer_worker(self):
        body = method_body("beginDeferredActivation")
        self.assertIn("executeActivation(", body)
        self.assertNotIn("startActivationTask(", body)
        self.assertNotIn("xTaskCreate(", body)

    def test_explicit_activation_also_crosses_response_boundary(self):
        body = method_body("handleActivate")
        self.assertIn("deferActivationUntilResponse(", body)
        self.assertNotIn("startActivationTask(", body)
        self.assertNotIn("xTaskCreate(", body)

    def test_dedicated_task_is_reserved_for_boot_recovery(self):
        self.assertEqual(SOURCE.count("startActivationTask("), 3)
        self.assertIn(
            "startActivationTask(",
            method_body("resumePendingArchiveActivation"),
        )
        self.assertIn(
            "startActivationTask(",
            method_body("resumePendingStreamActivation"),
        )

    def test_inline_and_recovery_paths_share_activation_execution(self):
        self.assertIn(
            "executeActivation(", method_body("beginDeferredActivation")
        )
        self.assertIn("executeActivation(", method_body("activationTaskThunk"))

    def test_transfer_worker_retains_activation_stack_budget(self):
        self.assertIn(
            "constexpr uint32_t kTransferHttpWorkerStackBytes = 16384;",
            DEVICE_TRANSFER_SOURCE,
        )

    def test_remote_debug_worker_retains_network_setup_stack_budget(self):
        self.assertIn(
            "constexpr uint32_t kDebugHttpWorkerStackBytes = 16384;",
            DEVICE_TRANSFER_SOURCE,
        )
        self.assertIn(
            'requestedMode == "debug" ? kDebugHttpWorkerStackBytes',
            DEVICE_TRANSFER_SOURCE,
        )

    def test_activation_progress_yields_to_the_idle_task(self):
        body = method_body("updateActivationProgress")
        self.assertIn("vTaskDelay(pdMS_TO_TICKS(1));", body)

    def test_deferred_state_records_response_semantics(self):
        self.assertIn("bool activationAlreadyBegun = false;", HEADER)
        self.assertIn("bool automaticExitOnCleanResponse = true;", HEADER)

    def test_renderer_handoff_preserves_bounded_diagnostic_identity(self):
        self.assertIn("struct ActivatedMapRoot", HEADER)
        body = method_body("takeActivatedMapRoot")
        self.assertIn("activated.root = pendingMapRoot_;", body)
        self.assertIn("activated.mapId = pendingMapId_;", body)
        self.assertIn(
            "activated.sessionPresent = !pendingMapSessionId_.empty();",
            body,
        )

    def test_completed_upload_survives_obsolete_cleanup_failure(self):
        body = method_body("handlePut")
        self.assertIn("post-upload cleanup incomplete", body)
        self.assertIn("continuing with completed upload", body)
        self.assertNotIn('sendError(client, 500, "staging_cleanup"', body)


if __name__ == "__main__":
    unittest.main()
