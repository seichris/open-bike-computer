"""Keep representative change scenarios within explicit CI work budgets."""
import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import changed_components as components
import ci_scopes as scopes

# Experimental e-paper builds that automatic selection adds to shared changes.
EPAPER_PAIR = ('WAVESHARE_EPAPER_397', 'WAVESHARE_EPAPER_397_PRODUCTION')


class CiCostBudgetTests(unittest.TestCase):
    def test_shared_fixture_has_only_its_swift_and_wire_consumers(self):
        paths = ['protocol/fixtures/workout-zones-v1.json', '.github/scripts/tests/test_ci_cost_budget.py']
        selected = components.classify_paths(paths)
        self.assertEqual([key for key, value in selected.items() if value], ['ios'])
        native = components.native_ios_required(paths)
        self.assertFalse(native)
        self.assertEqual(scopes.ios_scopes(paths, native=native, selected=True),
                         {'ios_checks': ['ios-navigation-workout'], 'ios_simulator': False, 'ios_release': False})
        self.assertTrue(scopes.zone_contracts_required(paths, ios=True, firmware_host=False))

    def test_release_tools_do_not_run_unrelated_native_checks(self):
        for path in ('tools/firmware_release_history.py', 'tools/verify_firmware_boot_acceptance.py'):
            selected = components.classify_paths([path])
            self.assertEqual([key for key, value in selected.items() if value], ['firmware_host'])
            self.assertEqual(scopes.firmware_host_checks([path], selected=True), ['esp32-host-firmware-manifest-tests'])
            self.assertFalse(scopes.zone_contracts_required([path], ios=False, firmware_host=True))

    def test_routine_firmware_changes_keep_three_builds_per_requested_board_and_the_epaper_pair(self):
        for board in ('175', '206'):
            full = components.select_firmware_targets(board)
            for library in ('ble_navigation', 'map_transfer'):
                paths = [f'esp32/lib/{library}/example.cpp', 'docs/change.md', '.github/scripts/tests/test_ci_scopes.py']
                targets = scopes.firmware_targets(paths, full)
                # Ordinary and plain lifecycle builds add no conditional arm here.
                self.assertEqual(set(targets), {f'WAVESHARE_AMOLED_{board}_PRODUCTION', f'WAVESHARE_AMOLED_{board}_REMOTE_DEBUG',
                                                f'WAVESHARE_AMOLED_{board}_POI_LIFECYCLE_QUALIFICATION', *EPAPER_PAIR})
                self.assertFalse(scopes.firmware_renderer_required(paths))

    def test_ci_recipe_edits_do_not_double_the_selected_hardware_matrix(self):
        for board in ('175', '206', 'all'):
            full = components.select_firmware_targets(board)
            self.assertEqual(scopes.firmware_targets(['.github/workflows/ci.yml', 'tools/dev_check.py'], full), full + EPAPER_PAIR)
        both_boards = scopes.board_firmware_targets(('175', '206'))
        self.assertEqual(scopes.firmware_targets(['esp32/platformio.ini'], components.select_firmware_targets('175')), both_boards + EPAPER_PAIR)
        for other in ('.github/workflows/ci.yml', 'tools/dev_check.py', 'ios-app/BikeComputer/App.swift'):
            targets = scopes.firmware_targets(['esp32/platformio.ini', other], components.select_firmware_targets('175'))
            self.assertEqual(targets, both_boards + EPAPER_PAIR)
            targets = scopes.firmware_targets(['esp32/lib/panel/WAVESHARE_AMOLED_206.cpp', other], components.select_firmware_targets('175'))
            self.assertEqual(targets[-2:], EPAPER_PAIR)
            self.assertTrue(targets[:-2])
            self.assertTrue(all('206' in target for target in targets[:-2]))

    def test_epaper_adds_two_builds_unless_its_own_sources_change(self):
        full = components.select_firmware_targets('175')
        for path in ('esp32/lib/ble_navigation/example.cpp', 'esp32/lib/storage/storage.cpp',
                     'esp32/platformio.ini', '.github/workflows/ci.yml'):
            targets = scopes.firmware_targets([path], full)
            self.assertEqual(sum('EPAPER' in t for t in targets), 2, path)
        # Its own sources build its whole matrix and no AMOLED image.
        self.assertEqual(scopes.firmware_targets(['esp32/lib/epaper_display/epaper_display.cpp'], full),
                         components.select_firmware_targets('397'))

    def test_unmapped_input_stops_cli_without_product_selection_outputs(self):
        output, errors = io.StringIO(), io.StringIO()
        with patch('sys.argv', ['changed_components.py', '--event', 'pull_request']), \
             patch.object(components, 'changed_paths', return_value=['protocol/unmapped-input.json']), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors), \
             self.assertRaises(SystemExit) as result:
            components.main()
        self.assertNotEqual(result.exception.code, 0)
        self.assertEqual(output.getvalue(), '')
        self.assertIn('explicit consumer mapping', errors.getvalue())


if __name__ == '__main__':
    unittest.main()
