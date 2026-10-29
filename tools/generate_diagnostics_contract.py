#!/usr/bin/env python3
"""Generate the reviewed diagnostics vocabulary for firmware, iOS and host.

The v2 registry deliberately preserves the v1 event encoding. New producers
can evolve independently of immutable historical bundles. Only this registry
may widen the persisted privacy vocabulary; run --check in every CI route.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / 'protocol/diagnostics/registry-v2.json'


def load_registry() -> dict:
    value = json.loads(REGISTRY.read_text(encoding='utf-8'))
    if value['schema'] != 2 or value['eventFormatSchema'] != 1:
        raise ValueError('unsupported diagnostics registry')
    if value.get('protocols') != {'issueMarker': 2}:
        raise ValueError('unsupported diagnostics marker protocol')
    fields = value['fields']
    if len(value['domains']) > 32 or len(set(value['domains'])) != len(value['domains']):
        raise ValueError('invalid domain bit registry')
    if set(value['instrumentedDomains']) - set(value['domains']):
        raise ValueError('unknown instrumented domain')
    for name, spec in fields.items():
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9]{0,63}', name):
            raise ValueError(f'invalid field name: {name}')
        if spec['firmwareType'] not in ('number', 'boolean', 'string'):
            raise ValueError(f'invalid scalar type: {name}')
        if spec['iosType'] != 'string' or spec['privacy'] != 'diagnostic':
            raise ValueError(f'v1 encoding/privacy changed: {name}')
        if spec['maxBytes'] != 256:
            raise ValueError(f'unreviewed string bound: {name}')
    for name, event in value['events'].items():
        domain, _, code = name.partition('.')
        if domain not in value['domains'] or not re.fullmatch(r'[a-z0-9_]+', code):
            raise ValueError(f'invalid event: {name}')
        if event['level'] not in value['levels']:
            raise ValueError(f'invalid level: {name}')
        if (set(event['required']) | set(event['optional'])) - fields.keys():
            raise ValueError(f'unknown event fields: {name}')
        if set(event['required']) & set(event['optional']):
            raise ValueError(f'duplicate event fields: {name}')
    return value


def quoted_lines(names: list[str], indent: str = '    ') -> str:
    return ''.join(indent + ', '.join(json.dumps(n) for n in names[i:i + 4]) + ',\n'
                   for i in range(0, len(names), 4))


def replace_region(text: str, label: str, body: str) -> str:
    pattern = rf'((?:#|//) BEGIN GENERATED DIAGNOSTICS {label}\n).*?((?:#|//) END GENERATED DIAGNOSTICS {label}\n)'
    result, count = re.subn(pattern, lambda m: m[1] + body + m[2], text, flags=re.S)
    if count != 1:
        raise ValueError(f'expected one generated region: {label}')
    return result


def generated(registry: dict) -> dict[Path, str]:
    keys = sorted(registry['fields'])
    numbers = [n for n in keys if registry['fields'][n]['firmwareType'] == 'number']
    booleans = [n for n in keys if registry['fields'][n]['firmwareType'] == 'boolean']
    result: dict[Path, str] = {}
    p = ROOT / 'tools/ride_diagnostics.py'
    body = ''.join(f'{name} = {{\n' + quoted_lines(values) + '}\n' for name, values in (
        ('ALLOWED_FIELD_KEYS', keys), ('FIRMWARE_NUMBER_FIELD_KEYS', numbers),
        ('FIRMWARE_BOOLEAN_FIELD_KEYS', booleans)))
    text = replace_region(p.read_text(), 'FIELDS', body)
    text = re.sub(r'ALLOWED_LEVELS = \{[^}]*\}', 'ALLOWED_LEVELS = {' + ', '.join(repr(x) for x in registry['levels']) + '}', text)
    text = re.sub(r'ALLOWED_CATEGORIES = \{[^}]*\}', 'ALLOWED_CATEGORIES = {\n' + quoted_lines(registry['domains']) + '}', text)
    result[p] = text
    p = ROOT / 'ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift'
    body = ''.join(f'    static let {name}: Set<String> = [\n' + quoted_lines(values, '        ') + '    ]\n' for name, values in (
        ('allowedKeys', keys), ('firmwareNumberKeys', numbers), ('firmwareBooleanKeys', booleans)))
    text = replace_region(p.read_text(), 'FIELDS', body)
    for name, values in [('RideDiagnosticLevel', registry['levels']), ('RideDiagnosticCategory', registry['domains'])]:
        text = re.sub(r'(nonisolated enum ' + name + r': String, Codable, CaseIterable \{).*?\n\}',
            lambda m: m[1] + '\n' + ''.join('    case ' + x + '\n' for x in values) + '}', text, flags=re.S)
    result[p] = text
    p = ROOT / 'esp32/lib/ride_diagnostics/ride_diagnostics_format.hpp'
    text = replace_region(p.read_text(), 'ALLOWED_FIELDS',
                         'constexpr const char *kAllowedFieldKeys[] = {\n' + quoted_lines(keys) + '};\n\n')
    body = ''.join(f'  static constexpr const char *{name}[] = {{\n' + quoted_lines(values, '      ') + '  };\n' for name, values in (
        ('kNumberKeys', numbers), ('kBooleanKeys', booleans)))
    result[p] = replace_region(text, 'FIELD_TYPES', body)
    digest = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    domains = registry['domains']
    mask = sum(1 << domains.index(n) for n in registry['instrumentedDomains'])
    result[ROOT / 'esp32/lib/ride_diagnostics/diagnostics_registry_identity.hpp'] = (
        '// Generated by tools/generate_diagnostics_contract.py. Do not edit.\n'
        '#pragma once\n#include <cstddef>\n#include <cstdint>\n#include <cstring>\n'
        'namespace ride_diagnostics::registry {\n'
        f'inline constexpr const char *kSha256 = "{digest}";\n'
        'inline constexpr unsigned kSchema = 2;\n'
        f'inline constexpr uint32_t kInstrumentedMask = {mask}U;\n'
        'inline constexpr const char *kDomains[] = {\n' + quoted_lines(domains) + '};\n'
        'inline uint32_t domainMask(const char *name) {\n'
        '  if (name == nullptr) return 0;\n'
        '  for (std::size_t i=0; i<sizeof(kDomains)/sizeof(kDomains[0]); ++i)\n'
        '    if (std::strcmp(name, kDomains[i]) == 0) return uint32_t(1) << i;\n'
        '  return 0;\n}\n}\n')
    result[ROOT / 'ios-app/BikeComputer/BikeComputer/Utilities/DiagnosticsSchema.generated.swift'] = (
        '// Generated by tools/generate_diagnostics_contract.py. Do not edit.\n'
        'import Foundation\nnonisolated enum DiagnosticsSchema {\n'
        '    static let registryVersion = 2\n'
        f'    static let digest = "{digest}"\n'
        f'    static let instrumentedMask: UInt32 = {mask}\n'
        '    static let domains: [String] = [\n' + quoted_lines(domains, '        ') + '    ]\n'
        '    static let levels: [String] = [\n' + quoted_lines(registry['levels'], '        ') + '    ]\n'
        '    static func mask(for domain: String) -> UInt32 {\n'
        '        guard let index = domains.firstIndex(of: domain) else { return 0 }\n'
        '        return UInt32(1) << index\n    }\n}\n')
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    changed = []
    for path, text in generated(load_registry()).items():
        if not path.exists() or path.read_text(encoding='utf-8') != text:
            changed.append(str(path.relative_to(ROOT)))
            if not args.check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding='utf-8')
    if args.check and changed:
        print('Stale diagnostics contract: ' + ', '.join(changed))
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
