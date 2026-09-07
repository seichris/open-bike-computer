#!/usr/bin/env python3
"""Compile the actual Watch adapter against explicitly host-only boundary doubles.

No source rewrite changes adapter behavior. A same-file test extension provides
fixture/inspection access to private members; all tested actions call production
entry points. Pure queue/demand/ACK types are extracted from production source,
not maintained as a second implementation.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parents[2]
TYPES = '''WatchDirectBLEProtocolV1 WatchDeviceCapabilitiesV1
RideBLEApplicationCommandEnvelopeV1 RideBLEApplicationAcknowledgementV1
RideBLEApplicationPendingIdentityV1 RideBLEApplicationAcknowledgementDispositionV1
RideBLEApplicationAcknowledgementPolicyV1 RideBLEApplicationTimeoutActionV1
RideBLEApplicationRetryPolicyV1 WatchNavigationNotificationV1
WatchBLEOutboundTargetV1 WatchBLEOutboundProtectionV1
WatchRideAutomationTransportPayloadV1 WatchRideAutomationTransportV1
WatchRideDemandStateV1 WatchBLEOutboundWriteV1 RideBLECommandPriorityV1
RideBLECommandDispositionV1 WatchBLETransportDiagnosticKindV1
WatchBLETransportDiagnosticEventV1 WatchBLEOutboundGroupV1 WatchBLEGroupAdmissionV1
WatchBLEOutboundQueueMetricsV1 WatchBLEOutboundQueueV1'''.split()

PREPARATION_TYPES = 'WatchControllerContractError WatchDirectRidePreparationOperationV1 WatchDirectRidePreparationSubmissionDispositionV1 WatchDirectRidePreparationIntentV1 WatchDirectRidePreparationRetryPolicyV1 WatchDirectRidePreparationRequestV1 WatchDirectRidePreparationResponseV1 WatchDirectRidePreparationPolicyV1 WatchDirectRidePreparationRestorationDecisionV1 WatchDirectRidePreparationRestorationGateV1'.split()

def declaration(text: str, name: str) -> str:
    # These selected declarations have balanced braces, including interpolations.
    match = re.search(r'^(?:struct|enum) ' + re.escape(name) + r'\b[^{}]*\{', text, re.M)
    if match is None:
        raise ValueError(f'Production declaration is missing: {name}')
    depth = 1
    offset = match.end()
    while depth:
        if offset == len(text):
            raise ValueError(f'Unbalanced declaration: {name}')
        depth += (text[offset] == '{') - (text[offset] == '}')
        offset += 1
    return text[match.start():offset]

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=DEFAULT_ROOT)
    parser.add_argument('--contract-source', type=Path)
    parser.add_argument('--generated-source', type=Path)
    parser.add_argument('--preparation-source', type=Path)
    parser.add_argument('--repeat', type=int, default=1, help='Repeat execution without recompiling.')
    parser.add_argument('--baseline', action='store_true', help='Run unchanged baseline with fixed expectations; nonzero is expected.')
    args = parser.parse_args()
    if not 1 <= args.repeat <= 100:
        parser.error('--repeat must be between 1 and 100.')
    swift = shutil.which('swiftc')
    if not swift:
        parser.error('swiftc is required (Swift 6 toolchain).')
    shared = args.source_root / 'ios-app/BikeComputer/RideShared'
    contract = args.contract_source or shared / 'WatchDirectBLEContract.swift'
    preparation = args.preparation_source or shared / 'WatchControllerContract.swift'
    generated = args.generated_source or shared / 'RideBLEProtocol.generated.swift'
    adapter = args.source_root / 'ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift'
    with tempfile.TemporaryDirectory(prefix='watch-link-host-') as temporary:
        build = Path(temporary)
        extension = '.dylib' if os.uname().sysname == 'Darwin' else '.so'
        for name in ('Combine', 'CoreBluetooth', 'Security'):
            subprocess.run([swift, '-swift-version', '5', '-emit-library', '-emit-module',
                            '-module-name', name, str(HERE / f'{name}.swift'),
                            '-emit-module-path', str(build / f'{name}.swiftmodule'),
                            '-o', str(build / f'lib{name}{extension}')], check=True)
        pure = build / 'ProductionContracts.swift'
        pure.write_text('import Foundation\ntypealias WatchAuthenticatedBLEChannelV1 = RideBLEGeneratedProtectedChannelV1\n' +
                        '\n\n'.join(declaration(contract.read_text(), name) for name in TYPES) + '\n\n' +
                        '\n\n'.join(declaration(preparation.read_text(), name) for name in PREPARATION_TYPES))
        fixture = build / 'WatchDeviceLink.swift'
        fixture.write_text(adapter.read_text() + '\n' + (HERE / 'AdapterFixture.swift.inc').read_text())
        executable = build / 'watch-link-tests'
        command = [swift, '-swift-version', '5', '-parse-as-library', '-I', str(build), '-L', str(build),
                   '-Xlinker', '-rpath', '-Xlinker', str(build),
                   '-lCombine', '-lCoreBluetooth', '-lSecurity']
        if not args.baseline:
            command += ['-D', 'FIXED_LIFECYCLE']
        command += [str(generated), str(pure), str(shared / 'RideBLETransportStateMachine.swift'),
                    str(HERE / 'BoundaryDoubles.swift'), str(HERE / 'ManualClock.swift'),
                    str(fixture), str(HERE / 'Tests.swift'), '-o', str(executable)]
        subprocess.run(command, check=True)
        for iteration in range(args.repeat):
            if args.repeat > 1:
                print(f'Execution {iteration + 1}/{args.repeat}', flush=True)
            result = subprocess.run([str(executable)])
            if result.returncode:
                return result.returncode
        return 0

if __name__ == '__main__':
    raise SystemExit(main())
