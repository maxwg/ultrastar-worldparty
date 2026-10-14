"""Bounded offline accounting-error regressions with independent live sentinel."""
from dataclasses import asdict
import ctypes as C
from ctypes import wintypes as W
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import threading
import time
import traceback
import uuid

HERE = Path(__file__).resolve().parent
OWNER = HERE.parent.parent / 'owned_process.py'
OUTER = HERE.parent.parent / 'before-repair-20261014' / 'owned_process.py'
spec = importlib.util.spec_from_file_location('accounting_outer_owner', OUTER)
outer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = outer
spec.loader.exec_module(outer)
RUN = HERE / ('run-' + uuid.uuid4().hex[:12])
RUN.mkdir()
K = C.WinDLL('kernel32', use_last_error=True)
K.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
K.OpenProcess.restype = W.HANDLE
K.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
K.WaitForSingleObject.restype = W.DWORD
K.CloseHandle.argtypes = [W.HANDLE]
K.CloseHandle.restype = W.BOOL

def launch(args, directory, timeout):
    box = {}
    def run():
        try:
            box['result'] = asdict(outer.run_owned(args, cwd=str(directory), timeout=timeout))
        except BaseException:
            box['error'] = traceback.format_exc()
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread, box

def wait_file(path, thread, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            try:
                value = path.read_text(encoding='utf-8').strip()
                if value:
                    return value
            except PermissionError:
                pass  # Test-only marker retry remains inside this deadline.
        if not thread.is_alive():
            raise RuntimeError('outer harness exited before result')
        time.sleep(.005)
    raise TimeoutError(str(path))

paths = (OWNER, OUTER, HERE.parent / 'capture_fixture.py', HERE / 'accounting_worker.py',
         Path(__file__).resolve(), HERE / 'burst_fixture.c', HERE / 'burst_fixture.exe', HERE / 'build_burst.cmd')
receipt = {'scope': 'narrow labeled fault injection and actual inert native short-lived descendants',
           'source_hashes': {str(path.relative_to(HERE.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths},
           'cases': [], 'run_directory': str(RUN)}
sentinel = RUN / 'sentinel'
sentinel.mkdir()
thread_s, box_s = launch([sys.executable, str(HERE.parent / 'capture_fixture.py'), 'sentinel', str(sentinel)], sentinel, 60)
handle_s = None
started = time.monotonic()
try:
    pid_s = int(wait_file(sentinel / 'root.pid', thread_s))
    handle_s = K.OpenProcess(0x00100000, False, pid_s)
    if not handle_s:
        raise C.WinError(C.get_last_error())
    receipt['sentinel'] = {'pid': pid_s, 'before': K.WaitForSingleObject(handle_s, 0)}
    for mode in ('accounting_mismatch', 'enumeration_failure', 'actual_short_lived_descendants'):
        root = RUN / mode
        root.mkdir()
        thread, box = launch([sys.executable, str(HERE / 'accounting_worker.py'), str(root), mode], root, 20)
        try:
            record = json.loads(wait_file(root / 'result.json', thread, 17))
            record['outer_alive_at_result'] = thread.is_alive()
            record['sentinel_wait_at_result'] = K.WaitForSingleObject(handle_s, 0)
            if not record['outer_alive_at_result'] or record['sentinel_wait_at_result'] != 258:
                record['status'] = 'failed'
                record['boundary_error'] = 'outer ended early or unrelated sentinel died'
        except BaseException:
            record = {'mode': mode, 'status': 'failed', 'traceback': traceback.format_exc()}
        finally:
            (root / 'acknowledge').write_text('acknowledged', encoding='ascii')
            thread.join(4)
        record['outer'] = box
        if thread.is_alive() or box.get('result', {}).get('reason') != 'exited':
            record['status'] = 'failed'
            record['watchdog_error'] = 'outer test watchdog did not exit normally'
        receipt['cases'].append(record)
        print(mode + ': ' + record['status'], flush=True)
    receipt['sentinel']['after'] = K.WaitForSingleObject(handle_s, 0)
finally:
    (sentinel / 'stop').write_text('stop', encoding='ascii')
    thread_s.join(4)
    if handle_s:
        K.CloseHandle(handle_s)
    receipt['sentinel_outer'] = box_s
    receipt['owner_unchanged'] = hashlib.sha256(OWNER.read_bytes()).hexdigest() == receipt['source_hashes']['owned_process.py']
    receipt['elapsed_seconds'] = time.monotonic() - started
    receipt['passed'] = sum(item['status'] == 'passed' for item in receipt['cases'])
    receipt['failed'] = sum(item['status'] != 'passed' for item in receipt['cases'])
    output = RUN / 'accounting-receipt.json'
    output.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(str(output), flush=True)
sys.exit(0 if receipt['failed'] == 0 and receipt['owner_unchanged'] and len(receipt['cases']) == 3 else 1)
