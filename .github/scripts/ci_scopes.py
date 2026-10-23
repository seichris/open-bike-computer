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


def firmware_targets(paths, full_targets):
    if not paths:
        return full_targets
    relevant = [p for p in paths if p.startswith('esp32/')]
    if len(relevant) != len(paths):
        return tuple('WAVESHARE_AMOLED_'+b+s for b in ('175', '206') for s in ('', '_REMOTE_DEBUG', '_PRODUCTION', '_LIFECYCLE_QUALIFICATION'))
    if all('206' in p for p in relevant):
        return tuple('WAVESHARE_AMOLED_206'+s for s in ('', '_REMOTE_DEBUG', '_PRODUCTION', '_LIFECYCLE_QUALIFICATION'))
    # Common board/runtime/config changes qualify both families and every profile.
    if any(not p.startswith('esp32/lib/') or p.startswith(('esp32/lib/panel/', 'esp32/lib/power/', 'esp32/lib/display/')) for p in relevant):
        if all('206' in p for p in relevant):
            boards = ('206',)
        else:
            boards = ('175', '206')
        return tuple('WAVESHARE_AMOLED_'+b+s for b in boards for s in ('', '_REMOTE_DEBUG', '_PRODUCTION', '_LIFECYCLE_QUALIFICATION'))
    production_libraries = ('map_transfer', 'device_transfer', 'ble_navigation', 'maps', 'gui', 'device_debug', 'world_radio')
    if any(p.split('/')[2] not in production_libraries for p in relevant):
        return full_targets
    profiles = {'_PRODUCTION', '_LIFECYCLE_QUALIFICATION'}
    if any(p.startswith(('esp32/lib/device_debug/', 'esp32/lib/gui/', 'esp32/lib/maps/')) for p in relevant):
        profiles.add('_REMOTE_DEBUG')
    if any(p.startswith(('esp32/lib/world_radio/', 'esp32/lib/gui/')) for p in relevant):
        profiles.update(('', '_REMOTE_DEBUG'))
    return tuple(t for t in full_targets if any(t.endswith(s) if s else t[-3:].isdigit() for s in profiles))


def ios_scopes(paths, *, native, selected):
    checks = json.loads((ROOT / 'tools/development/checks.json').read_text())['checks']
    fast = [c for c in checks if c['component'] == 'ios']
    if not selected:
        return {'ios_checks': [], 'ios_simulator': False, 'ios_release': False}
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
    if paths and all(p.endswith('.swift') and not p.startswith(shared) for p in paths):
        selected_checks.remove(watch_check)
    return {'ios_checks': selected_checks, 'ios_simulator': simulator, 'ios_release': release}
