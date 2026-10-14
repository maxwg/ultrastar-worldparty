"""Negative-control fixture: reports return with a deliberately live child.

No backend is loaded here. The unchanged installer boundary must reject it
before its independent outer Job watchdog is allowed to clean that child.
"""
import json
from pathlib import Path
import subprocess
import sys
import time

case = Path(sys.argv[1]).resolve(strict=True)
child = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c', 'import time; time.sleep(30)'],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, creationflags=subprocess.DETACHED_PROCESS)
(case / 'tools/guard_child.pid').write_text(str(child.pid), encoding='ascii')
deadline = time.monotonic() + 8
while not (case / 'allow_return').exists():
    if time.monotonic() >= deadline:
        raise TimeoutError('Controller did not acknowledge the exact child handle')
    time.sleep(.01)
(case / 'result.json').write_text(json.dumps({'status': 'synthetic_bad_worker',
    'scope': 'negative control only; deliberately leaves child alive'}), encoding='utf-8')
(case / 'runner_returned').write_text('negative control returned', encoding='ascii')
while not (case / 'acknowledge').exists():
    if time.monotonic() >= deadline:
        raise TimeoutError('Controller did not release the negative control')
    time.sleep(.01)
