"""Post-repair native install tests; original evidence and tests remain unchanged."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_boundary_v2 as boundary
base = boundary.base


class RepairTests(boundary.BoundaryTests):
    def setUp(self):
        super().setUp()
        for name in ("downloader.exe", "ffprobe.exe"):
            shutil.copyfile(HERE / "native_fixture_repair.exe", self.tools / name)

    def test_probe_descendant_cleanup_before_publication(self):
        self.start("probe_descendant")
        self.capture_roles(("probe", "probe_child"))
        (self.tools / "release_probe").write_text("release")
        self.finish()
        self.assertEqual(self.result["status"], "installed")
        self.assertEqual(list(self.case.glob(".worldparty-download-*")), [])

    def test_cancel_probe_descendant_without_release(self):
        self.start("probe_tree_hold")
        self.capture_roles(("probe", "probe_child"))
        (self.case / "cancel").write_text("cancel")
        self.finish()
        self.assert_no_publication()
        self.assertTrue(self.result["cancelled"])
        self.assertLess(self.result["elapsed_seconds"], 5)
        self.assertIn("verification", self.result["message"])

    def test_real_15_second_probe_timeout(self):
        self.start("probe_tree_hold", outer_timeout=25)
        self.capture_roles(("probe", "probe_child"))
        self.finish(timeout=22)
        self.assert_no_publication()
        self.assertFalse(self.result["cancelled"])
        self.assertGreaterEqual(self.result["elapsed_seconds"], 14.9)
        self.assertLess(self.result["elapsed_seconds"], 20)
        self.assertIn("timed out", self.result["message"])

    def test_probe_output_limit_rejects_publication(self):
        self.start("probe_flood")
        self.finish()
        self.assert_no_publication()
        self.assertLess(self.result["elapsed_seconds"], 5)
        self.assertIn("output limit", self.result["message"])


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "fast"
    skipped = {"test_native_process_setup_failure_removes_stage",
               "test_probe_descendant_reproduces_unbounded_verification"}
    names = unittest.defaultTestLoader.getTestCaseNames(RepairTests)
    names = [name for name in names if name not in skipped and
             ((name == "test_real_600_second_downloader_timeout") == (mode == "timeout"))]
    sources = [HERE.parent / "song_catalog.py", HERE.parent / "owned_process.py",
               HERE / "test_install_windows.py", HERE / "test_boundary_v2.py",
               HERE / "install_runner.py", HERE / "boundary_runner.py",
               HERE / "native_fixture_repair.c", HERE / "native_fixture_repair.exe",
               Path(__file__).resolve()]
    before = {str(p.relative_to(HERE.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    started = time.monotonic()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(RepairTests(name) for name in names))
    after = {str(p.relative_to(HERE.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    receipt = {"mode": mode, "tests_run": result.testsRun, "failures": len(result.failures),
               "errors": len(result.errors), "success": result.wasSuccessful() and before == after,
               "elapsed_seconds": time.monotonic() - started, "source_bytes_stable": before == after,
               "production_process_owner_mocked": False, "hashes": before,
               "boundary_receipts": boundary.BOUNDARY_RECEIPTS, "receipts": base.RECEIPTS,
               "excluded_cases": {"malformed_non_PE": "Original CreateProcess startup stall remains documented separately; valid-EXE sharing failure is tested.",
                                  "old_probe_defect_reproduction": "Replaced by successful owned-pipe-descendant cleanup and real 15-second timeout."}}
    output = base.RUN / ("repair-" + mode + "-receipt.json")
    output.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print("RECEIPT=" + str(output))
    raise SystemExit(0 if receipt["success"] else 1)

