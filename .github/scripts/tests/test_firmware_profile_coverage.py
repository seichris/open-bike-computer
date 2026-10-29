"""Prove reduced profiles still enter every conditional arm in scoped libraries.

This is preprocessor coverage, not a firmware build or hardware qualification.
Keep it independent of the router's profile choices and use the actual inherited
PlatformIO definitions and source, so new ordinary/lifecycle-only branches fail
before CI can omit the profile that needs to compile them.
"""
import configparser
from functools import lru_cache
from pathlib import Path
import re
import shlex
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / '.github/scripts'))
import changed_components
import ci_scopes


@lru_cache(maxsize=None)
def flags(target):
    config = configparser.ConfigParser(interpolation=None)
    config.read(ROOT / 'esp32/platformio.ini')

    def expand(section, key):
        return re.sub(r'\$\{([^}]+)\}', lambda m: str(ROOT / 'esp32') if m[1] == 'PROJECT_DIR' else expand(*m[1].rsplit('.', 1)),
                      config[section][key])

    tokens = iter(shlex.split(expand('env:' + target, 'build_flags')))
    return [token + next(tokens) if token == '-D' else token
            for token in tokens if token.startswith('-D')]


PLATFORM_DEFINES = ('ARDUINO=10812', 'ARDUINO_ARCH_ESP32', 'ESP_PLATFORM',
                    'BOARD_HAS_PSRAM', 'MBEDTLS_VERSION_NUMBER=0x03000000',
                    'MBEDTLS_VERSION_MAJOR=3', 'CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1')
# Separate host/diagnostic experiments and the isolated, manually built POI
# qualification signer, absent from every regular CI profile.
UNDEFINED_IN_REGULAR_PROFILES = {'DEVICE_OWNERSHIP_HOST_TEST', 'BLE_DEV_RANDOM_IDENTITY',
    'BLE_RADIO_CHARACTERIZATION', 'DISPLAY_POWER_DIAGNOSTICS', 'POWER_METRICS',
    'MAP_STREAM_QUALIFICATION_TRUST'}


def check_condition_inputs(source):
    """Do not silently treat an unknown include-derived feature as zero."""
    logical = re.sub(r'\\\n', ' ', source)

    def names(expression):
        expression = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', '', expression, flags=re.S)
        return set(re.findall(r'\b[A-Za-z_][A-Za-z_0-9]*\b', expression)) - {'defined', 'true', 'false'}

    # The manually selected e-paper family defines its board macro; AMOLED
    # coverage below still evaluates only AMOLED profiles, where it is absent.
    known = {re.match(r'-D([A-Za-z_][A-Za-z_0-9]*)', flag)[1]
             for hardware in ('all', '397')
             for profile in changed_components.select_firmware_targets(hardware)
             for flag in flags(profile)}
    known |= {d.split('=')[0] for d in PLATFORM_DEFINES} | UNDEFINED_IN_REGULAR_PROFILES
    local = {}
    for name, parameters, body in re.findall(r'^\s*#\s*define\s+([A-Za-z_][A-Za-z_0-9]*)(\([^\n]*?\))?([^\n]*)', logical, re.M):
        local[name] = names(body) - names(parameters)
    pending = names('\n'.join(re.findall(r'^\s*#\s*(?:if|elif|ifdef|ifndef)\b([^\n]*)', logical, re.M)))
    visited, missing = set(), set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        if name in local:
            pending.update(local[name])
        elif name not in known:
            missing.add(name)
    if missing:
        raise ValueError('unmodeled preprocessor inputs: ' + ', '.join(sorted(missing)))


def active_lines(source, defines):
    check_condition_inputs(source)
    lines = []
    continued = False
    for index, line in enumerate(source.splitlines(), 1):
        directive = line.lstrip().startswith('#') or continued
        if re.match(r'\s*#\s*include\b', line):
            lines.append('')
        else:
            lines.append(line)
            if not directive and not line.rstrip().endswith('\\'):
                lines.append(f'__CI_LINE_{index}__')
        continued = line.rstrip().endswith('\\')
    result = subprocess.run(['g++', '-E', '-P', '-x', 'c++', '-std=c++17',
        *('-D' + definition for definition in PLATFORM_DEFINES),
        *defines, '-'], input='\n'.join(lines), text=True, capture_output=True, check=True)
    return set(re.findall(r'__CI_LINE_(\d+)__', result.stdout))


