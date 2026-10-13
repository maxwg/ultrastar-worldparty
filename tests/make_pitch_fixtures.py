"""Generate copyright-free songs for the headless UI smoke test."""
from pathlib import Path
import math
import struct
import wave

root = Path(__file__).resolve().parents[1] / "build" / "ui" / "songs"
root.mkdir(parents=True, exist_ok=True)
audio = b"".join(struct.pack("<h", round(1500 * math.sin(2 * math.pi * 261.6256 * i / 44100)))
                 for i in range(44100 * 30))
for artist in ("Alice", "Baker", "Muse", "Zebra"):
    folder = root / artist
    folder.mkdir(exist_ok=True)
    with wave.open(str(folder / "test.wav"), "wb") as output:
        output.setparams((1, 2, 44100, 0, "NONE", "not compressed"))
        output.writeframes(audio)
    (folder / "test.txt").write_text(
        f"#TITLE:Pitch Test\n#ARTIST:{artist}\n#MP3:test.wav\n#BPM:120\n#GAP:0\n"
        ": 0 8 0 Sing\n: 8 8 2  these\n: 16 8 4  notes\n: 24 8 7  now\n- 32\n"
        ": 40 8 8 G sharp\n: 48 8 9  A\n: 56 8 11  B\n: 64 8 12  C\nE\n",
        encoding="utf-8")
