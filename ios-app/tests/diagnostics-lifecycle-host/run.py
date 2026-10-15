#!/usr/bin/env python3
"""Execute actual app orchestration methods with host boundary doubles."""
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

def section(source, start, stop):
    return source[source.index(start):source.index(stop, source.index(start))]

def declaration(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def other_regressions(directory):
    shared = (ROOT/'ios-app/BikeComputer/RideShared/WatchDirectBLEContract.swift').read_text()
    watch = (ROOT/'ios-app/BikeComputer/BikeComputerWatch/Managers/WatchConnectivityCoordinator.swift').read_text()
    phone = (ROOT/'ios-app/BikeComputer/BikeComputer/Managers/PhoneWatchConnectivityCoordinator.swift').read_text()
    fixture = (HERE/'WatchLoss.swift.inc').read_text()
    types = '\n'.join(declaration(shared, signature) for signature in (
        'enum WatchBLETransportDiagnosticKindV1:', 'struct WatchBLETransportDiagnosticEventV1:', 'struct WatchBLETransportDiagnosticBatchV1:'))
    fixture = fixture.replace('// SHARED_TYPES', types)
    methods = declaration(watch, '    func recordTransportDiagnostic(') + '\n' + declaration(watch, '    private func mergePendingTransportDiagnostics(')
    fixture = fixture.replace('// WATCH_METHODS', methods.replace('private func', 'func'))
    fixture = fixture.replace('// PHONE_METHOD', declaration(phone, '    private func receiveTransportDiagnostics(').replace('private func', 'func'))
    checkpoint = (ROOT/'ios-app/BikeComputer/BikeComputer/Managers/WorkoutMirrorManager.swift').read_text()
    checkpoint = (HERE/'Checkpoint.swift.inc').read_text().replace('// CHECKPOINT_METHOD', declaration(checkpoint,
        '    private func recordMirrorDebugCheckpoint(').replace('private func', 'func'))
    for name, text in (('watch', fixture), ('checkpoint', checkpoint)):
        source, binary = directory/(name+'.swift'), directory/name
        source.write_text(text)
        subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)

def main():
    client = (ROOT/'ios-app/BikeComputer/BikeComputer/Managers/DiagnosticsBrokerClient.swift').read_text()
    coordinator = (ROOT/'ios-app/BikeComputer/BikeComputer/Managers/DiagnosticsCollectionCoordinator.swift').read_text()
    methods = section(client, '    func configure(', '    func pair(')
    methods += section(client, '    private func recipientRoot(', '    private func uploadPending(')
    # The pairing protocol itself is covered by production contract/TLS tests;
    # this substitute removes only platform networking/Keychain dependencies.
    methods = methods.replace('DiagnosticsBrokerPairing', 'DiagnosticsBrokerPairingFixture').replace('private func', 'func')
    fixture = (HERE/'Handoff.swift.inc').read_text().replace('// CLIENT_METHODS', methods)
    fixture = fixture.replace('// COORDINATOR_DELETE', section(coordinator, '    func deleteRetainedDiagnostics(', '    func cancel('))
    with tempfile.TemporaryDirectory(prefix='diagnostics-lifecycle-host-') as directory:
        directory = Path(directory)
        source, binary = directory/'main.swift', directory/'handoff'
        source.write_text(fixture)
        subprocess.run(['python3', str(ROOT/'tools/development/swift_compile.py'), 'diagnostics-broker-contracts', '--',
            '-parse-as-library', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
        other_regressions(directory)

if __name__ == '__main__':
    main()
