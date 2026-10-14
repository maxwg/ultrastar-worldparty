"""Exercise production owner inside a separate, test-only watchdog Job.

Exact process handles are retained before release and observed immediately after
the production call returns, while this worker and its outer Job remain alive.
"""
from dataclasses import asdict
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
from pathlib import Path
import sys
import threading
import time
import traceback

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import owned_process as owner

K = C.WinDLL('kernel32', use_last_error=True)
K.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
K.OpenProcess.restype = W.HANDLE
K.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
K.WaitForSingleObject.restype = W.DWORD
K.CloseHandle.argtypes = [W.HANDLE]
K.CloseHandle.restype = W.BOOL
K.GetCurrentProcess.restype = W.HANDLE
K.GetProcessHandleCount.argtypes = [W.HANDLE, C.POINTER(W.DWORD)]
K.GetProcessHandleCount.restype = W.BOOL

def count_handles():
    count = W.DWORD()
    if not K.GetProcessHandleCount(K.GetCurrentProcess(), C.byref(count)):
        raise C.WinError(C.get_last_error())
    return count.value

def wait_file(path, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            value = path.read_text(encoding='ascii').strip()
            if value:
                return value
        time.sleep(.005)
    raise TimeoutError(str(path))

config = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
root = Path(config['directory'])
case = config['case']
record = {'case': case, 'assertions': [], 'processes': []}
handles = []

def check(condition, description):
    record['assertions'].append({'passed': bool(condition), 'description': description})
    if not condition:
        raise AssertionError(description)

try:
    if case == 'handle_count':
        args = [sys.executable, str(HERE / 'capture_fixture.py'), 'quick', str(root)]
        warmup = owner.run_owned(args, cwd=str(root), timeout=2, stdout='capture')
        check(warmup.stdout == 'quick', 'warmup capture is complete')
        before = count_handles()
        for _ in range(24):
            result = owner.run_owned(args, cwd=str(root), timeout=2, stdout='capture')
            check(result.reason == 'exited' and result.stdout == 'quick',
                  'repeated capture exits with exact output')
        after = count_handles()
        record['handle_counts'] = {'before': before, 'after': after, 'runs': 24}
        check(after == before, 'capture leaks no process handles across 24 calls')
    else:
        mode = config['mode']
        args = [sys.executable, str(HERE / 'capture_fixture.py'), mode, str(root)]
        if 'bytes' in config:
            args.append(str(config['bytes']))
        cancel = threading.Event()
        box = {}
        def run():
            try:
                box['result'] = owner.run_owned(
                    args, cwd=str(root), timeout=config.get('timeout', 3),
                    stdout='capture', cancel=cancel, cleanup_timeout=2,
                    max_output_bytes=config.get('cap', 65536))
            except BaseException:
                box['error'] = traceback.format_exc()
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        roles = ['root']
        if mode.endswith('_pipe'):
            roles.append('child')
        for role in roles:
            pid = int(wait_file(root / (role + '.pid')))
            handle = K.OpenProcess(0x00100000, False, pid)
            if not handle:
                raise C.WinError(C.get_last_error())
            handles.append(handle)
            before = K.WaitForSingleObject(handle, 0)
            record['processes'].append({'role': role, 'pid': pid, 'before': before})
            check(before == 258, role + ' exact retained handle is live before release')
        (root / 'release').write_text('release', encoding='ascii')
        if mode == 'cancel_pipe':
            time.sleep(.1)
            cancel.set()
        thread.join(6)
        check(not thread.is_alive(), 'production owner returns within six-second harness bound')
        if 'error' in box:
            raise RuntimeError(box['error'])
        result = box['result']
        record['result'] = asdict(result)
        check(isinstance(result.stdout, str), 'captured stdout is str')
        for item, handle in zip(record['processes'], handles):
            item['after_production_return_before_outer_cleanup'] = K.WaitForSingleObject(handle, 0)
        for item, handle in zip(record['processes'], handles):
            if item['after_production_return_before_outer_cleanup'] != 0:
                signal_started = time.monotonic()
                item['after_bounded_signal_wait_before_outer_cleanup'] = K.WaitForSingleObject(handle, 1000)
                item['signal_wait_seconds'] = time.monotonic() - signal_started
        for item, handle in zip(record['processes'], handles):
            check(item['after_production_return_before_outer_cleanup'] == 0,
                  item['role'] + ' signaled before test-only outer cleanup')
        check(result.reason == config['expected_reason'], 'result reason matches expectation')
        check(result.stdout == config['expected_stdout'], 'captured content has exact expected bound')
        check(result.elapsed_seconds < config.get('elapsed_limit', 2.5), 'bounded elapsed duration')
        if case == 'short_timeout_pipe':
            check(result.elapsed_seconds >= config['timeout'], 'actual timeout duration elapsed')
        if result.reason == 'exited':
            check(result.returncode == 0, 'normal exit preserves zero return code')
    record['status'] = 'passed'
except BaseException:
    record['status'] = 'failed'
    record['traceback'] = traceback.format_exc()
finally:
    for handle in handles:
        K.CloseHandle(handle)
    record['owner_sha256'] = hashlib.sha256((HERE.parent / 'owned_process.py').read_bytes()).hexdigest()
    (root / 'result.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    # Keep this process and the test-only outer Job alive for boundary observation.
    deadline = time.monotonic() + 5
    while not (root / 'acknowledge').exists() and time.monotonic() < deadline:
        time.sleep(.005)
