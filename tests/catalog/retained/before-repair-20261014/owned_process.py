"""Small Windows 10+ subprocess owner; Python standard library only.

One unnamed, non-inheritable Job per invocation. JOB_LIST associates the child
at CreateProcessW time, so no unassigned-child crash window exists. The child
starts suspended and is resumed only after successful creation. Descendants
remain in the Job; breakaway is never enabled. No shell or downloader is used.

References (supplied by the integration owner; no network access performed):
https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute
https://devblogs.microsoft.com/oldnewthing/20230209-00/?p=107812
Declarations cross-checked against installed Windows SDK 10.0.22621.0.
"""

from __future__ import annotations

import ctypes as C
from ctypes import wintypes as W
from dataclasses import dataclass
import math
import os
import subprocess
import threading
import time
from collections.abc import Sequence

if os.name != "nt":
    raise RuntimeError("owned_process requires Windows 10 or later")

K = C.WinDLL("kernel32", use_last_error=True)
SIZE_T = C.c_size_t
ULONG_PTR = C.c_size_t
INVALID_HANDLE = C.c_void_p(-1).value
JOB_LIMIT_KILL_ON_CLOSE = 0x2000
JOB_EXTENDED_LIMITS = 9
JOB_BASIC_ACCOUNTING = 1
ATTRIBUTE_HANDLE_LIST = 0x00020002
ATTRIBUTE_JOB_LIST = 0x0002000D
CREATE_SUSPENDED = 0x00000004
CREATE_NO_WINDOW = 0x08000000
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
STARTF_USESTDHANDLES = 0x100
WAIT_OBJECT_0, WAIT_TIMEOUT, WAIT_FAILED = 0, 258, 0xFFFFFFFF
CLEANUP_EXIT_CODE = 0xE0000001


class BasicLimits(C.Structure):
    _fields_ = [("PerProcessUserTimeLimit", C.c_longlong),
                ("PerJobUserTimeLimit", C.c_longlong), ("LimitFlags", W.DWORD),
                ("MinimumWorkingSetSize", SIZE_T), ("MaximumWorkingSetSize", SIZE_T),
                ("ActiveProcessLimit", W.DWORD), ("Affinity", ULONG_PTR),
                ("PriorityClass", W.DWORD), ("SchedulingClass", W.DWORD)]


