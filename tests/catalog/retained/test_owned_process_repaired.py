"""Offline Windows integration tests using only this directory's Python fixtures."""
import ctypes as C
from ctypes import wintypes as W
from dataclasses import asdict
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import owned_process as owned

FIXTURE = HERE / "fixture.py"
RUN_DIR = HERE / ("test-run-" + uuid.uuid4().hex[:12])
RUN_DIR.mkdir()
RECEIPTS = []

OpenProcess = owned._bind("OpenProcess", W.HANDLE, W.DWORD, W.BOOL, W.DWORD)
TerminateProcess = owned._bind("TerminateProcess", W.BOOL, W.HANDLE, W.UINT)
GetProcessHandleCount = owned._bind("GetProcessHandleCount", W.BOOL,
                                  W.HANDLE, C.POINTER(W.DWORD))
GetHandleInformation = owned._bind("GetHandleInformation", W.BOOL,
                                 W.HANDLE, C.POINTER(W.DWORD))


def args(role, folder):
    return [sys.executable, "-I", "-S", "-B", str(FIXTURE), role, str(folder)]


def handle_count():
    count = W.DWORD()
    owned._check(GetProcessHandleCount(owned._current_process(), C.byref(count)),
                 "GetProcessHandleCount")
    return count.value


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.folder = RUN_DIR / self._testMethodName
        self.folder.mkdir()
        self.process_handles = []
        self.sentinel = subprocess.Popen(
            [sys.executable, "-I", "-S", "-B", "-c", "import time; time.sleep(30)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)

    def tearDown(self):
        # Test emergency cleanup uses only retained exact fixture handles.
        for handle in self.process_handles:
            if owned._wait(handle, 0) == owned.WAIT_TIMEOUT:
                TerminateProcess(handle, 99)
                owned._wait(handle, 2000)
            owned._close(handle)
        self.assertIsNone(self.sentinel.poll(), "Unrelated sentinel was terminated")
        self.sentinel.terminate()
        self.sentinel.wait(timeout=3)

    def record(self, **fields):
        RECEIPTS.append({"test": self._testMethodName, **fields,
                         "sentinel_pid": self.sentinel.pid,
                         "sentinel_alive": self.sentinel.poll() is None})

    def ready_handles(self, folder, roles=("parent", "child", "grandchild")):
        deadline = time.monotonic() + 4
        records = {}
        while len(records) < len(roles) and time.monotonic() < deadline:
            for role in roles:
                if role in records:
                    continue
                try:
                    record = json.loads((folder / (role + ".json")).read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    continue
                handle = OpenProcess(0x00101001, False, record["pid"])
                owned._check(handle, "OpenProcess(exact fixture)")
                self.process_handles.append(handle)
                self.assertEqual(owned._wait(handle, 0), owned.WAIT_TIMEOUT)
                records[role] = (record, handle)
            time.sleep(0.01)
        self.assertEqual(set(records), set(roles), "Fixture did not become ready")
        return records

    def assert_terminated(self, records):
        for role, (_, handle) in records.items():
            self.assertEqual(owned._wait(handle, 1000), owned.WAIT_OBJECT_0, role)

    def tree_case(self, stdout, action):
        folder = self.folder / (stdout + "-" + action)
        folder.mkdir()
        cancel = threading.Event()
        results, errors = [], []

        def supervise():
            try:
                results.append(owned.run_owned(args("parent", folder),
                    cwd=str(folder), timeout=2.5 if action == "timeout" else 8,
                    stdout=stdout, cancel=cancel, cleanup_timeout=2))
            except BaseException as error:
                errors.append(error)

        worker = threading.Thread(target=supervise, daemon=True)
        started = time.monotonic()
        worker.start()
        records = self.ready_handles(folder)
        if action == "cancelled":
            cancel.set()
        elif action == "exited":
            (folder / "exit_parent").write_text("release", encoding="utf-8")
        worker.join(6)
        self.assertFalse(worker.is_alive(), "Supervisor hung")
        self.assertFalse(errors, repr(errors))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].reason, action)
        self.assertEqual(results[0].returncode,
                         23 if action == "exited" else owned.CLEANUP_EXIT_CODE)
        self.assert_terminated(records)
        self.record(stdout=stdout, action=action, result=asdict(results[0]),
                    fixture_pids={role: item[0]["pid"] for role, item in records.items()},
                    exact_process_handles_signaled=True,
                    wall_seconds=round(time.monotonic() - started, 4))

    def test_cancel_running_parent(self):
        for mode in ("devnull", "inherit"):
            with self.subTest(mode=mode):
                self.tree_case(mode, "cancelled")

    def test_timeout_running_parent(self):
        for mode in ("devnull", "inherit"):
            with self.subTest(mode=mode):
                self.tree_case(mode, "timeout")

    def test_parent_exit_cleans_descendants(self):
        for mode in ("devnull", "inherit"):
            with self.subTest(mode=mode):
                self.tree_case(mode, "exited")

    def test_atomic_job_association_failure(self):
        original_update = owned._update_attribute
        original_create = owned._create_process
        creation_outcomes = []
        invalid = (W.HANDLE * 1)(owned.INVALID_HANDLE)

        def invalid_job_attribute(attributes, flags, key, value, size, previous, returned):
            if key == owned.ATTRIBUTE_JOB_LIST:
                return original_update(attributes, flags, key, invalid,
                                       C.sizeof(invalid), previous, returned)
            return original_update(attributes, flags, key, value, size, previous, returned)

        def capture_create(*values):
            result = original_create(*values)
            creation_outcomes.append(bool(result))
            return result

        baseline = handle_count()
        with patch.object(owned, "_update_attribute", invalid_job_attribute), \
             patch.object(owned, "_create_process", capture_create), \
             patch.object(owned, "_resume_thread") as resume:
            with self.assertRaises(OSError) as raised:
                owned.run_owned(args("parent", self.folder), cwd=str(self.folder), timeout=2)
            resume.assert_not_called()
        self.assertFalse(any(creation_outcomes))
        self.assertFalse((self.folder / "parent.json").exists())
        self.assertLessEqual(handle_count(), baseline)
        self.record(error=str(raised.exception), creation_outcomes=creation_outcomes,
                    child_marker_absent=True, resume_called=False)

    def test_resume_failure_kills_suspended_child(self):
        original_create = owned._create_process
        captured = []

        def capture_create(*values):
            result = original_create(*values)
            if result:
                process = C.cast(values[-1], C.POINTER(owned.ProcessInfo)).contents
                handle = OpenProcess(0x00101001, False, process.dwProcessId)
                owned._check(handle, "OpenProcess(suspended fixture)")
                self.process_handles.append(handle)
                captured.append((process.dwProcessId, handle))
            return result

        def fail_resume(handle):
            C.set_last_error(5)
            return 0xFFFFFFFF

        baseline = handle_count()
        with patch.object(owned, "_create_process", capture_create), \
             patch.object(owned, "_resume_thread", fail_resume):
            with self.assertRaises(OSError) as raised:
                owned.run_owned(args("parent", self.folder), cwd=str(self.folder), timeout=2)
        self.assertEqual(len(captured), 1)
        self.assertEqual(owned._wait(captured[0][1], 1000), owned.WAIT_OBJECT_0)
        self.assertFalse((self.folder / "parent.json").exists())
        self.assertLessEqual(handle_count(), baseline + 1)  # retained verification handle
        self.record(error=str(raised.exception), suspended_pid=captured[0][0],
                    exact_process_handle_signaled=True, child_marker_absent=True)

    def test_owner_crash_kill_on_close_and_pipe_eof(self):
        owner = subprocess.Popen(args("owner", self.folder),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            records = self.ready_handles(self.folder)
            (self.folder / "crash_owner").write_text("crash", encoding="utf-8")
            output, error = owner.communicate(timeout=5)
            self.assertEqual(owner.returncode, 91)
            self.assertEqual(output, b"")
            self.assertEqual(error, b"")
            self.assert_terminated(records)
            self.record(owner_pid=owner.pid, owner_exitcode=owner.returncode,
                        fixture_pids={role: item[0]["pid"] for role, item in records.items()},
                        exact_process_handles_signaled=True, inherited_pipe_eof=True)
        finally:
            if owner.poll() is None:
                owner.terminate()
                owner.wait(timeout=3)
            owner.stdout.close()
            owner.stderr.close()

    def test_owner_crash_before_resume(self):
        owner = subprocess.Popen(args("owner_suspended", self.folder),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            records = self.ready_handles(self.folder, roles=("suspended",))
            self.assertFalse((self.folder / "parent.json").exists())
            (self.folder / "crash_owner").write_text("crash", encoding="utf-8")
            output, error = owner.communicate(timeout=5)
            self.assertEqual(owner.returncode, 91)
            self.assertEqual((output, error), (b"", b""))
            self.assert_terminated(records)
            self.assertFalse((self.folder / "parent.json").exists())
            self.record(owner_pid=owner.pid, owner_exitcode=owner.returncode,
                        suspended_pid=records["suspended"][0]["pid"],
                        exact_process_handle_signaled=True, child_marker_absent=True,
                        inherited_pipe_eof=True)
        finally:
            if owner.poll() is None:
                owner.terminate()
                owner.wait(timeout=3)
            owner.stdout.close()
            owner.stderr.close()

    def test_job_setup_failure_does_not_create_child(self):
        baseline = handle_count()
        with patch.object(owned, "_configure_job", side_effect=OSError("injected setup failure")), \
             patch.object(owned, "_create_process") as create:
            with self.assertRaisesRegex(OSError, "injected setup failure"):
                owned.run_owned(args("parent", self.folder), cwd=str(self.folder), timeout=2)
            create.assert_not_called()
        self.assertLessEqual(handle_count(), baseline)
        self.record(child_created=False, handles_before=baseline, handles_after=handle_count())

    def test_cleanup_failure_is_bounded_and_not_retried(self):
        command = [sys.executable, "-I", "-S", "-B", "-c", "pass"]
        original_stop = owned._stop_job
        attempts = []

        def tracked_stop(job, timeout):
            attempts.append(timeout)
            return original_stop(job, timeout)

        baseline = handle_count()
        started = time.monotonic()
        with patch.object(owned, "_active_processes", return_value=1), \
             patch.object(owned, "_stop_job", tracked_stop):
            with self.assertRaisesRegex(TimeoutError, "cleanup did not complete"):
                owned.run_owned(command, cwd=str(self.folder), timeout=2,
                                cleanup_timeout=0.1)
        elapsed = time.monotonic() - started
        self.assertEqual(len(attempts), 1)
        self.assertGreater(attempts[0], 0)
        self.assertLessEqual(attempts[0], 0.1)
        self.assertLess(elapsed, 1.5)
        self.assertLessEqual(handle_count(), baseline)
        self.record(cleanup_attempts=len(attempts), cleanup_timeout=0.1,
                    elapsed_seconds=round(elapsed, 4), failure_surfaced=True)

    def test_validation_and_no_handle_growth(self):
        command = [sys.executable, "-I", "-S", "-B", "-c", "raise SystemExit(259)"]
        for invalid in ("cmd /c echo forbidden", ["python.exe", "-V"]):
            with self.assertRaises(ValueError):
                owned.run_owned(invalid, cwd=str(self.folder), timeout=2)
        cancelled = threading.Event()
        cancelled.set()
        with self.assertRaises(ValueError):
            owned.run_owned(command, cwd=str(self.folder), timeout=2, cancel=cancelled)
        baseline = handle_count()
        for index in range(12):
            result = owned.run_owned(command, cwd=str(self.folder), timeout=3,
                                     stdout="inherit" if index % 2 else "devnull")
            self.assertEqual(result.reason, "exited")
            self.assertEqual(result.returncode, 259)
        after = handle_count()
        self.assertLessEqual(after, baseline)
        self.record(repetitions=12, exitcode_259_handled=True,
                    handles_before=baseline, handles_after=after)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OwnershipTests)
    outcome = unittest.TextTestRunner(verbosity=2).run(suite)
    receipt = {"python": sys.version, "executable": sys.executable,
               "platform": sys.platform, "windows_version": list(sys.getwindowsversion()),
               "run_directory": str(RUN_DIR), "tests_run": outcome.testsRun,
               "failures": len(outcome.failures), "errors": len(outcome.errors),
               "success": outcome.wasSuccessful(), "receipts": RECEIPTS}
    receipt_path = RUN_DIR / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print("RECEIPT=" + str(receipt_path))
    raise SystemExit(0 if outcome.wasSuccessful() else 1)
