"""Regression for immutable historical sources and intentional candidate overlays."""
import importlib.util
from pathlib import Path
import sys
import tempfile

RUNNER_PATH = Path(__file__).with_name("run_windows.py")
SPEC = importlib.util.spec_from_file_location("catalog_run_windows_under_test", RUNNER_PATH)
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)

def main():
    with tempfile.TemporaryDirectory(prefix="catalog-runner-retention-") as temporary:
        root = Path(temporary)
        retained_root = root / "retained"
        candidate_root = root / "windows"
        work = root / "scratch"
        retained_entry = {"path": "catalog-tests/install_runner.py"}
        candidate_entry = {"path": "install_runner.py"}
        retained = retained_root / retained_entry["path"]
        candidate = candidate_root / candidate_entry["path"]
        retained.parent.mkdir(parents=True)
        candidate.parent.mkdir(parents=True)
        retained.write_bytes(b"historical installer runner")
        candidate.write_bytes(b"current installer runner")
        retained_entry["sha256"] = RUNNER.sha(retained)
        candidate_entry["sha256"] = RUNNER.sha_text_lf(candidate)

        RUNNER.copy_retained_sources(retained_root, work, [retained_entry])
        RUNNER.copy_windows_test_sources(candidate_root, work, [candidate_entry])
        assert RUNNER.retained_sources_unchanged(
            retained_root, work, [retained_entry], [candidate_entry]
        ), "untouched historical copies should pass after a candidate overlay"
        assert RUNNER.windows_sources_unchanged(
            candidate_root, work, [candidate_entry]
        ), "untouched candidate overlay should pass"

        overlay = work / "catalog-tests" / candidate_entry["path"]
        overlay.write_bytes(b"tampered current installer runner")
        assert not RUNNER.windows_sources_unchanged(
            candidate_root, work, [candidate_entry]
        ), "candidate tampering must fail verification"
        assert RUNNER.retained_sources_unchanged(
            retained_root, work, [retained_entry], [candidate_entry]
        ), "candidate tampering must not rewrite the preserved historical source"

        preserved = work / "retained-sources" / retained_entry["path"]
        preserved.write_bytes(b"tampered historical source")
        assert not RUNNER.retained_sources_unchanged(
            retained_root, work, [retained_entry], [candidate_entry]
        ), "historical-source tampering must fail verification"
    print("runner retention regression passed")

if __name__ == "__main__":
    main()