class IOCounters(C.Structure):
    _fields_ = [(name, C.c_ulonglong) for name in
                ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                 "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]


class ExtendedLimits(C.Structure):
    _fields_ = [("BasicLimitInformation", BasicLimits), ("IoInfo", IOCounters),
                ("ProcessMemoryLimit", SIZE_T), ("JobMemoryLimit", SIZE_T),
                ("PeakProcessMemoryUsed", SIZE_T), ("PeakJobMemoryUsed", SIZE_T)]


class Accounting(C.Structure):
    _fields_ = [("TotalUserTime", C.c_longlong), ("TotalKernelTime", C.c_longlong),
                ("ThisPeriodTotalUserTime", C.c_longlong),
                ("ThisPeriodTotalKernelTime", C.c_longlong),
                ("TotalPageFaultCount", W.DWORD), ("TotalProcesses", W.DWORD),
                ("ActiveProcesses", W.DWORD), ("TotalTerminatedProcesses", W.DWORD)]


class StartupInfo(C.Structure):
    _fields_ = [("cb", W.DWORD), ("lpReserved", W.LPWSTR),
                ("lpDesktop", W.LPWSTR), ("lpTitle", W.LPWSTR),
                *[(name, W.DWORD) for name in
                  ("dwX", "dwY", "dwXSize", "dwYSize", "dwXCountChars",
                   "dwYCountChars", "dwFillAttribute", "dwFlags")],
                ("wShowWindow", W.WORD), ("cbReserved2", W.WORD),
                ("lpReserved2", C.POINTER(W.BYTE)), ("hStdInput", W.HANDLE),
                ("hStdOutput", W.HANDLE), ("hStdError", W.HANDLE)]


class StartupInfoEx(C.Structure):
    _fields_ = [("StartupInfo", StartupInfo), ("lpAttributeList", C.c_void_p)]


class ProcessInfo(C.Structure):
    _fields_ = [("hProcess", W.HANDLE), ("hThread", W.HANDLE),
                ("dwProcessId", W.DWORD), ("dwThreadId", W.DWORD)]


class SecurityAttributes(C.Structure):
    _fields_ = [("nLength", W.DWORD), ("lpSecurityDescriptor", C.c_void_p),
                ("bInheritHandle", W.BOOL)]


def _bind(name, restype, *args):
    fn = getattr(K, name)
    fn.restype, fn.argtypes = restype, list(args)
    return fn


_create_job = _bind("CreateJobObjectW", W.HANDLE, C.c_void_p, W.LPCWSTR)
_set_job = _bind("SetInformationJobObject", W.BOOL, W.HANDLE, C.c_int,
                 C.c_void_p, W.DWORD)
_query_job = _bind("QueryInformationJobObject", W.BOOL, W.HANDLE, C.c_int,
                   C.c_void_p, W.DWORD, C.c_void_p)
_terminate_job = _bind("TerminateJobObject", W.BOOL, W.HANDLE, W.UINT)
_close_handle = _bind("CloseHandle", W.BOOL, W.HANDLE)
_init_attributes = _bind("InitializeProcThreadAttributeList", W.BOOL,
                         C.c_void_p, W.DWORD, W.DWORD, C.POINTER(SIZE_T))
_update_attribute = _bind("UpdateProcThreadAttribute", W.BOOL,
                          C.c_void_p, W.DWORD, ULONG_PTR, C.c_void_p,
                          SIZE_T, C.c_void_p, C.c_void_p)
_delete_attributes = _bind("DeleteProcThreadAttributeList", None, C.c_void_p)
_create_process = _bind("CreateProcessW", W.BOOL, W.LPCWSTR, W.LPWSTR,
                        C.c_void_p, C.c_void_p, W.BOOL, W.DWORD,
                        C.c_void_p, W.LPCWSTR, C.c_void_p, C.POINTER(ProcessInfo))
_resume_thread = _bind("ResumeThread", W.DWORD, W.HANDLE)
_wait = _bind("WaitForSingleObject", W.DWORD, W.HANDLE, W.DWORD)
_exit_code = _bind("GetExitCodeProcess", W.BOOL, W.HANDLE, C.POINTER(W.DWORD))
_get_std = _bind("GetStdHandle", W.HANDLE, W.DWORD)
_current_process = _bind("GetCurrentProcess", W.HANDLE)
_duplicate = _bind("DuplicateHandle", W.BOOL, W.HANDLE, W.HANDLE,
                   W.HANDLE, C.POINTER(W.HANDLE), W.DWORD, W.BOOL, W.DWORD)
_create_file = _bind("CreateFileW", W.HANDLE, W.LPCWSTR, W.DWORD, W.DWORD,
                     C.POINTER(SecurityAttributes), W.DWORD, W.DWORD, W.HANDLE)


def _check(ok, operation):
    if not ok:
        error = C.get_last_error()
        raise OSError(error, f"{operation}: {C.FormatError(error).strip()}")


def _close(handle):
    if handle and handle != INVALID_HANDLE:
        _check(_close_handle(handle), "CloseHandle")


def _configure_job(job):
    limits = ExtendedLimits()
    limits.BasicLimitInformation.LimitFlags = JOB_LIMIT_KILL_ON_CLOSE
    _check(_set_job(job, JOB_EXTENDED_LIMITS, C.byref(limits), C.sizeof(limits)),
           "SetInformationJobObject(KILL_ON_JOB_CLOSE)")


def _active_processes(job):
    accounting = Accounting()
    _check(_query_job(job, JOB_BASIC_ACCOUNTING, C.byref(accounting),
                     C.sizeof(accounting), None), "QueryInformationJobObject")
    return accounting.ActiveProcesses


def _stop_job(job, cleanup_timeout):
    """Do not return until this exact Job is empty, or raise within the bound."""
    deadline = time.monotonic() + cleanup_timeout
    _check(_terminate_job(job, CLEANUP_EXIT_CODE), "TerminateJobObject")
    while _active_processes(job):
        if time.monotonic() >= deadline:
            raise TimeoutError("Job cleanup did not complete within the deadline")
        time.sleep(min(0.01, max(0, deadline - time.monotonic())))


def _stdio(mode, handles):
    # Only these handles enter HANDLE_LIST; the Job handle never does.
    security = SecurityAttributes(C.sizeof(SecurityAttributes), None, True)
    nul = _create_file("NUL", 0xC0000000, 3, C.byref(security), 3, 0, None)
    _check(nul != INVALID_HANDLE, "CreateFileW(NUL)")
    handles.append(nul)
    if mode == "devnull":
        return nul, nul, nul
    outputs = []
    for standard_id in (-11, -12):
        original = _get_std(standard_id & 0xFFFFFFFF)
        if not original or original == INVALID_HANDLE:
            raise OSError("Inherited stdout/stderr is unavailable")
        duplicate = W.HANDLE()
        _check(_duplicate(_current_process(), original, _current_process(),
                          C.byref(duplicate), 0, True, 2), "DuplicateHandle(stdio)")
        handles.append(duplicate.value)
        outputs.append(duplicate.value)
    return nul, *outputs


@dataclass(frozen=True)
class Result:
    pid: int
    returncode: int
    reason: str  # exited, timeout, or cancelled
    elapsed_seconds: float


def run_owned(argv: Sequence[str], *, cwd: str, timeout: float,
              stdout: str = "devnull", cancel: threading.Event | None = None,
              cleanup_timeout: float = 3.0) -> Result:
    """Run one absolute executable; finish only after its entire Job is empty.

    Root exit also cleans remaining descendants. stdin is NUL; stdout/stderr
    are either NUL or explicit copies of the caller's handles (no pipe reader).
    Errors fail closed and propagate. No fallback if Job association is blocked.
    A cleanup failure raises rather than reporting successful cancellation.
    Concurrent calls/other code creating processes with broad handle inheritance
    are out of scope; coordinate this single-owner helper in the host process.
    """
    if isinstance(argv, (str, bytes)) or not argv or any(
            not isinstance(arg, str) or "\0" in arg for arg in argv):
        raise ValueError("argv must be a nonempty sequence of NUL-free strings")
    if not os.path.isabs(argv[0]) or not os.path.isfile(argv[0]):
        raise ValueError("argv[0] must name an existing absolute executable")
    if not os.path.isabs(cwd) or not os.path.isdir(cwd) or "\0" in cwd:
        raise ValueError("cwd must name an existing absolute directory")
    if stdout not in ("devnull", "inherit"):
        raise ValueError("stdout must be devnull or inherit")
    if any(not math.isfinite(value) or value <= 0
           for value in (timeout, cleanup_timeout)):
        raise ValueError("timeout and cleanup_timeout must be finite and positive")
    if cancel is not None and cancel.is_set():
        raise ValueError("Cancellation already requested; no child created")

    started = time.monotonic()
    job = None
    proc = ProcessInfo()
    handles = []
    attributes = None
    child_created = False
    cleanup_attempted = False
    try:
        job = _create_job(None, None)  # non-inheritable, unnamed
        _check(job, "CreateJobObjectW")
        _configure_job(job)
        stdin_handle, stdout_handle, stderr_handle = _stdio(stdout, handles)
        required = SIZE_T()
        _init_attributes(None, 2, 0, C.byref(required))
        if not required.value:
            _check(False, "InitializeProcThreadAttributeList(size)")
        buffer = C.create_string_buffer(required.value)
        _check(_init_attributes(buffer, 2, 0, C.byref(required)),
               "InitializeProcThreadAttributeList")
        attributes = buffer
        inherited = (W.HANDLE * len(handles))(*handles)
        jobs = (W.HANDLE * 1)(job)
        _check(_update_attribute(attributes, 0, ATTRIBUTE_HANDLE_LIST,
                                  inherited, C.sizeof(inherited), None, None),
               "UpdateProcThreadAttribute(HANDLE_LIST)")
        _check(_update_attribute(attributes, 0, ATTRIBUTE_JOB_LIST,
                                  jobs, C.sizeof(jobs), None, None),
               "UpdateProcThreadAttribute(JOB_LIST)")
        startup = StartupInfoEx()
        startup.StartupInfo.cb = C.sizeof(startup)
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES
        startup.StartupInfo.hStdInput = stdin_handle
        startup.StartupInfo.hStdOutput = stdout_handle
        startup.StartupInfo.hStdError = stderr_handle
        startup.lpAttributeList = C.cast(attributes, C.c_void_p)
        # Windows requires a mutable command line, quoted from argv. No shell.
        command_line = C.create_unicode_buffer(subprocess.list2cmdline(list(argv)))
        _check(_create_process(argv[0], command_line, None, None, True,
                                CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                                None, cwd, C.byref(startup), C.byref(proc)),
               "CreateProcessW(atomic Job association)")
        child_created = True
        previous_suspend_count = _resume_thread(proc.hThread)
        if previous_suspend_count != 1:
            if previous_suspend_count == 0xFFFFFFFF:
                _check(False, "ResumeThread")
            raise RuntimeError(f"Unexpected suspend count: {previous_suspend_count}")
        reason = "exited"
        while True:
            state = _wait(proc.hProcess, 0)
            if state == WAIT_OBJECT_0:
                break
            if state == WAIT_FAILED:
                _check(False, "WaitForSingleObject")
            if state != WAIT_TIMEOUT:
                raise RuntimeError(f"Unexpected process wait result: {state}")
            if cancel is not None and cancel.is_set():
                reason = "cancelled"
                break
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                reason = "timeout"
                break
            time.sleep(min(0.02, remaining))
        root_exit = W.DWORD()
        if reason == "exited":
            _check(_exit_code(proc.hProcess, C.byref(root_exit)), "GetExitCodeProcess")
        cleanup_attempted = True
        _stop_job(job, cleanup_timeout)
        if reason != "exited":
            _check(_exit_code(proc.hProcess, C.byref(root_exit)), "GetExitCodeProcess")
        return Result(proc.dwProcessId, root_exit.value, reason,
                      time.monotonic() - started)
    finally:
        try:
            if child_created and not cleanup_attempted:
                cleanup_attempted = True
                _stop_job(job, cleanup_timeout)
        finally:
            # Closing the last Job handle is the final kill-on-close backstop.
            # Attempt every release, even if an individual CloseHandle fails.
            errors = []
            if attributes is not None:
                _delete_attributes(attributes)
            for handle in (job, proc.hThread, proc.hProcess, *reversed(handles)):
                try:
                    _close(handle)
                except OSError as error:
                    errors.append(error)
            if errors:
                raise errors[0]
