"""Additional evidence without editing the source set used by the 600s run."""
from dataclasses import asdict
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
from pathlib import Path
import sys
import threading
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_install_windows as base

owner = base.owner
BOUNDARY_RECEIPTS = []


class BoundaryTests(base.InstallWindowsTests):
    def start(self, mode="success", outer_timeout=25):
        (self.tools / "mode.txt").write_text(mode, encoding="ascii")
        config_path = self.case / "config.json"
        config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.outer_results, self.outer_errors = [], []

        def run():
            try:
                self.outer_results.append(owner.run_owned(
                    [sys.executable, "-I", "-S", "-B", str(HERE / "boundary_runner.py"),
                     str(config_path)], cwd=str(self.case), timeout=outer_timeout,
                    stdout="devnull", cleanup_timeout=3))
            except BaseException as error:
                self.outer_errors.append(repr(error))

        self.worker = threading.Thread(target=run, daemon=True)
        self.worker.start()

    def finish(self, timeout=12, expected_outer="exited"):
        try:
            self.wait_file(self.case / "runner_returned", timeout=timeout)
            self.assertTrue(self.worker.is_alive(), "Outer Job already finished")
            states = {role: owner._wait(handle, 0) for role, handle in self.handles.items()}
            result = json.loads((self.case / "result.json").read_text())
            record = {"test": self._testMethodName, "harness_alive_before_outer_cleanup": True,
                      "exact_fixture_handle_states_before_outer_cleanup": states,
                      "production_result": result,
                      "remaining_stage_before_outer_cleanup": [str(p) for p in self.case.glob(".worldparty-download-*")],
                      "sentinel_alive": self.sentinel.poll() is None}
            BOUNDARY_RECEIPTS.append(record)
            self.assertTrue(all(state == owner.WAIT_OBJECT_0 for state in states.values()),
                            "Production returned before exact fixture process termination")
        finally:
            (self.case / "acknowledge").write_text("release test harness")
            self.worker.join(15)
        super().finish(timeout=1, expected_outer=expected_outer)

    def test_valid_executable_sharing_failure_removes_stage(self):
        create_file = owner._create_file
        lock = create_file(str(self.tools / "downloader.exe"), 0x80000000, 0, None, 3, 0, None)
        owner._check(lock != owner.INVALID_HANDLE, "CreateFileW(test-only sharing lock)")
        try:
            self.start()
            self.finish()
            self.assert_no_publication()
            self.assertIn(self.result["error_type"], ("OSError", "BrokenPipeError", "PermissionError"))
            self.assertFalse((self.tools / "parent.pid").exists())
        finally:
            owner._close(lock)

    def test_probe_noaudio_prevents_publication(self):
        self.start("probe_noaudio")
        self.finish()
        self.assert_no_publication()

    def test_probe_badjson_prevents_publication(self):
        self.start("probe_badjson")
        self.finish()
        self.assert_no_publication()


if __name__ == "__main__":
    names = ["test_cancel_running_descendants_removes_stage",
             "test_parent_exit_cleans_descendants_before_publication",
             "test_nonzero_cleans_descendants_and_stage",
             "test_valid_executable_sharing_failure_removes_stage",
             "test_probe_noaudio_prevents_publication", "test_probe_badjson_prevents_publication"]
    started = time.monotonic()
    outcome = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(BoundaryTests(name) for name in names))
    sources = [HERE.parent / "song_catalog.py", HERE.parent / "owned_process.py",
               HERE / "test_install_windows.py", HERE / "install_runner.py",
               HERE / "native_fixture.c", HERE / "native_fixture.exe",
               HERE / "boundary_runner.py", HERE / "test_boundary_v2.py"]
    receipt = {"tests_run": outcome.testsRun, "failures": len(outcome.failures),
               "errors": len(outcome.errors), "success": outcome.wasSuccessful(),
               "elapsed_seconds": time.monotonic() - started,
               "run_directory": str(base.RUN), "production_process_owner_mocked": False,
               "boundary_receipts": BOUNDARY_RECEIPTS, "base_receipts": base.RECEIPTS,
               "hashes": {str(p.relative_to(HERE.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    output = base.RUN / "catalog-boundary-receipt.json"
    output.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print("RECEIPT=" + str(output))
    raise SystemExit(0 if outcome.wasSuccessful() else 1)
