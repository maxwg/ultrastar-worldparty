"""Keep test harness alive after real install_song finishes, for attribution."""
import json
from pathlib import Path
import runpy
import sys
import time

config_path = Path(sys.argv[1])
case = Path(json.loads(config_path.read_text(encoding="utf-8"))["case"])
runpy.run_path(str(Path(__file__).with_name("install_runner.py")), run_name="__main__")
(case / "runner_returned").write_text("install_song returned or raised")
deadline = time.monotonic() + 15
while not (case / "acknowledge").exists() and time.monotonic() < deadline:
    time.sleep(0.01)
