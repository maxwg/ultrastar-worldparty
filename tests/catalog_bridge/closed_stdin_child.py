#!/usr/bin/env python3
"""Offline fixture: close stdin, remain alive, and perform no other work."""
import os
import sys
import time

if len(sys.argv) != 1:
    raise SystemExit('unexpected child arguments')
os.close(0)
# FPC 3.2.2's Unix TProcess leaves the source descriptor duplicated after
# dup2(…, 0). Close the duplicate too, while preserving stdout/stderr.
for descriptor in range(3, 64):
    try:
        os.close(descriptor)
    except OSError:
        pass
sys.stdout.write('stdin-closed\n')
sys.stdout.flush()
time.sleep(30)
