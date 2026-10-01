#!/usr/bin/env python3
"""Compile and execute portable diagnostics producer, protocol, and broker tests."""
from __future__ import annotations
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(arguments: list[str]) -> None:
    print('+ ' + ' '.join(arguments), flush=True)
    subprocess.run(arguments, cwd=ROOT, check=True)

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-swift', action='store_true')
    parser.add_argument('--sanitizers', action='store_true')
    args = parser.parse_args()
    run([sys.executable, 'tools/generate_diagnostics_contract.py', '--check'])
    run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tools/tests'])
    compiler = shutil.which('c++')
    if compiler is None:
        raise SystemExit('C++ compiler is required')
    with tempfile.TemporaryDirectory(prefix='bicino-diagnostics-tests-') as temporary:
        for source in sorted((ROOT / 'esp32/tools/tests').glob('test_diagnostics_*.cpp')):
            executable = Path(temporary) / source.stem
            flags = ['-std=c++17', '-Wall', '-Wextra', '-Werror', '-g']
            if args.sanitizers:
                flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
            run([compiler, *flags, str(source), '-o', str(executable)])
            run([str(executable)])
        swift = shutil.which('swiftc')
        if swift:
            utilities = ROOT / 'ios-app/BikeComputer/BikeComputer/Utilities'
            sources = [utilities / name for name in (
                'DiagnosticsContractV2.generated.swift', 'DiagnosticsCapturePolicyV2.swift',
                'DiagnosticsAcquisitionV2.swift', 'DiagnosticsBrokerEnrollmentV2.swift',
                'DiagnosticsLiveTailV2.swift',
            )]
            executable = Path(temporary) / 'swift-diagnostics'
            run([swift, '-parse-as-library', *(str(path) for path in sources),
                 'ios-app/BikeComputerTests/DiagnosticsPolicyV2Tests.swift', '-o', str(executable)])
            run([str(executable)])
        elif args.require_swift:
            raise SystemExit('Swift compiler is required for this gate')
        else:
            print('UNVERIFIED: Swift compiler is unavailable', flush=True)
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
