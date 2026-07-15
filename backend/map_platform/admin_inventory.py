from __future__ import annotations

import hashlib
import hmac
from typing import Any, Iterable

from .models import MapJob


def map_inventory(
    jobs: Iterable[MapJob],
    *,
    pseudonym_secret: str,
    include_undownloaded: bool = False,
) -> dict[str, Any]:
    if not pseudonym_secret:
        raise ValueError("admin inventory pseudonym secret is required")
    selected = [
        job
        for job in jobs
        if include_undownloaded or job.download_receipts
    ]
    selected.sort(
        key=lambda job: (
            job.download_receipts[-1].downloaded_at
            if job.download_receipts
            else job.created_at
        ),
        reverse=True,
    )
    installation_ids = {
        job.client_installation_id
        for job in selected
        if job.client_installation_id is not None
    }
    return {
        "summary": {
            "mapJobs": len(selected),
            "downloads": sum(len(job.download_receipts) for job in selected),
            "uniqueInstallations": len(installation_ids),
            "downloadedBytes": sum(
                receipt.bytes
                for job in selected
                for receipt in job.download_receipts
            ),
            "reusedMapJobs": sum(
                job.reuse_strategy in {"exact", "subset"} for job in selected
            ),
        },
        "maps": [
            _inventory_row(job, pseudonym_secret=pseudonym_secret)
            for job in selected
        ],
    }


def _inventory_row(job: MapJob, *, pseudonym_secret: str) -> dict[str, Any]:
    receipts = job.download_receipts
    return {
        "jobId": job.job_id,
        "mapId": job.map_id,
        "userLabel": job.user_label,
        "displayName": job.user_label or job.source_region.name or job.map_id,
        "geofabrik": {
            "provider": job.source_region.provider,
            "id": job.source_region.id,
            "name": job.source_region.name,
        },
        "geometry": {
            "mode": job.geometry.mode.value,
            "bounds": job.geometry.bounds.to_list(),
            "areaKm2": job.geometry.area_km2,
        },
        "packBytes": job.pack_bytes,
        "artifacts": [
            {
                "format": artifact.format,
                "bytes": artifact.bytes,
                "sha256": artifact.sha256,
            }
            for artifact in job.artifacts
        ],
        "downloadCount": len(receipts),
        "downloadedBytes": sum(receipt.bytes for receipt in receipts),
        "firstDownloadedAt": receipts[0].downloaded_at if receipts else None,
        "lastDownloadedAt": receipts[-1].downloaded_at if receipts else None,
        "reuse": {
            "strategy": job.reuse_strategy,
            "sourceJobId": job.reuse_source_job_id,
        },
        "createdAt": job.created_at,
        "readyAt": job.finished_at if job.status.value == "ready" else None,
        "installationRef": _installation_ref(
            job.client_installation_id,
            pseudonym_secret=pseudonym_secret,
        ),
    }


def _installation_ref(
    installation_id: str | None,
    *,
    pseudonym_secret: str,
) -> str | None:
    if installation_id is None:
        return None
    digest = hmac.new(
        pseudonym_secret.encode("utf-8"),
        installation_id.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return f"install_{digest[:12]}"
