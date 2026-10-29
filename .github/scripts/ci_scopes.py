"""Conservative sub-scopes for the component gate (shared with local checks)."""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/development'))
from swift_compile import sources

MAP_SCOPES = ('map_source', 'map_catalog', 'map_social', 'map_readers', 'map_deploy')
COMPOSE_LOCKS = {'map-platform/deploy/compose.yaml', 'map-platform/deploy/compose.development.yaml'}

# Inputs consumed only by existing fast checks. Keep one mapping for local and
# hosted selection; adding an input here must identify its executable consumers.
SHARED_FAST_CHECKS = {
    'protocol/fixtures/workout-zones-v1.json': ('ios-navigation-workout',),
    'tools/firmware_ota_channels.py': ('esp32-host-firmware-manifest-tests',),
    'tools/firmware_release_history.py': ('esp32-host-firmware-manifest-tests',),
    'tools/verify_firmware_boot_acceptance.py': ('esp32-host-firmware-manifest-tests',),
}


def registry_checks():
    return json.loads((ROOT / 'tools/development/checks.json').read_text())['checks']


def product_inputs(paths):
    # CI/development unit tests already run in the selection job.
    return [p for p in paths or () if not p.endswith('.md') and not p.startswith(
        ('.github/scripts/tests/', 'tools/development/tests/'))]


def shared_fast_checks(paths):
    """Return exact checks only when every executable input is explicitly mapped."""
    inputs = product_inputs(paths)
    if not inputs or any(p not in SHARED_FAST_CHECKS for p in inputs):
        return None
    selected = {check for p in inputs for check in SHARED_FAST_CHECKS[p]}
    known = {c['id'] for c in registry_checks()}
    if selected - known:
        raise ValueError('shared input references unknown checks: ' + ', '.join(sorted(selected - known)))
    return selected


def firmware_host_checks(paths, *, selected):
    checks = [c['id'] for c in registry_checks() if c['component'] == 'firmware_host']
    narrow = shared_fast_checks(paths)
    result = [c for c in checks if narrow is None or c in narrow] if selected else []
    if selected and not result:
        raise ValueError('selected firmware host component has no checks')
    return result


def firmware_renderer_required(paths):
    # BLE and transfer-only edits do not change the rider-badge rasterizer.
    inputs = product_inputs(paths)
    return not inputs or any(not p.startswith(('esp32/lib/ble_navigation/',
        'esp32/lib/map_transfer/', 'esp32/lib/device_transfer/')) for p in inputs)


def zone_contracts_required(paths, *, ios, firmware_host):
    if not (ios or firmware_host):
        return False
    narrow = shared_fast_checks(paths)
    # The zone fixture has Swift and both-board wire/display consumers. The
    # release-history and boot-evidence Python tools have none of those inputs.
    return narrow is None or 'ios-navigation-workout' in narrow


def map_scopes(paths, *, selected):
    result = dict.fromkeys(MAP_SCOPES, False)
    if not selected:
        return result
    if paths and set(paths) <= COMPOSE_LOCKS:
        result['map_deploy'] = True
    elif paths and all(p.startswith('map-platform/catalog/') for p in paths):
        result['map_catalog'] = True
    else:
        # Backend/config/workflow changes can affect every deployed consumer.
        result = dict.fromkeys(MAP_SCOPES, True)
    return result


# Profile suffixes of changed_components.FIRMWARE_TARGETS, in registry order.
FIRMWARE_PROFILE_SUFFIXES = ('', '_REMOTE_DEBUG', '_PRODUCTION', '_LIFECYCLE_QUALIFICATION',
                             '_POI_LIFECYCLE_QUALIFICATION')


def board_firmware_targets(boards):
    return tuple('WAVESHARE_AMOLED_'+b+s for b in boards for s in FIRMWARE_PROFILE_SUFFIXES)


