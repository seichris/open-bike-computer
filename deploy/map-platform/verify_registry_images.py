#!/usr/bin/env python3
"""Verify production image availability, platform, and GitHub provenance."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path
from typing import Sequence

from update_image import DeploymentImages, validate_manifest


SOURCE_REPOSITORY = "seichris/open-bike-computer"
SIGNER_WORKFLOW = (
    "seichris/open-bike-computer/.github/workflows/map-platform-image.yml"
)
REQUIRED_OS = "linux"
REQUIRED_ARCHITECTURE = "amd64"
REQUIRED_SOURCE_REF = "refs/heads/main"


def _run(command: Sequence[str], attempts: int = 3) -> str:
    if attempts < 1:
        raise ValueError("attempts must be positive")
    for attempt in range(attempts):
        try:
            completed = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
            return completed.stdout
        except subprocess.CalledProcessError as error:
            if attempt + 1 == attempts:
                detail = (error.stderr or error.stdout or "").strip()
                message = f"command failed after {attempts} attempts: {' '.join(command)}"
                if detail:
                    message = f"{message}: {detail}"
                raise RuntimeError(message) from error
            time.sleep(2**attempt)
    raise AssertionError("retry loop must return or raise")


def require_linux_amd64(raw_manifest: str, reference: str) -> None:
    try:
        manifest = json.loads(raw_manifest)
    except json.JSONDecodeError as error:
        raise ValueError(f"registry returned invalid JSON for {reference}") from error
    descriptors = manifest.get("manifests")
    if not isinstance(descriptors, list):
        raise ValueError(f"{reference} is not a platform-indexed OCI image")
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            continue
        platform = descriptor.get("platform")
        if not isinstance(platform, dict):
            continue
        if (
            platform.get("os") == REQUIRED_OS
            and platform.get("architecture") == REQUIRED_ARCHITECTURE
        ):
            return
    raise ValueError(f"{reference} does not contain a linux/amd64 image")


def verify_image(reference: str, source_commit: str) -> None:
    raw_manifest = _run(
        ["docker", "buildx", "imagetools", "inspect", reference, "--raw"]
    )
    require_linux_amd64(raw_manifest, reference)
    _run(
        [
            "gh",
            "attestation",
            "verify",
            f"oci://{reference}",
            "--repo",
            SOURCE_REPOSITORY,
            "--signer-workflow",
            SIGNER_WORKFLOW,
            "--source-digest",
            source_commit,
            "--source-ref",
            REQUIRED_SOURCE_REF,
            "--deny-self-hosted-runners",
        ]
    )


def verify_deployment(deployment: DeploymentImages) -> None:
    verify_image(
        deployment.control_plane_reference,
        deployment.control_plane_source_commit,
    )
    verify_image(deployment.worker_reference, deployment.worker_source_commit)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify digest-pinned production images in GHCR",
    )
    parser.add_argument("compose", type=Path)
    args = parser.parse_args()
    deployment = validate_manifest(args.compose)
    verify_deployment(deployment)
    print(
        "verified control-plane "
        f"{deployment.control_plane_source_commit} "
        f"{deployment.control_plane_reference}"
    )
    print(
        f"verified worker {deployment.worker_source_commit} "
        f"{deployment.worker_reference}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
