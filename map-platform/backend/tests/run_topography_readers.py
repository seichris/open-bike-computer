"""Run the macOS native-reader CI suite and require a passing ImageIO contract."""

import sys
import unittest


IMAGEIO_TEST = (
    "tests.test_topography_geometry.TopographyGeometryTests."
    "test_iphone_companion_reader_accepts_python_artifact_and_rejects_mutations"
)


class NativeReaderResult(unittest.TextTestResult):
    imageio_passed = False

    def addSuccess(self, test):
        super().addSuccess(test)
        if test.id() == IMAGEIO_TEST:
            self.imageio_passed = True


def main():
    suite = unittest.defaultTestLoader.loadTestsFromNames(
        ["tests.test_topography_artifacts", "tests.test_topography_geometry"]
    )
    result = unittest.TextTestRunner(verbosity=2, resultclass=NativeReaderResult).run(suite)
    if not result.imageio_passed:
        sys.exit(f"Required ImageIO test did not pass: {IMAGEIO_TEST}")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
