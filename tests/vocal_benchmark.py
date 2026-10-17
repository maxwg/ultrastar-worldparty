#!/usr/bin/env python3
"""Repeatable, note-aligned pitch benchmark for the Vocadito solo-vocal set.

The production Pascal harness is intentionally separate. It accepts mono
signed-16-bit little-endian PCM plus a companion ``input.pcm.targets`` file.
Each target record is two little-endian float64 values: target MIDI (or -999
for a rest), then note onset seconds (or -999). It emits one CSV row per
20 ms analysis step with pitch estimates and the production Easy/Medium/Hard
and legacy hit decisions.

Frozen track split: clips 1-10 are development; clips 11-40 are held out.
Use development for tuning. Held-out results should be reported unchanged.
This script uses only the Python standard library.

Example (after building the production harness):
  python tests/vocal_benchmark.py --harness work/vocal-benchmark/pitch_benchmark.exe --tracks 1-10
  python tests/vocal_benchmark.py --harness work/vocal-benchmark/pitch_benchmark.exe --tracks 11-40
"""

from __future__ import annotations

import argparse
import bisect
import csv
import hashlib
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import wave
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


ZENODO_URL = "https://zenodo.org/records/5578807/files/vocadito.zip?download=1"
ARCHIVE_MD5 = "dea40fd18f14d899643c4ba221b33a46"
LICENSE = "CC BY 4.0"
FRAME_SECONDS = 0.020
TIERS = {"Easy": 2.5, "Medium": 1.5, "Hard": 0.5}
REQUIRED_COLUMNS = (
    "time", "valid", "midi", "confidence", "rms", "score_valid",
    "score_midi", "legacy_valid", "legacy_midi", "hit_easy", "hit_medium",
    "hit_hard", "legacy_hit_easy", "legacy_hit_medium", "legacy_hit_hard",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def md5_file(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_receipt(harness: Path, repo: Path) -> Dict[str, Any]:
    """Bind measured binaries to the production source that built them."""
    path = Path(str(harness) + ".sources.json")
    if not path.is_file():
        raise ValueError("Build the harness with tests/run_pitch_tests.ps1 to create its source receipt")
    receipt = json.loads(path.read_text(encoding="utf-8-sig"))
    if receipt["executable_sha256"] != sha256_file(harness):
        raise ValueError("Harness binary changed since its source receipt was created")
    for entry in receipt["files"]:
        if sha256_file(repo / entry["path"]) != entry["sha256"]:
            raise ValueError(f"Rebuild the harness: source changed: {entry['path']}")
    return receipt


def download_archive(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    archive = root / "vocadito.zip"
    if archive.exists() and md5_file(archive) == ARCHIVE_MD5:
        return archive
    temporary = archive.with_suffix(".zip.part")
    print(f"Downloading Vocadito from Zenodo to {archive}", file=sys.stderr)
    try:
        request = urllib.request.Request(ZENODO_URL, headers={"User-Agent": "UltraStarWorldParty-vocal-benchmark/1.0"})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        actual = md5_file(temporary)
        if actual != ARCHIVE_MD5:
            raise ValueError(f"Vocadito archive MD5 mismatch: expected {ARCHIVE_MD5}, got {actual}")
        os.replace(temporary, archive)
    finally:
        if temporary.exists():
            temporary.unlink()
    return archive


def safe_extract(archive: Path, destination: Path) -> None:
    """Extract only archive members that stay under destination."""
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with zipfile.ZipFile(archive) as bundle:
        for info in bundle.infolist():
            member = PurePosixPath(info.filename)
            if member.is_absolute() or ".." in member.parts:
                raise ValueError(f"Unsafe path in dataset archive: {info.filename}")
            if any(part == "__MACOSX" or part.startswith("._") for part in member.parts):
                continue
            target = (destination / Path(*member.parts)).resolve()
            if target != root and root not in target.parents:
                raise ValueError(f"Dataset archive path escapes extraction root: {info.filename}")
        bundle.extractall(destination, [
            info for info in bundle.infolist()
            if not any(part == "__MACOSX" or part.startswith("._")
                       for part in PurePosixPath(info.filename).parts)
        ])


class Dataset:
    def __init__(self, root: Path, allow_download: bool) -> None:
        self.root = root.resolve()
        self.archive = self.root / "vocadito.zip"
        if allow_download and (
            not self.archive.exists() or md5_file(self.archive) != ARCHIVE_MD5
        ):
            self.archive = download_archive(self.root)
        if not (self.root / "Audio").is_dir():
            if not self.archive.exists():
                raise FileNotFoundError(
                    f"Vocadito not found under {self.root}; place Audio/ and Annotations/ there or pass --download"
                )
            expected = ARCHIVE_MD5
            actual = md5_file(self.archive)
            if actual != expected:
                raise ValueError(f"Vocadito archive MD5 mismatch: expected {expected}, got {actual}")
            safe_extract(self.archive, self.root)
        elif self.archive.exists():
            actual = md5_file(self.archive)
            if actual != ARCHIVE_MD5:
                raise ValueError(f"Vocadito archive MD5 mismatch: expected {ARCHIVE_MD5}, got {actual}")
        self.audio_dir = self.root / "Audio"
        self.f0_dir = self.root / "Annotations" / "F0"
        self.notes_dir = self.root / "Annotations" / "Notes"
        self._validate()
        metadata_path = self.root / "vocadito_metadata.csv"
        with metadata_path.open("r", newline="", encoding="utf-8-sig") as source:
            self.metadata = {row["track_id"]: row for row in csv.DictReader(source)}

    def _validate(self) -> None:
        for directory in (self.audio_dir, self.f0_dir, self.notes_dir):
            if not directory.is_dir():
                raise FileNotFoundError(f"Missing required Vocadito directory: {directory}")
        if not (self.root / "vocadito_metadata.csv").is_file():
            raise FileNotFoundError(f"Missing Vocadito metadata: {self.root / 'vocadito_metadata.csv'}")
        for number in range(1, 41):
            missing = [path for path in self.files(number) if not path.is_file()]
            if missing:
                raise FileNotFoundError(f"Missing clip {number} file(s): {', '.join(map(str, missing))}")

    def files(self, number: int) -> Tuple[Path, Path, Path, Path]:
        track = f"vocadito_{number}"
        return (
            self.audio_dir / f"{track}.wav",
            self.f0_dir / f"{track}_f0.csv",
            self.notes_dir / f"{track}_notesA1.csv",
            self.notes_dir / f"{track}_notesA2.csv",
        )


def parse_track_spec(value: str) -> List[int]:
    selected = set()
    for raw in value.split(","):
        token = raw.strip()
        if not token:
            continue
        match = re.fullmatch(r"(\d+)(?:\s*-\s*(\d+))?", token)
        if not match:
            raise argparse.ArgumentTypeError(f"Invalid track selection: {token!r}; use 1-10,11,12")
        start = int(match.group(1))
        end = int(match.group(2) or start)
        if start < 1 or end > 40 or end < start:
            raise argparse.ArgumentTypeError(f"Track range outside 1-40: {token!r}")
        selected.update(range(start, end + 1))
    if not selected:
        raise argparse.ArgumentTypeError("Track selection is empty")
    return sorted(selected)


def select_tracks(split: str, explicit: Optional[str]) -> Tuple[List[int], str]:
    if explicit:
        ids = parse_track_spec(explicit)
        if ids == list(range(1, 11)):
            label = "development"
        elif ids == list(range(11, 41)):
            label = "heldout"
        elif all(number <= 10 for number in ids):
            label = "development-subset"
        elif all(number >= 11 for number in ids):
            label = "heldout-subset"
        else:
            label = "custom-mixed"
        return ids, label
    if split == "development":
        return list(range(1, 11)), split
    if split == "heldout":
        return list(range(11, 41)), split
    return list(range(1, 41)), "all-split"


def parse_numeric_csv(path: Path, columns: int) -> List[Tuple[float, ...]]:
    rows: List[Tuple[float, ...]] = []
    with path.open("r", newline="", encoding="utf-8-sig") as source:
        for line_number, row in enumerate(csv.reader(source), 1):
            if not row or all(not cell.strip() for cell in row):
                continue
            if len(row) != columns:
                raise ValueError(f"{path}:{line_number}: expected {columns} columns, got {len(row)}")
            try:
                numbers = tuple(float(cell.strip()) for cell in row)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: expected numeric CSV row") from exc
            if not all(math.isfinite(number) for number in numbers):
                raise ValueError(f"{path}:{line_number}: non-finite numeric annotation")
            rows.append(numbers)
    return rows


def read_audio_pcm16(path: Path, destination: Path) -> Tuple[int, int, str]:
    """Convert the source WAV to mono S16LE without resampling or normalization."""
    with wave.open(str(path), "rb") as source:
        channels = source.getnchannels()
        width = source.getsampwidth()
        sample_rate = source.getframerate()
        frames = source.getnframes()
        if source.getcomptype() != "NONE":
            raise ValueError(f"Unsupported compressed WAV: {path}")
        raw = source.readframes(frames)
    if channels < 1 or sample_rate <= 0:
        raise ValueError(f"Invalid WAV parameters: {path}")
    bytes_per_frame = channels * width
    if width not in (1, 2, 3, 4) or len(raw) % bytes_per_frame:
        raise ValueError(f"Unsupported PCM sample format or truncated WAV: {path}")
    count = len(raw) // bytes_per_frame
    output = bytearray(count * 2)
    if width == 2 and channels == 1:
        output[:] = raw
    else:
        for frame in range(count):
            base = frame * bytes_per_frame
            total = 0
            for channel in range(channels):
                offset = base + channel * width
                sample_bytes = raw[offset:offset + width]
                if width == 1:
                    sample = (sample_bytes[0] - 128) << 8
                elif width == 2:
                    sample = struct.unpack_from("<h", raw, offset)[0]
                elif width == 3:
                    sample = int.from_bytes(sample_bytes, "little", signed=True) >> 8
                else:
                    sample = struct.unpack_from("<i", raw, offset)[0] >> 16
                total += sample
            mono = max(-32768, min(32767, int(total / channels)))
            struct.pack_into("<h", output, frame * 2, mono)
    destination.write_bytes(output)
    return sample_rate, count, sha256_file(path)


def run_harness(executable: Path, pcm_path: Path, sample_rate: int, output_csv: Path) -> List[Dict[str, float]]:
    completed = subprocess.run(
        [str(executable), str(pcm_path), str(sample_rate), str(output_csv)],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Benchmark harness failed ({completed.returncode}) for {pcm_path.name}:\n{completed.stdout[-4000:]}"
        )
    if not output_csv.is_file():
        raise FileNotFoundError(f"Harness did not create {output_csv}; output: {completed.stdout[-4000:]}")
    result: List[Dict[str, float]] = []
    with output_csv.open("r", newline="", encoding="utf-8-sig") as source:
        reader = csv.DictReader(source)
        missing = set(REQUIRED_COLUMNS) - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{output_csv}: missing output columns {sorted(missing)}")
        for line_number, row in enumerate(reader, 2):
            parsed: Dict[str, float] = {}
            for column in REQUIRED_COLUMNS:
                try:
                    value = row[column].strip().lower()
                    if value in ("true", "yes"):
                        parsed[column] = 1.0
                    elif value in ("false", "no"):
                        parsed[column] = 0.0
                    else:
                        parsed[column] = float(value)
                except (TypeError, ValueError) as exc:
                    raise ValueError(f"{output_csv}:{line_number}: invalid {column} value") from exc
            result.append(parsed)
    return result


def validate_frame_times(estimates: Sequence[Dict[str, float]], sample_rate: int) -> None:
    hop = round(sample_rate * FRAME_SECONDS)
    tolerance = max(2.0 / sample_rate, 1e-7)
    for index, estimate in enumerate(estimates):
        expected = (index + 1) * hop / sample_rate
        if abs(estimate["time"] - expected) > tolerance:
            raise ValueError(
                f"Harness frame {index} time {estimate['time']:.9f} disagrees with "
                f"the fixed-hop time {expected:.9f}"
            )


def nearest_f0(rows: Sequence[Tuple[float, float]], times: Sequence[float], target: float) -> Optional[float]:
    index = bisect.bisect_left(times, target)
    candidates = []
    if index < len(rows):
        candidates.append(rows[index])
    if index > 0:
        candidates.append(rows[index - 1])
    if not candidates:
        return None
    time, frequency = min(candidates, key=lambda item: abs(item[0] - target))
    return frequency if abs(time - target) <= 0.020 else None


def midi_from_hz(frequency: float) -> float:
    return 69.0 + 12.0 * math.log2(frequency / 440.0)


def octave_folded_delta(detected_midi: float, target_midi: float) -> float:
    """Use the game's octave-near-target scoring rule, including its +/-6 edge."""
    delta = detected_midi - target_midi
    while delta > 6.0:
        delta -= 12.0
    while delta < -6.0:
        delta += 12.0
    return delta


def note_at(notes: Sequence[Tuple[float, float, float]], time_seconds: float) -> Optional[Tuple[float, float]]:
    for start, midi, duration in notes:
        if start <= time_seconds < start + duration:
            return midi, start
    return None


def frame_rows(
    estimates: Sequence[Dict[str, float]], f0: Sequence[Tuple[float, float]],
    f0_times: Sequence[float], notes_by_annotator: Dict[str, Sequence[Tuple[float, float, float]]],
    sample_rate: int,
) -> List[Dict[str, Any]]:
    output = []
    for estimate in estimates:
        corrected_time = estimate["time"] - 2048.0 / sample_rate
        reference_hz = nearest_f0(f0, f0_times, corrected_time)
        reference_voiced = reference_hz is not None and reference_hz > 0.0
        note_targets = {annotator: note_at(notes, corrected_time)
                        for annotator, notes in notes_by_annotator.items()}
        output.append({
            "estimate": estimate,
            "target_time": corrected_time,
            "reference_hz": reference_hz,
            "reference_voiced": reference_voiced,
            "note_targets": note_targets,
        })
    return output


def write_targets(
    pcm_path: Path, sample_rate: int, sample_count: int,
    notes: Sequence[Tuple[float, float, float]],
) -> int:
    """Write target MIDI/onset float64le pairs, one per complete 20 ms hop."""
    hop = round(sample_rate * FRAME_SECONDS)
    frame_count = sample_count // hop
    with Path(str(pcm_path) + ".targets").open("wb") as output:
        for frame_index in range(frame_count):
            center = (frame_index + 1) * hop / sample_rate - 2048.0 / sample_rate
            target = note_at(notes, center)
            midi, onset = target if target is not None else (-999.0, -999.0)
            output.write(struct.pack("<dd", midi, onset))
    return frame_count


def distribution(values: Sequence[float]) -> Dict[str, Optional[float]]:
    if not values:
        return {"count": 0, "mean": None, "median": None, "p90": None, "max": None}
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "mean": sum(ordered) / len(ordered),
        "median": ordered[(len(ordered) - 1) // 2],
        "p90": ordered[min(len(ordered) - 1, math.ceil(0.9 * len(ordered)) - 1)],
        "max": ordered[-1],
    }


def detection_metrics(rows: Sequence[Dict[str, Any]], valid_key: str, midi_key: str) -> Dict[str, Any]:
    voiced = [row for row in rows if row["reference_voiced"]]
    unvoiced = [row for row in rows if row["reference_hz"] is not None and not row["reference_voiced"]]
    valid_voiced = [row for row in voiced if row["estimate"][valid_key] >= 0.5]
    valid_unvoiced = [row for row in unvoiced if row["estimate"][valid_key] >= 0.5]
    cents = []
    signed_cents = []
    for row in valid_voiced:
        ref = row["reference_hz"]
        pred_midi = row["estimate"][midi_key]
        if ref and ref > 0 and math.isfinite(pred_midi):
            offset = (pred_midi - midi_from_hz(ref)) * 100.0
            cents.append(abs(offset))
            signed_cents.append(offset)
    return {
        "reference_voiced_frames": len(voiced),
        "reference_unvoiced_frames": len(unvoiced),
        "predicted_voiced_on_voiced_frames": len(valid_voiced),
        "voiced_recall": len(valid_voiced) / len(voiced) if voiced else None,
        "false_voice_rate": len(valid_unvoiced) / len(unvoiced) if unvoiced else None,
        "gross_abs_cents": distribution(cents),
        "signed_cents_mean": sum(signed_cents) / len(signed_cents) if signed_cents else None,
    }


def note_metrics(rows: Sequence[Dict[str, Any]], annotator: str, prefix: str) -> Dict[str, Any]:
    eligible = [row for row in rows if row["note_targets"][annotator] is not None]
    hits: Dict[str, int] = {tier: 0 for tier in TIERS}
    for row in eligible:
        for tier in TIERS:
            column = f"{prefix + '_' if prefix else ''}hit_{tier.lower()}"
            hits[tier] += int(row["estimate"][column] >= 0.5)
    return {
        "annotated_note_frames": len(eligible),
        "frame_seconds": FRAME_SECONDS,
        "score_out_of_10000_excluding_line_bonus": {
            tier: round(10000.0 * count / len(eligible), 2) if eligible else None
            for tier, count in hits.items()
        },
        "hits": hits,
    }


def shifted_control_metrics(rows: Sequence[Dict[str, Any]], annotator: str) -> Dict[str, Any]:
    """Model the deliberate +4-semitone wrong-note control from measured MIDI."""
    eligible = [row for row in rows if row["note_targets"][annotator] is not None]
    hits: Dict[str, int] = {tier: 0 for tier in TIERS}
    for row in eligible:
        estimate = row["estimate"]
        if estimate["score_valid"] < 0.5:
            continue
        target = row["note_targets"][annotator][0]
        delta = abs(octave_folded_delta(estimate["score_midi"] + 4.0, target))
        for tier, tolerance in TIERS.items():
            if delta <= tolerance:
                hits[tier] += 1
    return {
        "control_type": "modeled measured MIDI + 4 semitones; not a second audio pass",
        "annotated_note_frames": len(eligible),
        "frame_seconds": FRAME_SECONDS,
        "score_out_of_10000_excluding_line_bonus": {
            tier: round(10000.0 * count / len(eligible), 2) if eligible else None
            for tier, count in hits.items()
        },
        "hits": hits,
    }


def summarize_track(
    estimates: Sequence[Dict[str, float]], f0: Sequence[Tuple[float, float]],
    notes_by_annotator: Dict[str, Sequence[Tuple[float, float, float]]],
    sample_rate: int,
) -> Dict[str, Any]:
    f0_times = [row[0] for row in f0]
    rows = frame_rows(estimates, f0, f0_times, notes_by_annotator, sample_rate)
    note_results = {}
    for annotator in sorted(notes_by_annotator):
        note_results[annotator] = {
            "production_score_hits": note_metrics(rows, annotator, ""),
            "legacy_score_hits": note_metrics(rows, annotator, "legacy"),
            "score_detector_plus_four_semitones_control": shifted_control_metrics(rows, annotator),
        }
    return {
        "analysis_latency_compensation_seconds": 2048.0 / sample_rate,
        "frame_count": len(rows),
        "f0_tracking": detection_metrics(rows, "valid", "midi"),
        "legacy_f0_tracking": detection_metrics(rows, "legacy_valid", "legacy_midi"),
        "note_scoring_by_annotator": note_results,
    }


def summary_tracks(track_results: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    # benchmark_track deliberately returns provenance and a nested metrics
    # object. Keep summary traversal on that exact public result shape.
    metric_results = [track.get("metrics", track) for track in track_results]

    def gather(path: Sequence[str], metric: str) -> Tuple[float, int]:
        values = []
        count = 0
        for track in metric_results:
            value: Any = track
            for key in path:
                value = value[key]
            if metric in value and value[metric] is not None:
                values.append(float(value[metric]))
                count += 1
        return (sum(values) / len(values) if values else 0.0, count)

    f0_fields = ("f0_tracking",)
    legacy_fields = ("legacy_f0_tracking",)
    f0_recall, f0_recall_tracks = gather(f0_fields, "voiced_recall")
    f0_false, f0_false_tracks = gather(f0_fields, "false_voice_rate")
    f0_cents, f0_cents_tracks = gather(f0_fields + ("gross_abs_cents",), "mean")
    old_recall, old_recall_tracks = gather(legacy_fields, "voiced_recall")
    old_false, old_false_tracks = gather(legacy_fields, "false_voice_rate")
    old_cents, old_cents_tracks = gather(legacy_fields + ("gross_abs_cents",), "mean")
    note = {}
    for annotator in ("A1", "A2"):
        note[annotator] = {}
        for detector in ("production_score_hits", "legacy_score_hits", "score_detector_plus_four_semitones_control"):
            note[annotator][detector] = {}
            for tier in TIERS:
                path = ("note_scoring_by_annotator", annotator, detector,
                        "score_out_of_10000_excluding_line_bonus")
                vals = []
                for track in metric_results:
                    score = track
                    for key in path:
                        score = score[key]
                    if score.get(tier) is not None:
                        vals.append(float(score[tier]))
                note[annotator][detector][tier] = {
                    "macro_mean_out_of_10000": sum(vals) / len(vals) if vals else None,
                    "tracks": len(vals),
                }
    silence = {}
    for annotator in ("A1", "A2"):
        silence[annotator] = {}
        for detector, valid_key in (("new", "new_false_voice_rate"),
                                    ("legacy", "legacy_false_voice_rate")):
            values = [
                float(track["actual_silence_negative_control"]["annotators"][annotator][valid_key])
                for track in metric_results
                if track["actual_silence_negative_control"]["annotators"][annotator][valid_key] is not None
            ]
            silence[annotator][detector] = {
                "macro_false_voice_rate": sum(values) / len(values) if values else None,
                "tracks": len(values),
            }
        silence[annotator]["production_note_score_out_of_10000"] = {
            tier: {
                "macro_mean": sum(
                    float(track["actual_silence_negative_control"]["annotators"][annotator]
                          ["production_score_hits"]["score_out_of_10000_excluding_line_bonus"][tier])
                    for track in metric_results
                ) / len(track_results) if track_results else None,
                "tracks": len(track_results),
            }
            for tier in TIERS
        }
    return {
        "tracks": len(track_results),
        "macro_mean_f0_tracking": {
            "new": {"voiced_recall": f0_recall, "false_voice_rate": f0_false,
                    "gross_abs_cents": f0_cents,
                    "tracks": min(f0_recall_tracks, f0_false_tracks, f0_cents_tracks)},
            "legacy": {"voiced_recall": old_recall, "false_voice_rate": old_false,
                       "gross_abs_cents": old_cents,
                       "tracks": min(old_recall_tracks, old_false_tracks, old_cents_tracks)},
        },
        "note_scoring": note,
        "actual_silence_negative_control": silence,
    }


def summary_shape_smoke_test() -> None:
    """Exercise summary aggregation using benchmark_track's nested return shape."""
    scoring = {
        detector: {"score_out_of_10000_excluding_line_bonus": {tier: 10000.0 for tier in TIERS}}
        for detector in ("production_score_hits", "legacy_score_hits",
                         "score_detector_plus_four_semitones_control")
    }
    # Keep note-scoring and silence in their distinct production report locations.
    silence_annotators = {
        name: {
            "new_false_voice_rate": 0.0,
            "legacy_false_voice_rate": 0.0,
            "production_score_hits": scoring["production_score_hits"],
        }
        for name in ("A1", "A2")
    }
    one_track = {
        "track_id": 1,
        "metrics": {
            "f0_tracking": {"voiced_recall": 0.75, "false_voice_rate": 0.10,
                            "gross_abs_cents": {"mean": 25.0}},
            "legacy_f0_tracking": {"voiced_recall": 0.50, "false_voice_rate": 0.20,
                                   "gross_abs_cents": {"mean": 50.0}},
            "note_scoring_by_annotator": {
                name: {key: scoring[key] for key in scoring}
                for name in ("A1", "A2")
            },
            "actual_silence_negative_control": {"annotators": silence_annotators},
        },
    }
    summary = summary_tracks([one_track])
    assert summary["tracks"] == 1
    assert summary["macro_mean_f0_tracking"]["new"]["voiced_recall"] == 0.75
    assert summary["note_scoring"]["A1"]["production_score_hits"]["Hard"]["macro_mean_out_of_10000"] == 10000.0
    assert summary["actual_silence_negative_control"]["A2"]["production_note_score_out_of_10000"]["Easy"]["macro_mean"] == 10000.0


def parse_wav_notes(path: Path) -> Tuple[List[Tuple[float, float, float]], str]:
    rows = parse_numeric_csv(path, 3)
    notes = []
    for start, frequency, duration in rows:
        if frequency <= 0 or duration <= 0:
            continue
        # UltraStar chart notes are integer MIDI pitches; use deterministic
        # half-up rounding, leaving the frame-level human F0 untouched.
        chart_midi = math.floor(midi_from_hz(frequency) + 0.5)
        notes.append((start, float(chart_midi), duration))
    notes.sort(key=lambda note: note[0])
    return notes, sha256_file(path)


def benchmark_track(
    dataset: Dataset, executable: Path, number: int, temporary: Path,
) -> Dict[str, Any]:
    audio_path, f0_path, a1_path, a2_path = dataset.files(number)
    pcm_path = temporary / f"vocadito_{number}.pcm"
    sample_rate, sample_count, audio_sha = read_audio_pcm16(audio_path, pcm_path)
    f0 = parse_numeric_csv(f0_path, 2)
    notes_a1, a1_sha = parse_wav_notes(a1_path)
    notes_a2, a2_sha = parse_wav_notes(a2_path)
    notes_by_annotator = {"A1": notes_a1, "A2": notes_a2}
    expected_frames = sample_count // round(sample_rate * FRAME_SECONDS)
    estimates_by_annotator = {}
    aligned_by_annotator = {}
    f0_times = [row[0] for row in f0]
    for annotator, notes in notes_by_annotator.items():
        target_frames = write_targets(pcm_path, sample_rate, sample_count, notes)
        if target_frames != expected_frames:
            raise AssertionError("target frame count calculation changed unexpectedly")
        output_path = temporary / f"vocadito_{number}_{annotator}.csv"
        estimates = run_harness(executable, pcm_path, sample_rate, output_path)
        if len(estimates) != expected_frames:
            raise ValueError(
                f"Harness emitted {len(estimates)} frames for clip {number}; "
                f"expected {expected_frames} complete 20 ms hops for .targets"
            )
        validate_frame_times(estimates, sample_rate)
        estimates_by_annotator[annotator] = estimates
        aligned_by_annotator[annotator] = frame_rows(
            estimates, f0, f0_times, notes_by_annotator, sample_rate
        )

    metrics = summarize_track(estimates_by_annotator["A1"], f0, notes_by_annotator, sample_rate)
    for annotator, rows in aligned_by_annotator.items():
        metrics["note_scoring_by_annotator"][annotator] = {
            "production_score_hits": note_metrics(rows, annotator, ""),
            "legacy_score_hits": note_metrics(rows, annotator, "legacy"),
            "score_detector_plus_four_semitones_control": shifted_control_metrics(rows, annotator),
        }

    silence_path = temporary / f"vocadito_{number}_silence.pcm"
    silence_path.write_bytes(bytes(sample_count * 2))
    silence_by_annotator = {}
    for annotator, notes in notes_by_annotator.items():
        write_targets(silence_path, sample_rate, sample_count, notes)
        silence_output = temporary / f"vocadito_{number}_silence_{annotator}.csv"
        silence_estimates = run_harness(executable, silence_path, sample_rate, silence_output)
        if len(silence_estimates) != expected_frames:
            raise ValueError(
                f"Harness emitted {len(silence_estimates)} silence frames for clip {number}; "
                f"expected {expected_frames} complete 20 ms hops for .targets"
            )
        validate_frame_times(silence_estimates, sample_rate)
        silence_rows = frame_rows(silence_estimates, f0, f0_times, notes_by_annotator, sample_rate)
        valid_frames = sum(row["valid"] >= 0.5 for row in silence_estimates)
        legacy_valid_frames = sum(row["legacy_valid"] >= 0.5 for row in silence_estimates)
        silence_by_annotator[annotator] = {
            "frames": len(silence_estimates),
            "new_valid_frames": valid_frames,
            "new_false_voice_rate": valid_frames / len(silence_estimates) if silence_estimates else None,
            "legacy_valid_frames": legacy_valid_frames,
            "legacy_false_voice_rate": legacy_valid_frames / len(silence_estimates) if silence_estimates else None,
            "production_score_hits": note_metrics(silence_rows, annotator, ""),
            "legacy_score_hits": note_metrics(silence_rows, annotator, "legacy"),
        }
    first_silence = silence_by_annotator["A1"]
    metrics["actual_silence_negative_control"] = {
        "annotators": silence_by_annotator,
        "frames": first_silence["frames"],
        "new_valid_frames": first_silence["new_valid_frames"],
        "new_false_voice_rate": first_silence["new_false_voice_rate"],
        "legacy_valid_frames": first_silence["legacy_valid_frames"],
        "legacy_false_voice_rate": first_silence["legacy_false_voice_rate"],
    }
    return {
        "track_id": number,
        "source_files": {
            "audio": str(audio_path.relative_to(dataset.root)),
            "audio_sha256": audio_sha,
            "f0": str(f0_path.relative_to(dataset.root)),
            "f0_sha256": sha256_file(f0_path),
            "notes_a1": str(a1_path.relative_to(dataset.root)),
            "notes_a1_sha256": a1_sha,
            "notes_a2": str(a2_path.relative_to(dataset.root)),
            "notes_a2_sha256": a2_sha,
        },
        "sample_rate": sample_rate,
        "sample_count": sample_count,
        "duration_seconds": sample_count / sample_rate,
        "metrics": metrics,
    }


def main() -> int:
    script_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, default=script_root / "work" / "vocal-benchmark",
                        help="Vocadito root containing Audio/ and Annotations/ (default: work/vocal-benchmark)")
    parser.add_argument("--download", action="store_true",
                        help="fetch the official archive if missing; verify its published MD5 before extraction")
    parser.add_argument("--harness", type=Path,
                        help="production pitch_benchmark executable built by the parent integration")
    parser.add_argument("--self-test", action="store_true",
                        help="run a cheap summary aggregation smoke test and exit")
    parser.add_argument("--output-dir", type=Path, default=script_root / "work" / "vocal-benchmark" / "results",
                        help="directory for JSON reports (default: work/vocal-benchmark/results)")
    parser.add_argument("--split", choices=("development", "heldout", "all"), default="development",
                        help="frozen split; default development (clips 1-10)")
    parser.add_argument("--tracks", type=str,
                        help="explicit clip IDs/ranges (for example 1-10 or 11-40); overrides --split")
    args = parser.parse_args()

    try:
        summary_shape_smoke_test()
        if args.self_test:
            print("Summary shape smoke test passed.")
            return 0
        if args.harness is None:
            parser.error("--harness is required unless --self-test is used")
        dataset = Dataset(args.dataset_root, args.download)
        harness = args.harness.resolve(strict=True)
        if not harness.is_file():
            raise FileNotFoundError(f"Not a harness file: {harness}")
        track_ids, split_label = select_tracks(args.split, args.tracks)
        output_dir = args.output_dir.resolve()
        output_dir.mkdir(parents=True, exist_ok=True)
        track_dir = output_dir / "tracks"
        track_dir.mkdir(parents=True, exist_ok=True)
        created_utc = datetime.now(timezone.utc).isoformat()
        dataset_report = {
            "name": "Vocadito: a dataset of solo vocals with f0, note, and lyric annotations",
            "source": "https://zenodo.org/records/5578807",
            "license": LICENSE,
            "archive_md5_expected": ARCHIVE_MD5,
            "archive_md5_actual": md5_file(dataset.archive) if dataset.archive.exists() else None,
            "archive_sha256": sha256_file(dataset.archive) if dataset.archive.exists() else None,
            "metadata_sha256": sha256_file(dataset.root / "vocadito_metadata.csv")
            if (dataset.root / "vocadito_metadata.csv").is_file() else None,
        }
        harness_report = {"path": str(harness), "sha256": sha256_file(harness),
                          "source_receipt": source_receipt(harness, script_root)}
        split_report = {
            "label": split_label,
            "development_tracks": "1-10",
            "heldout_tracks": "11-40",
            "selected_tracks": track_ids,
            "analysis_latency_policy": "fixed 2048-sample analysis-window center for both detectors; no per-track tuning",
            "note_score_policy": "production hit columns aggregated by eligible 20 ms note frames, normalized to 10000; excludes line bonus",
            "tiers_semitones_after_octave_fold": TIERS,
            "note_annotations": "A1 and A2 evaluated separately",
            "note_chart_quantization": "annotation Hz converted to MIDI and rounded half-up with floor(midi + 0.5); human frame-level F0 remains unrounded",
        }
        script_sha = sha256_file(Path(__file__).resolve())
        print(f"Vocadito {split_label}: {len(track_ids)} tracks; harness={harness}")
        if any(number >= 11 for number in track_ids):
            print("HELD-OUT split selected; keep results frozen and do not tune against these clips.")
        with tempfile.TemporaryDirectory(prefix="vocadito-benchmark-") as temporary_name:
            temporary = Path(temporary_name)
            results = []
            for index, number in enumerate(track_ids, 1):
                print(f"[{index}/{len(track_ids)}] vocadito_{number}", flush=True)
                result = benchmark_track(dataset, harness, number, temporary)
                results.append(result)
                # Persist each completed track immediately, so a later bad
                # clip or summary issue cannot discard successful measurements.
                track_report = {
                    "schema_version": 1,
                    "created_utc": created_utc,
                    "dataset": dataset_report,
                    "harness": harness_report,
                    "benchmark_script_sha256": script_sha,
                    "split_policy": split_report,
                    "track": result,
                }
                track_path = track_dir / f"vocal-benchmark-{split_label}-vocadito_{number}.json"
                track_path.write_text(json.dumps(track_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        report = {
            "schema_version": 1,
            "created_utc": created_utc,
            "dataset": dataset_report,
            "harness": harness_report,
            "benchmark_script_sha256": script_sha,
            "split_policy": split_report,
            "summary": summary_tracks(results),
            "tracks": results,
        }
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        track_paths = []
        for result in results:
            track_path = track_dir / f"vocal-benchmark-{split_label}-vocadito_{result['track_id']}.json"
            track_report = {
                "schema_version": report["schema_version"],
                "created_utc": report["created_utc"],
                "dataset": report["dataset"],
                "harness": report["harness"],
                "benchmark_script_sha256": report["benchmark_script_sha256"],
                "split_policy": report["split_policy"],
                "track": result,
            }
            track_path.write_text(json.dumps(track_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            track_paths.append(str(track_path))
        report["per_track_reports"] = track_paths
        report_path = output_dir / f"vocal-benchmark-{split_label}-{stamp}.json"
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        latest_path = output_dir / f"latest-{split_label}.json"
        latest_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Wrote {report_path}")
        print(json.dumps(report["summary"], indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
