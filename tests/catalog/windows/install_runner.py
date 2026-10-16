"""Offline harness: real install_song/Job owner, inert external tool paths only."""
import json
import os
from pathlib import Path
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import song_catalog as catalog

config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
case = Path(config["case"])
tools = case / "tools"
chart = "#TITLE:Synthetic local fixture\n#ARTIST:Test\n#BPM:120\n: 0 4 60 la\n- 4\nE\n"
url = "https://www.youtube.com/watch?v=ABCDEFGHIJK"
if config.get("relative_paths"):
    os.environ["PATH"] = "tools"
    downloader = "downloader.exe"
else:
    def fixture_which(name):
        if name == "yt-dlp":
            return None if config.get("missing_downloader") else str(tools / "downloader.exe")
        if name == "ffprobe":
            return None if config.get("missing_probe") else str(tools / "ffprobe.exe")
        raise AssertionError("Unexpected external executable lookup")

    # Only executable discovery is replaced. Real production process ownership,
    # subprocess APIs, staging, verification parsing and publication all execute.
    catalog.shutil.which = fixture_which
    downloader = "yt-dlp"

if config.get("protocol_main"):
    # Replace catalog/network input only. Exercise actual JSON request dispatch.
    catalog.Catalog.details = lambda self, song_id: (chart, [url])
    catalog.main(downloads_enabled=config.get("downloads_enabled") is True)
    raise SystemExit(0)

cancelled = threading.Event()
if config.get("precancel"):
    cancelled.set()


def cancel_from_local_marker():
    while not stopped.is_set():
        if (case / "cancel").exists():
            cancelled.set()
            return
        stopped.wait(0.01)


stopped = threading.Event()
threading.Thread(target=cancel_from_local_marker, daemon=True).start()
started = time.monotonic()
result = {}
with (case / "protocol.log").open("w", encoding="utf-8") as protocol:
    sys.stdout = protocol
    try:
        folder = catalog.install_song(config["root"], config.get("song_id", 401),
            chart, url, cancelled, downloader=downloader)
        result = {"status": "installed", "folder": folder}
        catalog.emit("installed", folder=folder, id=config.get("song_id", 401))
    except Exception as error:
        result = {"status": "error", "error_type": type(error).__name__,
                  "message": str(error)}
        catalog.emit("error", message=str(error))
    finally:
        stopped.set()
        result["elapsed_seconds"] = time.monotonic() - started
        result["cancelled"] = cancelled.is_set()
        (case / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        catalog.emit("idle")
