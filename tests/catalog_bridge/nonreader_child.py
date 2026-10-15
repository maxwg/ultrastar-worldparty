#!/usr/bin/env python3
"""Offline child-process fixture that deliberately never reads its stdin."""
import sys
import time

if len(sys.argv) != 1:
    raise SystemExit('unexpected child arguments')

time.sleep(60)