class FirmwareProfileCoverageTests(unittest.TestCase):
    def test_unknown_include_derived_conditions_fail_instead_of_looking_covered(self):
        for source in ('#if UNMODELED_FEATURE\nint hidden;\n#endif',
                       '#define ALIAS UNMODELED_FEATURE\n#if ALIAS\nint hidden;\n#endif',
                       '#if ARDUINO // known\n#endif\n#if UNMODELED_FEATURE\nint hidden;\n#endif',
                       '#define FIRMWARE_DIAGNOSTICS UNMODELED_FEATURE\n#if FIRMWARE_DIAGNOSTICS\nint hidden;\n#endif'):
            with self.assertRaisesRegex(ValueError, 'unmodeled preprocessor inputs: UNMODELED_FEATURE'):
                active_lines(source, flags('WAVESHARE_AMOLED_175_PRODUCTION'))

    def test_guard_detects_a_new_ordinary_or_lifecycle_only_branch(self):
        profiles = changed_components.select_firmware_targets('175')
        selected = ci_scopes.firmware_targets(['esp32/lib/ble_navigation/ble_navigation.cpp'], profiles)
        for expression in ('FIRMWARE_DIAGNOSTICS && !DEVICE_REMOTE_DEBUG',
                           'FIRMWARE_OPERATIONS_V1_ENABLED && !MAP_POIS_RUNTIME_ENABLED'):
            source = f'#if {expression}\nint requires_another_profile;\n#endif\n'
            all_lines = set().union(*(active_lines(source, flags(p)) for p in profiles))
            selected_lines = set().union(*(active_lines(source, flags(p)) for p in selected))
            self.assertTrue(all_lines - selected_lines, expression)

    def test_transfer_libraries_keep_the_production_slot_poi_image(self):
        # Line coverage cannot see slot fit or diagnostics-off interactions of
        # nearby-POI code; remote-debug compiles it in a larger development slot.
        config = configparser.ConfigParser(interpolation=None)
        config.read(ROOT / 'esp32/platformio.ini')

        def option(section, key):
            while key not in config[section]:
                section = config[section]['extends'].strip()
            return config[section][key].strip()

        for board in ('175', '206'):
            profiles = changed_components.select_firmware_targets(board)
            production_slot = option(f'env:WAVESHARE_AMOLED_{board}_PRODUCTION', 'board_build.partitions')
            budget = {p for p in profiles if '-DMAP_POIS_RUNTIME_ENABLED=1' in flags(p)
                      and option('env:' + p, 'board_build.partitions') == production_slot}
            self.assertEqual(budget, {f'WAVESHARE_AMOLED_{board}_POI_LIFECYCLE_QUALIFICATION'})
            for library in ('ble_navigation', 'map_transfer'):
                selected = ci_scopes.firmware_targets([f'esp32/lib/{library}/example.cpp'], profiles)
                self.assertLessEqual(budget, set(selected), library)

    def test_selected_profiles_cover_existing_library_conditional_arms(self):
        for board in ('175', '206'):
            self.assert_board_coverage(board)

    def assert_board_coverage(self, board):
        profiles = changed_components.select_firmware_targets(board)
        definitions = {p: flags(p) for p in profiles}
        for library in ('ble_navigation', 'map_transfer'):
            for path in sorted((ROOT / 'esp32/lib' / library).glob('*')):
                if path.suffix not in ('.cpp', '.hpp', '.h', '.inc'):
                    continue
                source = path.read_text()
                if not re.search(r'^\s*#\s*(?:if|elif)', source, re.M):
                    continue
                selected = ci_scopes.firmware_targets([str(path.relative_to(ROOT))], profiles)
                try:
                    coverage = {p: active_lines(source, definitions[p]) for p in profiles}
                except subprocess.CalledProcessError as error:
                    self.fail(f'{path.relative_to(ROOT)}: {error.stderr}')
                missing = set().union(*coverage.values()) - set().union(*(coverage[p] for p in selected))
                self.assertFalse(missing, f'{path.relative_to(ROOT)}: uncovered lines {sorted(missing, key=int)}')


if __name__ == '__main__':
    unittest.main()
