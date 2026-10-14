"""Narrow labeled fault injection plus an unmodified-owner native burst case."""
import ctypes as C
from ctypes import wintypes as W
import gc
import hashlib
import json
from pathlib import Path
import sys
import threading
import time
import traceback

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent))
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
K.DuplicateHandle.argtypes = [W.HANDLE, W.HANDLE, W.HANDLE, C.POINTER(W.HANDLE), W.DWORD, W.BOOL, W.DWORD]
K.DuplicateHandle.restype = W.BOOL
K.GetProcessId.argtypes = [W.HANDLE]
K.GetProcessId.restype = W.DWORD

def count_handles():
    gc.collect()
    value = W.DWORD()
    if not K.GetProcessHandleCount(K.GetCurrentProcess(), C.byref(value)):
        raise C.WinError(C.get_last_error())
    return value.value

def wait_for(function, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = function()
        if result:
            return result
        time.sleep(.005)
    raise TimeoutError('bounded fixture coordination expired')

def read_when_present(path):
    try:
        return path.read_text(encoding='utf-8').strip()
    except (FileNotFoundError, PermissionError):
        # Synthetic marker publication can briefly retain a Windows share lock;
        # the enclosing wait_for deadline still bounds this test-only retry.
        return None

root, mode = Path(sys.argv[1]), sys.argv[2]
record = {'mode': mode, 'fault_injection': mode != 'actual_short_lived_descendants',
          'assertions': [], 'runs': [], 'owner_sha256': hashlib.sha256(Path(owner.__file__).read_bytes()).hexdigest()}

def check(condition, description):
    record['assertions'].append({'passed': bool(condition), 'description': description})
    if not condition:
        raise AssertionError(description)

originals = {name: getattr(owner, name) for name in ('_track_members', '_cleanup_job', '_stop_job', '_accounting')}
try:
    owner.run_owned([sys.executable, str(HERE.parent / 'capture_fixture.py'), 'quick', str(root)],
                    cwd=str(root), timeout=2, stdout='capture')
    warmup = threading.Thread(target=lambda: None)
    warmup.start(); warmup.join()
    baseline = count_handles()
    for index in range(3):
        directory = root / str(index + 1)
        directory.mkdir()
        item = {'index': index + 1, 'processes': [], 'injections': []}
        record['runs'].append(item)
        handles = []
        flags = {'ready': False, 'in_cleanup': False, 'stopped': False, 'injected': False, 'tracked': []}
        cancel = threading.Event()
        box = {}
        if mode != 'actual_short_lived_descendants':
            def track(job, tracked):
                if mode == 'enumeration_failure' and flags['ready'] and flags['in_cleanup'] and not flags['injected']:
                    flags['injected'] = True
                    item['injections'].append({'label': 'INJECTED one cleanup-time member enumeration exception',
                                               'tracked_pids': sorted(tracked),
                                               'exact_handle_states': [K.WaitForSingleObject(h, 0) for h in handles]})
                    raise OSError(1234, 'INJECTED member enumeration failure')
                originals['_track_members'](job, tracked)
                flags['tracked'] = sorted(tracked)
            def cleanup(job, tracked, timeout):
                flags['in_cleanup'] = True
                try:
                    return originals['_cleanup_job'](job, tracked, timeout)
                finally:
                    flags['in_cleanup'] = False
            def stop(job, timeout):
                answer = originals['_stop_job'](job, timeout)
                flags['stopped'] = True
                return answer
            def accounting(job):
                answer = originals['_accounting'](job)
                if mode == 'accounting_mismatch' and flags['ready'] and flags['in_cleanup'] and flags['stopped'] and not flags['injected']:
                    actual = answer.TotalProcesses
                    answer.TotalProcesses += 1
                    flags['injected'] = True
                    item['injections'].append({'label': 'INJECTED final TotalProcesses excess only',
                                               'actual_total': actual, 'injected_total': answer.TotalProcesses,
                                               'actual_active': answer.ActiveProcesses,
                                               'tracked_pids': flags['tracked'],
                                               'exact_handle_states': [K.WaitForSingleObject(h, 0) for h in handles]})
                return answer
            owner._track_members, owner._cleanup_job = track, cleanup
            owner._stop_job, owner._accounting = stop, accounting
            args = [sys.executable, str(HERE.parent / 'capture_fixture.py'), 'cancel_pipe', str(directory)]
        else:
            args = [str(HERE / 'burst_fixture.exe')]
        def run():
            began = time.monotonic()
            try:
                result = owner.run_owned(args, cwd=str(directory), timeout=5, stdout='capture', cancel=cancel, cleanup_timeout=2)
                box['unexpected_result'] = {'reason': result.reason, 'returncode': result.returncode}
            except BaseException as error:
                box['error_type'] = type(error).__name__
                box['error_message'] = str(error)
            finally:
                box['elapsed_seconds'] = time.monotonic() - began
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        try:
            roles = ('root',) if mode == 'actual_short_lived_descendants' else ('root', 'child')
            for role in roles:
                pid = int(wait_for(lambda: read_when_present(directory / (role + '.pid'))))
                access = 0x00101040 if mode == 'actual_short_lived_descendants' else 0x00100000
                handle = K.OpenProcess(access, False, pid)
                if not handle:
                    raise C.WinError(C.get_last_error())
                handles.append(handle)
                state = K.WaitForSingleObject(handle, 0)
                item['processes'].append({'role': role, 'pid': pid, 'before_release': state})
                check(state == 258, mode + ': exact ' + role + ' handle observed live')
            if mode == 'actual_short_lived_descendants':
                (directory / 'start').write_text('start', encoding='ascii')
                children = json.loads(wait_for(lambda: read_when_present(directory / 'burst.json')))
                check(len(children) == 32, 'native fixture created 32 actual short-lived descendants')
                for child in children:
                    duplicate = W.HANDLE()
                    if not K.DuplicateHandle(handles[0], child['handle'], K.GetCurrentProcess(), C.byref(duplicate), 0, False, 2):
                        raise C.WinError(C.get_last_error())
                    handles.append(duplicate.value)
                    check(K.GetProcessId(duplicate) == child['pid'], 'duplicated native retained handle identifies exact child PID')
                    state = K.WaitForSingleObject(duplicate, 0)
                    item['processes'].append({'role': 'short_child', 'pid': child['pid'], 'before_parent_release': state})
                    check(state == 0, 'native child already exited while production owner and fixture parent remain alive')
                check(K.WaitForSingleObject(handles[0], 0) == 258, 'native fixture parent alive before release')
                item['known_lifetime_process_count'] = 33
                item['production_monkeypatches'] = False
                (directory / 'release').write_text('release', encoding='ascii')
            else:
                expected_pids = {item['pid'] for item in item['processes']}
                wait_for(lambda: expected_pids.issubset(flags['tracked']))
                item['tracked_before_injection'] = flags['tracked'][:]
                flags['ready'] = True
                cancel.set()
            thread.join(7)
            check(not thread.is_alive(), mode + ': owner completes within bounded join')
            item.update(box)
            for entry, handle in zip(item['processes'], handles):
                entry['after_owner_raised_before_outer_cleanup'] = K.WaitForSingleObject(handle, 0)
            check(all(x['after_owner_raised_before_outer_cleanup'] == 0 for x in item['processes']),
                  mode + ': all exact retained fixture handles signal before outer cleanup')
            if mode == 'enumeration_failure':
                check(box.get('error_type') == 'OSError' and 'INJECTED member enumeration failure' in box.get('error_message', ''),
                      'cleanup preserves the injected enumeration error')
            elif mode == 'actual_short_lived_descendants':
                # Scheduler timing may let the owner observe every child.
                # Either verified exit or the precise conservative error is valid.
                missed = box.get('error_type') == 'RuntimeError' and 'unobserved process' in box.get('error_message', '')
                verified = box.get('unexpected_result') == {'reason': 'exited', 'returncode': 0}
                item['observed_outcome'] = 'missed_lifetime_failed_closed' if missed else 'all_lifetimes_verified_normal_exit'
                check(missed or verified, 'actual burst either verifies every lifetime or conservatively rejects a missed lifetime')
            else:
                check(box.get('error_type') == 'RuntimeError' and 'unobserved process' in box.get('error_message', ''),
                      mode + ': accounting mismatch fails closed with expected RuntimeError')
            if mode != 'actual_short_lived_descendants':
                check(len(item['injections']) == 1, 'exactly one narrow labeled fault was injected')
            check(box['elapsed_seconds'] < 4, 'fault/burst case completes in under four seconds')
        finally:
            for handle in handles:
                K.CloseHandle(handle)
            for name, function in originals.items():
                setattr(owner, name, function)
    after = count_handles()
    record['handle_counts'] = {'before': baseline, 'after': after, 'runs': 3}
    check(after == baseline, 'no handle growth across repeated error paths')
    if mode == 'actual_short_lived_descendants':
        record['actual_outcome_counts'] = {
            'missed_lifetime_failed_closed': sum(x.get('observed_outcome') == 'missed_lifetime_failed_closed' for x in record['runs']),
            'all_lifetimes_verified_normal_exit': sum(x.get('observed_outcome') == 'all_lifetimes_verified_normal_exit' for x in record['runs'])}
    record['status'] = 'passed'
except BaseException:
    record['status'] = 'failed'
    record['traceback'] = traceback.format_exc()
finally:
    record['owner_unchanged'] = record['owner_sha256'] == hashlib.sha256(Path(owner.__file__).read_bytes()).hexdigest()
    path = root / 'result.json'
    temporary = root / 'result.tmp'
    temporary.write_text(json.dumps(record, indent=2), encoding='utf-8')
    temporary.replace(path)
    deadline = time.monotonic() + 5
    while not (root / 'acknowledge').exists() and time.monotonic() < deadline:
        time.sleep(.005)
