from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


DEPLOY_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DEPLOY_DIR))
MODULE_PATH = DEPLOY_DIR / "verify_registry_images.py"
SPEC = importlib.util.spec_from_file_location("verify_registry_images", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
verify_registry_images = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verify_registry_images
SPEC.loader.exec_module(verify_registry_images)


class VerifyRegistryImagesTests(unittest.TestCase):
    def test_scheduler_converter_pairing_and_complete_rollback(self) -> None:
        legacy = verify_registry_images.LEGACY_PROMOTION_REFERENCE
        old_converter = verify_registry_images.LEGACY_CONVERTER_REFERENCE
        current = verify_registry_images.IMAGE_REPOSITORY + "@sha256:" + "a" * 64
        converter = verify_registry_images.IMAGE_REPOSITORY + "@sha256:d8b9d172d657cbfa7298e970968b64520c6b3d00f8dcb28758bab8f8cef3a9b9"
        verify_registry_images.verify_promotion_pairing(legacy, old_converter)
        with self.assertRaises(ValueError):
            verify_registry_images.verify_promotion_pairing(legacy, converter)
        image = {
            "os": "linux", "architecture": "amd64", "config": {"Labels": {
                "org.bicino.release-profile": "production-map-promotion",
                "org.bicino.converter-image": converter,
            }},
        }
        with mock.patch.object(verify_registry_images, "_run", return_value=json.dumps(image)):
            verify_registry_images.verify_promotion_pairing(current, converter)
            for mismatched in (old_converter, None):
                with self.assertRaises(ValueError):
                    verify_registry_images.verify_promotion_pairing(current, mismatched)
        for invalid in ("null", "{}", "[]", "invalid", json.dumps({
            **image, "architecture": "arm64",
        }), json.dumps({**image, "config": {"Labels": {
            "org.bicino.release-profile": "standard",
            "org.bicino.converter-image": converter,
        }}})):
            with self.subTest(invalid=invalid), mock.patch.object(
                verify_registry_images, "_run", return_value=invalid,
            ), self.assertRaises(ValueError):
                verify_registry_images.verify_promotion_pairing(current, converter)

    def test_deployment_verification_rejects_partial_scheduler_rollback(self) -> None:
        from dataclasses import replace
        deployment = verify_registry_images.DeploymentImages(
            "a" * 40, "control", "b" * 40, "worker", "c" * 40,
            verify_registry_images.LEGACY_PROMOTION_REFERENCE,
            verify_registry_images.LEGACY_CONVERTER_REFERENCE,
        )
        with mock.patch.object(verify_registry_images, "verify_image"):
            verify_registry_images.verify_deployment(deployment)
            with self.assertRaises(ValueError):
                verify_registry_images.verify_deployment(replace(
                    deployment, promotion_converter_reference="wrong-converter",
                ))

    def test_registry_commands_retry_transient_failures(self) -> None:
        failure = subprocess.CalledProcessError(
            1,
            ["registry", "inspect"],
            stderr="temporary registry error",
        )
        success = subprocess.CompletedProcess(
            ["registry", "inspect"],
            0,
            stdout="manifest",
            stderr="",
        )
        with mock.patch.object(
            verify_registry_images.subprocess,
            "run",
            side_effect=[failure, success],
        ) as run, mock.patch.object(verify_registry_images.time, "sleep") as sleep:
            output = verify_registry_images._run(["registry", "inspect"])

        self.assertEqual(output, "manifest")
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(1)

    def test_linux_amd64_platform_is_required(self) -> None:
        valid = json.dumps(
            {
                "manifests": [
                    {"platform": {"os": "unknown", "architecture": "unknown"}},
                    {"platform": {"os": "linux", "architecture": "amd64"}},
                ]
            }
        )
        verify_registry_images.require_linux_amd64(valid, "image@sha256:digest")

        for invalid in (
            "not-json",
            json.dumps({"architecture": "amd64", "os": "linux"}),
            json.dumps(
                {"manifests": [{"platform": {"os": "linux", "architecture": "arm64"}}]}
            ),
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                verify_registry_images.require_linux_amd64(
                    invalid,
                    "image@sha256:digest",
                )

    def test_verification_binds_attestation_to_source_and_workflow(self) -> None:
        manifest = json.dumps(
            {"manifests": [{"platform": {"os": "linux", "architecture": "amd64"}}]}
        )
        reference = "ghcr.io/seichris/open-bike-computer-map-platform@sha256:" + "a" * 64
        source_commit = "b" * 40

        with mock.patch.object(
            verify_registry_images,
            "_run",
            side_effect=[manifest, "verified"],
        ) as run:
            verify_registry_images.verify_image(reference, source_commit)

        self.assertEqual(
            run.call_args_list[0].args[0],
            ["docker", "buildx", "imagetools", "inspect", reference, "--raw"],
        )
        attestation_command = run.call_args_list[1].args[0]
        self.assertIn(f"oci://{reference}", attestation_command)
        self.assertEqual(
            attestation_command[
                attestation_command.index("--source-digest") + 1
            ],
            source_commit,
        )
        self.assertEqual(
            attestation_command[
                attestation_command.index("--signer-workflow") + 1
            ],
            verify_registry_images.SIGNER_WORKFLOW,
        )
        self.assertEqual(
            attestation_command[
                attestation_command.index("--source-ref") + 1
            ],
            verify_registry_images.REQUIRED_SOURCE_REF,
        )
        self.assertIn("--deny-self-hosted-runners", attestation_command)


if __name__ == "__main__":
    unittest.main()
