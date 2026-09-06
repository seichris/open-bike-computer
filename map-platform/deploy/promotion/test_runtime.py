"""The scheduling wrapper must not alter the qualified converter or signer."""
import hashlib
from pathlib import Path
import unittest


class PromotionRuntimeTests(unittest.TestCase):
    def test_only_scheduler_added(self):
        def inventory(root):
            return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
        before = inventory(Path("/opt/promotion-base-app"))
        after = inventory(Path("/app"))
        differences = {key for key in before.keys() | after.keys() if before.get(key) != after.get(key)}
        self.assertEqual(differences, {"map-platform/backend/map_platform/automatic_promotion.py"})
