#!/usr/bin/env python3
"""Skip a scheduled sweep only after an unchanged, successful comparable run."""
import re
import subprocess
import sys


def changed(previous, current='HEAD'):
    if not re.fullmatch(r'[a-f0-9]{40}', previous):
        return True
    try:
        # Entire source/tool/CI trees: unknown new inputs in these trees invalidate reuse.
        result = subprocess.run(['git', 'diff', '--quiet', previous, current, '--',
                                 'esp32', 'tools', 'protocol', 'map-platform', '.github'], check=False)
        return result.returncode != 0
    except OSError:
        return True


if __name__ == '__main__':
    print('run='+str(changed(sys.argv[1] if len(sys.argv)>1 else '')).lower())