def firmware_targets(paths, full_targets):
    if not paths:
        return full_targets
    paths = product_inputs(paths)
    relevant = [p for p in paths if p.startswith('esp32/')]
    if not relevant:
        return full_targets
    if all('206' in p for p in relevant):
        return board_firmware_targets(('206',))
    # Common board/runtime/config changes qualify both families and every profile.
    if any(not p.startswith('esp32/lib/') or p.startswith(('esp32/lib/panel/', 'esp32/lib/power/', 'esp32/lib/display/')) for p in relevant):
        if all('206' in p for p in relevant):
            boards = ('206',)
        else:
            boards = ('175', '206')
        return board_firmware_targets(boards)
    if len(relevant) != len(paths):
        # CI/runner inputs exercise the requested hardware family. Resolve
        # board/runtime changes first so a mixed diff cannot hide their board.
        return full_targets
    production_libraries = ('map_transfer', 'device_transfer', 'ble_navigation', 'maps', 'gui', 'device_debug', 'world_radio')
    if any(p.split('/')[2] not in production_libraries for p in relevant):
        return full_targets
    profiles = {'_PRODUCTION'}
    for path in relevant:
        if path.startswith(('esp32/lib/ble_navigation/', 'esp32/lib/map_transfer/')):
            # Remote-debug inherits ordinary diagnostics and adds debug/trust
            # branches; production exercises their disabled branches. The POI
            # budget profile is the only diagnostics-off, 3 MiB-slot image of
            # their nearby-POI code. Neither library contains the lifecycle-only
            # adapter implementation.
            profiles.update(('_REMOTE_DEBUG', '_POI_LIFECYCLE_QUALIFICATION'))
        else:
            profiles.update(('_LIFECYCLE_QUALIFICATION', '_POI_LIFECYCLE_QUALIFICATION'))
            if path.startswith(('esp32/lib/device_debug/', 'esp32/lib/gui/', 'esp32/lib/maps/')):
                profiles.add('_REMOTE_DEBUG')
            if path.startswith(('esp32/lib/world_radio/', 'esp32/lib/gui/')):
                profiles.update(('', '_REMOTE_DEBUG'))
    # Match exact suffixes: '_LIFECYCLE_QUALIFICATION' is also a POI suffix tail.
    return tuple(t for t in full_targets if re.fullmatch(r'WAVESHARE_AMOLED_\d{3}(.*)', t)[1] in profiles)


def ios_scopes(paths, *, native, selected):
    checks = registry_checks()
    fast = [c for c in checks if c['component'] == 'ios']
    if not selected:
        return {'ios_checks': [], 'ios_simulator': False, 'ios_release': False}
    narrow = shared_fast_checks(paths)
    if narrow is not None:
        return {'ios_checks': [c['id'] for c in fast if c['id'] in narrow],
                'ios_simulator': False, 'ios_release': False}
    full = not paths or any(not p.endswith('.swift') for p in paths)
    groups = json.loads((ROOT / 'tools/development/swift-sources.json').read_text())['groups']
    nav = [c for c in fast if 'ciInputs' in c]
    inputs = {}
    for c in nav:
        metadata = c['ciInputs']
        inputs[c['id']] = set(metadata.get('inputs', []))
        for g in metadata.get('swiftGroups', []):
            inputs[c['id']].update(sources(g, groups))
    def matches(check, path):
        return path in inputs[check['id']] or path.startswith(tuple(check['ciInputs'].get('inputPrefixes', [])))
    # An unknown or deleted source is never evidence that a helper is irrelevant.
    full = full or any(not any(matches(c, p) for c in nav) for p in paths or [])
    selected_checks = [c['id'] for c in fast if 'ciInputs' not in c or full or any(matches(c,p) for p in paths)]
    shared = ('ios-app/BikeComputer/WorkoutShared/', 'ios-app/BikeComputer/RideShared/', 'ios-app/BikeComputer/BikeComputerWatch/', 'ios-app/BikeComputer/BikeComputerLiveActivity/')
    project = (ROOT / 'ios-app/BikeComputer/BikeComputer.xcodeproj/project.pbxproj').read_text()
    # These dedicated targets explicitly enumerate their production and test files.
    phases = project[project.index('/* Begin PBXSourcesBuildPhase section */'):project.index('/* End PBXSourcesBuildPhase section */')]
    simulator_names = set(re.findall(r'/\* ([^/]+\.swift) in Sources \*/', phases))
    simulator = native and (not paths or any(not p.endswith('.swift') or p.startswith(shared) or Path(p).name in simulator_names for p in paths))
    release = native and (not paths or any(not p.endswith('.swift') or '/BuildIdentity' in p or '/AppIdentity' in p for p in paths))
    watch_check = 'ios-fast-type-check-the-complete-watch-source-graph'
    if not full and paths and all(p.endswith('.swift') and not p.startswith(shared) for p in paths):
        selected_checks.remove(watch_check)
    return {'ios_checks': selected_checks, 'ios_simulator': simulator, 'ios_release': release}
