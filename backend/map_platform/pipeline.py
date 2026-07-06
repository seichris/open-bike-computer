from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .manifest import PipelineMetadata, build_manifest, stable_map_id, write_pack_archive
from .models import JobStatus, MapJob


@dataclass(frozen=True)
class PipelinePaths:
    repo_root: Path
    work_root: Path
    pack_root: Path

    @property
    def osm_extract_root(self) -> Path:
        return self.repo_root / "OSM_Extract"


class CommandRunner:
    def run(self, args: list[str], *, cwd: Path | None = None) -> str:
        result = subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True)
        return (result.stdout or result.stderr).strip()


class MapBuildPipeline:
    def __init__(self, paths: PipelinePaths, runner: CommandRunner | None = None):
        self.paths = paths
        self.runner = runner or CommandRunner()

    def build(self, job: MapJob, on_status=None) -> tuple[str, Path]:
        map_id = stable_map_id(job)
        job.map_id = map_id
        job_dir = self.paths.work_root / job.job_id
        clipped_pbf = job_dir / "clipped.osm.pbf"
        geojson_prefix = job_dir / "features"
        raw_output_dir = job_dir / "raw-map"
        pack_root = job_dir / "pack"
        vectmap_output = pack_root / "VECTMAP" / map_id
        archive_path = self.paths.pack_root / f"{map_id}.zip"

        if job_dir.exists():
            shutil.rmtree(job_dir)
        job_dir.mkdir(parents=True)
        self.paths.pack_root.mkdir(parents=True, exist_ok=True)

        if on_status:
            on_status(JobStatus.RESOLVING_SOURCE)
        source_pbf = self._source_pbf_path(job)
        if on_status:
            on_status(JobStatus.EXTRACTING_PBF)
        self._extract_pbf(job, source_pbf, clipped_pbf)
        if on_status:
            on_status(JobStatus.CONVERTING_FEATURES)
        self._convert_to_geojson(job, clipped_pbf, geojson_prefix)
        self._extract_features(job, geojson_prefix, raw_output_dir)
        if on_status:
            on_status(JobStatus.PACKAGING)
        self._stage_vectmap(raw_output_dir, vectmap_output)

        manifest = build_manifest(job, pack_root, self._pipeline_metadata())
        write_pack_archive(pack_root, manifest, archive_path)
        return map_id, archive_path

    def _source_pbf_path(self, job: MapJob) -> Path:
        if not job.source_region.local_path:
            raise FileNotFoundError(f"source region {job.source_region.id} has no localPath configured")
        source = Path(job.source_region.local_path)
        if not source.is_absolute():
            source = self.paths.repo_root / source
        if not source.exists():
            raise FileNotFoundError(f"source PBF is missing: {source}")
        return source

    def _extract_pbf(self, job: MapJob, source_pbf: Path, clipped_pbf: Path) -> None:
        bounds = job.geometry.bounds
        args = [
            "osmium",
            "extract",
            "--strategy=smart",
            "-b",
            f"{bounds.min_lon},{bounds.min_lat},{bounds.max_lon},{bounds.max_lat}",
            str(source_pbf),
            "-o",
            str(clipped_pbf),
            "--overwrite",
        ]
        if job.geometry.geometry and job.geometry.mode.value == "custom_polygon":
            polygon_path = clipped_pbf.parent / "clip.geojson"
            polygon_path.write_text(json.dumps(job.geometry.geometry))
            args = [
                "osmium",
                "extract",
                "--strategy=smart",
                "-p",
                str(polygon_path),
                str(source_pbf),
                "-o",
                str(clipped_pbf),
                "--overwrite",
            ]
        self.runner.run(args)

    def _convert_to_geojson(self, job: MapJob, clipped_pbf: Path, geojson_prefix: Path) -> None:
        bounds = job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "pbf_to_geojson.sh"
        self.runner.run(
            [
                "bash",
                str(script),
                str(bounds.min_lon),
                str(bounds.min_lat),
                str(bounds.max_lon),
                str(bounds.max_lat),
                str(clipped_pbf),
                str(geojson_prefix),
            ],
            cwd=self.paths.osm_extract_root / "scripts",
        )

    def _extract_features(self, job: MapJob, geojson_prefix: Path, raw_output_dir: Path) -> None:
        bounds = job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "extract_features.py"
        self.runner.run(
            [
                "python",
                str(script),
                str(bounds.min_lon),
                str(bounds.min_lat),
                str(bounds.max_lon),
                str(bounds.max_lat),
                str(geojson_prefix),
                str(raw_output_dir),
            ],
            cwd=self.paths.osm_extract_root / "scripts",
        )

    def _stage_vectmap(self, raw_output_dir: Path, vectmap_output: Path) -> None:
        if not raw_output_dir.exists():
            raise FileNotFoundError(f"OSM_Extract output is missing: {raw_output_dir}")
        vectmap_output.mkdir(parents=True, exist_ok=True)
        for child in raw_output_dir.iterdir():
            destination = vectmap_output / child.name
            if child.is_dir():
                shutil.copytree(child, destination)
            elif child.suffix in {".fmb", ".fmp"}:
                shutil.copy2(child, destination)

    def _pipeline_metadata(self) -> PipelineMetadata:
        osmium_version = "unknown"
        try:
            osmium_version = self.runner.run(["osmium", "--version"]).splitlines()[0]
        except Exception:
            pass
        return PipelineMetadata(osmium_version=osmium_version)


def run_job(store, pipeline: MapBuildPipeline, job_id: str) -> MapJob:
    job = store.update_status(job_id, JobStatus.VALIDATING)

    def update(status: JobStatus) -> None:
        store.update_status(job_id, status)

    try:
        map_id, archive_path = pipeline.build(job, on_status=update)
        return store.update_status(job_id, JobStatus.READY, map_id=map_id, pack_path=str(archive_path))
    except Exception as exc:
        return store.update_status(job_id, JobStatus.FAILED, error=str(exc))
