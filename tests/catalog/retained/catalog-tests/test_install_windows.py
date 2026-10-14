"""Native Windows install_song tests; no production process-owner mocking."""
import ctypes as C
from ctypes import wintypes as W
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import struct
import subprocess
import sys
import threading
import time
import unittest
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import owned_process as owner

RUN = HERE / ("run-" + uuid.uuid4().hex[:12])
RUN.mkdir()
RECEIPTS = []
DEFECTS = []
URL = "https://www.youtube.com/watch?v=ABCDEFGHIJK"
OpenProcess = owner._bind("OpenProcess", W.HANDLE, W.DWORD, W.BOOL, W.DWORD)


def read_argv(path):
    data = path.read_bytes()
    count = struct.unpack_from("<I", data)[0]
    offset, result = 4, []
    for _ in range(count):
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        result.append(data[offset:offset + size].decode("utf-8"))
        offset += size
    if offset != len(data):
        raise AssertionError("Unexpected argv bytes")
    return result


class InstallWindowsTests(unittest.TestCase):
    def setUp(self):
        self.case = RUN / self._testMethodName
        self.case.mkdir()
        self.tools = self.case / "tools"
        self.tools.mkdir()
        for name in ("downloader.exe", "ffprobe.exe"):
            shutil.copyfile(HERE / "native_fixture.exe", self.tools / name)
        self.root = self.case / "Songs & [local] ü"
        self.config = {"case": str(self.case), "root": str(self.root)}
        self.handles = {}
        self.sentinel = subprocess.Popen(
            [sys.executable, "-I", "-S", "-B", "-c", "import time; time.sleep(650)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)

    def tearDown(self):
        for handle in self.handles.values():
            owner._close(handle)
        self.assertIsNone(self.sentinel.poll(), "Unrelated sentinel stopped")
        self.sentinel.terminate()
        self.sentinel.wait(timeout=3)

    def start(self, mode="success", outer_timeout=25):
        (self.tools / "mode.txt").write_text(mode, encoding="ascii")
        config_path = self.case / "config.json"
        config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.outer_results, self.outer_errors = [], []

        def run():
            try:
                self.outer_results.append(owner.run_owned(
                    [sys.executable, "-I", "-S", "-B", str(HERE / "install_runner.py"),
                     str(config_path)], cwd=str(self.case), timeout=outer_timeout,
                    stdout="devnull", cleanup_timeout=3))
            except BaseException as error:
                self.outer_errors.append(repr(error))

        self.worker = threading.Thread(target=run, daemon=True)
        self.worker.start()

    def wait_file(self, path, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists() and path.stat().st_size:
                return
            time.sleep(0.01)
        self.fail("Fixture marker missing: " + str(path))

    def capture_roles(self, roles):
        for role in roles:
            path = self.tools / (role + ".pid")
            self.wait_file(path)
            pid = int(path.read_text(encoding="ascii").strip())
            handle = OpenProcess(0x00100000, False, pid)
            owner._check(handle, "OpenProcess(exact native fixture)")
            self.assertEqual(owner._wait(handle, 0), owner.WAIT_TIMEOUT)
            self.handles[role] = handle

    def finish(self, timeout=30, expected_outer="exited"):
        self.worker.join(timeout)
        self.assertFalse(self.worker.is_alive(), "Outer ownership watchdog hung")
        self.assertEqual(self.outer_errors, [])
        self.assertEqual(self.outer_results[0].reason, expected_outer)
        for role, handle in self.handles.items():
            self.assertEqual(owner._wait(handle, 1000), owner.WAIT_OBJECT_0, role)
        result_path = self.case / "result.json"
        self.result = json.loads(result_path.read_text()) if result_path.exists() else None
        RECEIPTS.append({"test": self._testMethodName, "outer": asdict(self.outer_results[0]),
                         "result": self.result, "case": str(self.case),
                         "verified_terminated_roles": list(self.handles),
                         "sentinel_alive": self.sentinel.poll() is None})
        if self.result is not None:
            events = [json.loads(line) for line in (self.case / "protocol.log").read_text().splitlines()]
            self.assertEqual(events[-1]["type"], "idle")
            self.assertTrue(all(item["type"] in ("installed", "error", "idle") for item in events))

    def assert_no_publication(self):
        self.assertFalse((self.root / "USDB-401").exists())
        self.assertEqual(list(self.case.glob(".worldparty-download-*")), [])
        self.assertEqual(self.result["status"], "error")

    def assert_argv(self):
        argv = read_argv(self.tools / "argv.bin")
        self.assertEqual(argv[:11], [str((self.tools / "downloader.exe").resolve()),
            "--ignore-config", "--no-playlist", "--no-warnings", "--newline", "--progress",
            "--max-filesize", "500M", "-f", "best[ext=mp4]", "-o"])
        self.assertEqual(argv[12:], ["--", URL])
        output = Path(argv[11])
        self.assertTrue(output.is_absolute())
        self.assertEqual(output.name, "media.mp4")
        self.assertEqual(output.parent.parent, self.case)
        self.assertTrue(output.parent.name.startswith(".worldparty-download-"))
        self.assertNotEqual(output.parent, self.root)
        return argv

    def test_success_exact_argv_and_publication(self):
        self.start()
        self.finish()
        argv = self.assert_argv()
        target = self.root / "USDB-401"
        self.assertEqual(self.result["status"], "installed")
        self.assertEqual(set(p.name for p in target.iterdir()), {"media.mp4", "source.json", "song.txt"})
        self.assertGreaterEqual((target / "media.mp4").stat().st_size, 32)
        self.assertTrue((target / "song.txt").read_text().startswith("#MP3:media.mp4\n#VIDEO:media.mp4\n"))
        self.assertEqual(json.loads((target / "source.json").read_text()), {"usdb_id": 401, "media": URL})
        self.assertEqual(list(self.case.glob(".worldparty-download-*")), [])
        RECEIPTS[-1]["actual_argv"] = argv

    def test_relative_path_downloader_resolution(self):
        self.config["relative_paths"] = True
        self.start()
        self.finish()
        self.assert_argv()
        self.assertEqual(self.result["status"], "installed")

    def test_cancel_running_descendants_removes_stage(self):
        self.start("hold")
        self.capture_roles(("parent", "child", "grandchild"))
        (self.case / "cancel").write_text("cancel")
        self.finish()
        self.assert_no_publication()
        self.assertTrue(self.result["cancelled"])

    def test_parent_exit_cleans_descendants_before_publication(self):
        self.start("exit_descendants")
        self.capture_roles(("parent", "child", "grandchild"))
        (self.tools / "release").write_text("exit")
        self.finish()
        self.assertEqual(self.result["status"], "installed")
        self.assertEqual(list(self.case.glob(".worldparty-download-*")), [])

    def test_nonzero_cleans_descendants_and_stage(self):
        self.start("nonzero_descendants")
        self.capture_roles(("parent", "child", "grandchild"))
        (self.tools / "release").write_text("exit")
        self.finish()
        self.assert_no_publication()

    def test_native_process_setup_failure_removes_stage(self):
        (self.tools / "downloader.exe").write_bytes(b"not a Windows executable")
        self.start()
        self.finish()
        self.assert_no_publication()
        self.assertEqual(self.result["error_type"], "OSError")
        self.assertFalse((self.tools / "parent.pid").exists())

    def test_missing_downloader_removes_stage(self):
        self.config["missing_downloader"] = True
        self.start()
        self.finish()
        self.assert_no_publication()

    def test_existing_destination_preserved(self):
        target = self.root / "USDB-401"
        target.mkdir(parents=True)
        (target / "preserve.txt").write_bytes(b"EXISTING CONTENT")
        self.start()
        self.finish()
        self.assertEqual(self.result["status"], "error")
        self.assertEqual((target / "preserve.txt").read_bytes(), b"EXISTING CONTENT")
        self.assertEqual(set(p.name for p in target.iterdir()), {"preserve.txt"})
        self.assertFalse((self.tools / "parent.pid").exists())
        self.assertEqual(list(self.case.glob(".worldparty-download-*")), [])

    def test_destination_created_during_verification_preserved(self):
        self.start("probe_hold")
        self.capture_roles(("probe",))
        target = self.root / "USDB-401"
        target.mkdir()
        (target / "preserve.txt").write_text("RACE CONTENT")
        (self.tools / "release_probe").write_text("continue")
        self.finish()
        self.assertEqual(self.result["status"], "error")
        self.assertEqual((target / "preserve.txt").read_text(), "RACE CONTENT")
        self.assertEqual(set(p.name for p in target.iterdir()), {"preserve.txt"})
        self.assertEqual(list(self.case.glob(".worldparty-download-*")), [])

    def test_cancel_during_probe_prevents_publication(self):
        self.start("probe_hold")
        self.capture_roles(("probe",))
        (self.case / "cancel").write_text("cancel")
        time.sleep(0.05)  # allow local cancellation-input monitor to observe marker
        (self.tools / "release_probe").write_text("continue")
        self.finish()
        self.assert_no_publication()
        self.assertTrue(self.result["cancelled"])

    def test_probe_failure_prevents_publication(self):
        self.start("probe_fail")
        self.finish()
        self.assert_no_publication()

    def test_probe_descendant_reproduces_unbounded_verification(self):
        self.start("probe_descendant", outer_timeout=20)
        self.capture_roles(("probe_child",))
        self.finish(timeout=25, expected_outer="timeout")
        self.assertIsNone(self.result, "Production unexpectedly completed its 15-second probe timeout")
        stages = list(self.case.glob(".worldparty-download-*"))
        self.assertEqual(len(stages), 1)
        self.assertFalse((self.root / "USDB-401").exists())
        defect = {"finding": "ffprobe descendant retains output pipe past 15-second timeout",
                  "observed_seconds": self.outer_results[0].elapsed_seconds,
                  "production_result_absent": True, "stage_remaining": str(stages[0]),
                  "test_only_outer_job_killed_descendant": True}
        DEFECTS.append(defect)
        RECEIPTS[-1]["reproduced_defect"] = defect

    def test_actual_json_main_stdout_isolation(self):
        self.config["protocol_main"] = True
        (self.tools / "mode.txt").write_text("success", encoding="ascii")
        config_path = self.case / "config.json"
        config_path.write_text(json.dumps(self.config))
        process = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-u",
            str(HERE / "install_runner.py"), str(config_path)], cwd=self.case,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
        lines = queue.Queue()
        reader = threading.Thread(target=lambda: [lines.put(line) for line in process.stdout], daemon=True)
        reader.start()
        try:
            process.stdin.write(json.dumps({"op": "download", "root": str(self.root), "id": 401, "url": URL}) + "\n")
            process.stdin.flush()
            events = []
            while True:
                event = json.loads(lines.get(timeout=5))
                events.append(event)
                if event["type"] == "idle":
                    break
            process.stdin.write('{"op":"quit"}\n')
            process.stdin.flush()
            process.stdin.close()
            process.wait(timeout=5)
            reader.join(timeout=2)
            self.assertEqual([event["type"] for event in events], ["installed", "idle"])
            self.assertEqual(process.stderr.read(), "")
            self.assertEqual(process.returncode, 0)
            self.assertTrue(lines.empty())
            self.assert_argv()
            RECEIPTS.append({"test": self._testMethodName, "actual_main_events": events,
                             "stderr_empty": True, "native_downloader_noise_suppressed": True,
                             "sentinel_alive": self.sentinel.poll() is None})
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def test_real_600_second_downloader_timeout(self):
        self.start("hold", outer_timeout=615)
        self.capture_roles(("parent", "child", "grandchild"))
        self.finish(timeout=620)
        self.assert_no_publication()
        self.assertGreaterEqual(self.result["elapsed_seconds"], 599)
        self.assertLess(self.result["elapsed_seconds"], 610)
        self.assertFalse(self.result["cancelled"])
        self.assertIn("timed out", self.result["message"])


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "fast"
    names = unittest.defaultTestLoader.getTestCaseNames(InstallWindowsTests)
    selected = [name for name in names if (name == "test_real_600_second_downloader_timeout") == (mode == "timeout")]
    started = time.monotonic()
    outcome = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(InstallWindowsTests(name) for name in selected))
    source_files = [HERE.parent / "song_catalog.py", HERE.parent / "owned_process.py",
                    HERE / "test_install_windows.py", HERE / "install_runner.py",
                    HERE / "native_fixture.c", HERE / "native_fixture.exe"]
    receipt = {"mode": mode, "tests_run": outcome.testsRun, "failures": len(outcome.failures),
               "errors": len(outcome.errors), "success": outcome.wasSuccessful(),
               "elapsed_seconds": time.monotonic() - started, "python": sys.version,
               "windows": list(sys.getwindowsversion()), "run_directory": str(RUN),
               "production_process_owner_mocked": False,
               "external_inputs": "Native inert downloader/probe binaries; executable discovery/catalog details fixtures only",
               "hashes": {str(path.relative_to(HERE.parent)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files},
               "receipts": RECEIPTS, "defects": DEFECTS}
    output = RUN / ("catalog-" + mode + "-receipt.json")
    output.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print("RECEIPT=" + str(output))
    raise SystemExit(0 if outcome.wasSuccessful() else 1)
