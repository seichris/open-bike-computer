import base64
import sqlite3
import struct
import tempfile
import unittest
import zlib
from pathlib import Path
from types import SimpleNamespace

import numpy as np
from map_platform.terrain import ALGORITHM, SIZE, NODATA, encode_grid, validate_grid, grids_from_mosaic
from map_platform.topography_artifacts import Contour, ContourSection
from map_platform.topography_geometry import CompiledTopography
from map_platform.topography_companion import write_companion, validate_companion

class TerrainTests(unittest.TestCase):
    def test_terrain_request_requires_explicit_v4_opt_in(self):
        from map_platform.jobs import _validate_map_job_fields
        for version, profile in ((3, 1), (4, True), (4, 2), (None, 1)):
            request = {"target": {"renderer": "esp32-fmb", "terrainProfileVersion": profile}}
            if version is not None:
                request["target"]["rendererFormatVersion"] = version
            with self.assertRaises(ValueError):
                _validate_map_job_fields(request)
        request = {"target": {"renderer": "esp32-fmb", "rendererFormatVersion": 4, "terrainProfileVersion": 1}}
        request["labels"] = {"profileVersion": 1, "preferredLanguages": ["en"], "internationalFallback": "en"}
        _validate_map_job_fields(request)
        self.assertEqual(request["target"]["terrainProfileVersion"], 1)

    def test_terrain_algorithm_participates_in_reuse(self):
        from map_platform.topography_reuse import sample_matches_input_identity
        self.assertTrue(sample_matches_input_identity({}, {}))
        self.assertFalse(sample_matches_input_identity({"terrainAlgorithm": ALGORITHM}, {}))
        self.assertFalse(sample_matches_input_identity({"terrainAlgorithm": ALGORITHM}, {"terrainAlgorithm": "future"}))

    def test_grid_budget_is_checked_before_sampling(self):
        with self.assertRaisesRegex(ValueError, "256 block"):
            grids_from_mosaic(None, None, [-170, -80, 170, 80])

    def test_codec_bounds_crc_and_nodata(self):
        data = encode_grid(-1, 2, [(100, 180, 0)] * 1089)
        self.assertEqual(len(data), SIZE)
        self.assertEqual(validate_grid(data), (-1, 2))
        for damaged in (data[:-1], data+b'\0', b'BAD!'+data[4:], data[:-1]+b'\x01'):
            with self.assertRaises(ValueError): validate_grid(damaged)
        for node in [(NODATA,1,0), (100,2,91), (10001,0,0)]:
            with self.assertRaises(ValueError): encode_grid(0,0,[node]*1089)
        self.assertEqual(validate_grid(encode_grid(0,0,[(NODATA,0,0)]*1089)),(0,0))

    def test_flat_plane_and_shared_seam(self):
        # A source plane spanning two globally aligned blocks, with halo.
        grid = SimpleNamespace(crs='EPSG:3857',left=-1024,top=6144,resolution=32)
        mosaic = np.full((224, 384), 800, dtype='float32')
        bounds = [0.001, 0.001, 0.07, 0.03]
        output = [base64.b64decode(v) for v in grids_from_mosaic(mosaic,grid,bounds)]
        by_key = {validate_grid(data): list(struct.iter_unpack('<hBB',data[16:])) for data in output}
        self.assertTrue(by_key)
        self.assertEqual(by_key[(0,0)][16*33+16], (800,180,0))
        for y in range(33): self.assertEqual(by_key[(0,0)][y*33+32], by_key[(1,0)][y*33])
        mosaic[80:140,80:140] = np.nan
        outputs = [base64.b64decode(v) for v in grids_from_mosaic(mosaic,grid,bounds)]
        self.assertTrue(any(h==NODATA for data in outputs for h,_,_ in struct.iter_unpack('<hBB',data[16:])))

    def test_slope_is_derived_from_dem(self):
        grid = SimpleNamespace(crs='EPSG:3857',left=-1024,top=6144,resolution=32)
        mosaic = np.tile(np.arange(384,dtype='float32')*32,(224,1))
        output = [base64.b64decode(v) for v in grids_from_mosaic(mosaic,grid,[.001,.001,.03,.03])]
        nodes = list(struct.iter_unpack('<hBB',output[0][16:]))
        self.assertAlmostEqual(nodes[16*33+16][2],45,delta=1)

    def test_companion_v1_and_v2_readability_and_corrupt_feature(self):
        section = ContourSection(20,100,(Contour(800,1,((0,256),(4096,256))),))
        compiled = CompiledTopography({(0,0):section},'a'*64,'b'*64,'c'*64)
        with tempfile.TemporaryDirectory() as tmp:
            for version in (1,2):
                path = Path(tmp)/f'{version}.btopo'
                terrain = None if version==1 else {(0,0):encode_grid(0,0,[(800,180,0)]*1089)}
                metadata = write_companion(path,compiled,map_id='fixture',source_policy_sha256='d'*64,attribution_sha256='e'*64,bounds_e7=[0,0,400000,400000],terrain_grids=terrain)
                self.assertEqual(metadata['schemaVersion'],version)
                self.assertEqual(validate_companion(path),metadata)
            path = Path(tmp)/'2.btopo'
            with sqlite3.connect(path) as db:
                self.assertGreater(db.execute('SELECT count(*) FROM labels').fetchone()[0],0)
                db.execute('UPDATE labels SET elevation=801')
            with self.assertRaises(ValueError): validate_companion(path)

if __name__ == '__main__': unittest.main()
