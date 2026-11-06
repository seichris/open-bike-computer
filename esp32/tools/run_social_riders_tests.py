#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='bicino-social-host-') as directory:
    for diagnostics in (0, 1):
        binary=pathlib.Path(directory)/f'test-social-{diagnostics}'
        subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',
                        f'-DFIRMWARE_DIAGNOSTICS={diagnostics}',
                        str(root/'tools/tests/test_social_riders.cpp'),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
