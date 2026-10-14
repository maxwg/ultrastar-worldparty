"""Local inert fixtures. Every invocation is launched in a test-owned Job."""
import os
from pathlib import Path
import subprocess
import sys
import time

mode, directory = sys.argv[1:3]
root = Path(directory)
root.mkdir(parents=True, exist_ok=True)
if mode == 'child':
    (root / 'child.pid').write_text(str(os.getpid()), encoding='ascii')
    time.sleep(30)
    raise SystemExit(0)
if mode == 'quick':
    os.write(1, b'quick')
    raise SystemExit(0)
(root / 'root.pid').write_text(str(os.getpid()), encoding='ascii')
if mode == 'sentinel':
    deadline = time.monotonic() + 60
    while not (root / 'stop').exists() and time.monotonic() < deadline:
        time.sleep(.01)
    raise SystemExit(0)
if mode in ('cancel_pipe', 'timeout_pipe', 'exit_pipe'):
    subprocess.Popen([sys.executable, __file__, 'child', str(root)],
                     stdin=subprocess.DEVNULL, stdout=sys.stdout,
                     stderr=sys.stderr, close_fds=False,
                     creationflags=subprocess.CREATE_NO_WINDOW)
deadline = time.monotonic() + 10
while not (root / 'release').exists():
    if time.monotonic() > deadline:
        raise SystemExit(19)
    time.sleep(.005)
if mode == 'exact':
    os.write(1, b'X' * int(sys.argv[3]))
elif mode == 'flood':
    while True:
        os.write(1, b'F' * 65536)
elif mode == 'exit_pipe':
    os.write(1, b'{"streams":[{"codec_type":"audio"}]}')
elif mode in ('cancel_pipe', 'timeout_pipe'):
    os.write(1, b'prefix')
    time.sleep(30)
elif mode == 'invalid_utf8':
    os.write(1, b'\xff\xfeA')
else:
    raise SystemExit('unknown fixture mode')
