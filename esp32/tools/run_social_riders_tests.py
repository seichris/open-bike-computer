#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='bicino-social-host-') as directory:
    binary=pathlib.Path(directory)/'test-social'
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(root/'tools/tests/test_social_riders.cpp'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
