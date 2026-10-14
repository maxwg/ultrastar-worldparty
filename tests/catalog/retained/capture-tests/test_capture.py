"""Bounded offline capture regressions; never invokes installed applications."""
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
OWNER = HERE.parent / 'owned_process.py'
OUTER = HERE.parent / 'before-repair-20261014' / 'owned_process.py'
spec = importlib.util.spec_from_file_location('test_outer_owner', OUTER)
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

def owned_thread(args, directory, timeout):
    box = {}
    def run():
        try:
            box['result'] = asdict(outer.run_owned(args, cwd=str(directory), timeout=timeout))
        except BaseException:
            box['error'] = traceback.format_exc()
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread, box

def wait_file(path, thread, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            try:
                return path.read_text(encoding='utf-8')
            except PermissionError:
                pass
        if not thread.is_alive():
            raise RuntimeError('outer harness exited before result')
        time.sleep(.01)
    raise TimeoutError(str(path))

hashes = {str(path.relative_to(HERE.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
          for path in (OWNER, OUTER, HERE / 'capture_fixture.py', HERE / 'capture_worker.py', Path(__file__).resolve())}
receipt = {'scope': 'offline inert synthetic capture fixtures only', 'source_hashes': hashes,
           'cases': [], 'run_directory': str(RUN)}
sentinel = RUN / 'unrelated-sentinel'
sentinel.mkdir()
sentinel_thread, sentinel_box = owned_thread(
    [sys.executable, str(HERE / 'capture_fixture.py'), 'sentinel', str(sentinel)], sentinel, 60)
sentinel_handle = None
started = time.monotonic()
try:
    sentinel_pid = int(wait_file(sentinel / 'root.pid', sentinel_thread))
    sentinel_handle = K.OpenProcess(0x00100000, False, sentinel_pid)
    if not sentinel_handle:
        raise C.WinError(C.get_last_error())
    receipt['sentinel'] = {'pid': sentinel_pid, 'before': K.WaitForSingleObject(sentinel_handle, 0)}
    cases = [
        {'case': 'exact_cap', 'mode': 'exact', 'cap': 65536, 'bytes': 65536,
         'expected_reason': 'exited', 'expected_stdout': 'X' * 65536},
        {'case': 'cap_plus_one', 'mode': 'exact', 'cap': 65536, 'bytes': 65537,
         'expected_reason': 'output_limit', 'expected_stdout': 'X' * 65536},
        {'case': 'continuous_flood', 'mode': 'flood', 'cap': 65536,
         'expected_reason': 'output_limit', 'expected_stdout': 'F' * 65536},
        {'case': 'cancel_descendant_pipe', 'mode': 'cancel_pipe',
         'expected_reason': 'cancelled', 'expected_stdout': 'prefix'},
        {'case': 'short_timeout_pipe', 'mode': 'timeout_pipe', 'timeout': .8,
         'expected_reason': 'timeout', 'expected_stdout': 'prefix'},
        {'case': 'parent_exit_descendant_pipe', 'mode': 'exit_pipe',
         'expected_reason': 'exited', 'expected_stdout': '{"streams":[{"codec_type":"audio"}]}'},
        {'case': 'invalid_utf8_is_string', 'mode': 'invalid_utf8',
         'expected_reason': 'exited', 'expected_stdout': '\ufffd\ufffdA'},
        {'case': 'handle_count'},
    ]
    for config in cases:
        root = RUN / config['case']
        root.mkdir()
        config['directory'] = str(root)
        config_path = root / 'config.json'
        config_path.write_text(json.dumps(config), encoding='utf-8')
        thread, box = owned_thread([sys.executable, str(HERE / 'capture_worker.py'), str(config_path)], root, 12)
        try:
            raw = wait_file(root / 'result.json', thread, 10)
            # File publication is non-atomic, so one bounded parse retry is allowed.
            try:
                record = json.loads(raw)
            except json.JSONDecodeError:
                time.sleep(.02)
                record = json.loads((root / 'result.json').read_text(encoding='utf-8'))
            record['outer_alive_at_result'] = thread.is_alive()
            record['sentinel_wait_at_result'] = K.WaitForSingleObject(sentinel_handle, 0)
            if not record['outer_alive_at_result'] or record['sentinel_wait_at_result'] != 258:
                record['status'] = 'failed'
                record['boundary_error'] = 'outer harness ended early or unrelated sentinel died'
        except BaseException:
            record = {'case': config['case'], 'status': 'failed', 'traceback': traceback.format_exc()}
        finally:
            (root / 'acknowledge').write_text('acknowledged', encoding='ascii')
            thread.join(4)
        record['outer'] = box
        if thread.is_alive() or box.get('result', {}).get('reason') != 'exited':
            record['status'] = 'failed'
            record['watchdog_error'] = 'test-only outer Job did not exit normally'
        # Preserve complete worker result locally; keep receipt compact and exact.
        if 'result' in record:
            captured = record['result'].pop('stdout')
            record['result']['stdout_characters'] = len(captured)
            record['result']['stdout_sha256_utf8'] = hashlib.sha256(captured.encode('utf-8')).hexdigest()
        receipt['cases'].append(record)
        print(config['case'] + ': ' + record['status'], flush=True)
    receipt['sentinel']['after'] = K.WaitForSingleObject(sentinel_handle, 0)
finally:
    (sentinel / 'stop').write_text('stop', encoding='ascii')
    sentinel_thread.join(4)
    if sentinel_handle:
        K.CloseHandle(sentinel_handle)
    receipt['sentinel_owner'] = sentinel_box
    receipt['owner_unchanged'] = hashlib.sha256(OWNER.read_bytes()).hexdigest() == hashes['owned_process.py']
    receipt['elapsed_seconds'] = time.monotonic() - started
    receipt['passed'] = sum(x['status'] == 'passed' for x in receipt['cases'])
    receipt['failed'] = sum(x['status'] != 'passed' for x in receipt['cases'])
    path = RUN / 'capture-receipt.json'
    path.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(str(path), flush=True)
sys.exit(0 if receipt['failed'] == 0 and receipt['owner_unchanged'] and len(receipt['cases']) == 8 else 1)
