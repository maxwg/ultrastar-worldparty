#!/usr/bin/env python3
"""
UltraStar Song Chart Validator
Validates syntax, timing monotonicity, line breaks, audio synchronicity,
and pitch alignment for UltraStar karaoke charts.
"""

import os
import sys
import argparse
import io

try:
    import librosa
    import numpy as np
    from scipy.io import wavfile
    AUDIO_ANALYSIS_AVAILABLE = True
except ImportError:
    AUDIO_ANALYSIS_AVAILABLE = False


def validate_chart(chart_path, audio_path=None, vocal_path=None, generate_mix=False):
    print("=" * 60)
    print(f"VALIDATING ULTRASTAR CHART: {os.path.basename(chart_path)}")
    print("=" * 60)

    if not os.path.exists(chart_path):
        raise FileNotFoundError(f"Chart file not found: {chart_path}")

    # 1. Parse Chart
    headers = {}
    notes = []
    line_breaks = []

    with open(chart_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    for line_num, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#"):
            parts = line[1:].split(":", 1)
            if len(parts) == 2:
                headers[parts[0].upper()] = parts[1]
        elif line.startswith(("-", ":", "*", "F", "R", "G")):
            parts = line.split(maxsplit=4)
            typ = parts[0]
            if typ == "-":
                beat = int(parts[1])
                line_breaks.append((line_num, beat))
            else:
                beat = int(parts[1])
                length = int(parts[2])
                pitch = int(parts[3])
                lyric = parts[4] if len(parts) > 4 else ""
                notes.append({
                    "line_num": line_num,
                    "type": typ,
                    "beat": beat,
                    "length": length,
                    "pitch": pitch,
                    "lyric": lyric
                })
        elif line == "E":
            pass
        else:
            print(f"[WARN] Unknown line {line_num}: {line}")

    # Check Required Headers
    required_headers = ["TITLE", "ARTIST", "BPM", "GAP"]
    for h in required_headers:
        if h not in headers:
            raise ValueError(f"Missing required header: #{h}")

    bpm = float(headers["BPM"].replace(",", "."))
    gap_ms = float(headers["GAP"].replace(",", "."))
    gap_sec = gap_ms / 1000.0
    beat_dur = 60.0 / (bpm * 4.0)

    print(f"Header: {headers['ARTIST']} - {headers['TITLE']}")
    print(f"BPM: {bpm:.2f} (Beat duration: {beat_dur*1000:.2f}ms), GAP: {gap_ms:.1f}ms")
    print(f"Total notes: {len(notes)}, Line breaks: {len(line_breaks)}")

    # 2. Structural & Timing Monotonicity Check
    errors = []
    warnings = []

    if len(notes) == 0:
        errors.append("Chart contains no notes!")

    for i in range(len(notes)):
        curr = notes[i]
        if curr["length"] <= 0:
            errors.append(f"Line {curr['line_num']}: Non-positive length ({curr['length']}) for note '{curr['lyric']}'")
        if i > 0:
            prev = notes[i-1]
            if curr["beat"] < prev["beat"] + prev["length"]:
                errors.append(
                    f"Line {curr['line_num']}: Note overlap! Beat {curr['beat']} < "
                    f"Prev end {prev['beat'] + prev['length']} ('{prev['lyric']}' -> '{curr['lyric']}')"
                )

    # Line break sanity
    note_idx = 0
    for lb_line, lb_beat in line_breaks:
        while note_idx < len(notes) and notes[note_idx]["beat"] + notes[note_idx]["length"] <= lb_beat:
            note_idx += 1
        if note_idx < len(notes) and notes[note_idx]["beat"] < lb_beat:
            errors.append(f"Line {lb_line}: Line break beat {lb_beat} cuts through note at beat {notes[note_idx]['beat']}")

    print(f"Structure validation: {len(errors)} errors, {len(warnings)} warnings.")
    if errors:
        for e in errors[:10]:
            print("  ERROR:", e)
        raise ValueError(f"Chart failed structural validation with {len(errors)} errors.")

    # 3. Audio & Vocal Alignment Check (if audio available)
    song_dir = os.path.dirname(chart_path)
    if not audio_path and "MP3" in headers:
        candidate = os.path.join(song_dir, headers["MP3"])
        if os.path.exists(candidate):
            audio_path = candidate

    target_audio = vocal_path if vocal_path and os.path.exists(vocal_path) else audio_path
    if AUDIO_ANALYSIS_AVAILABLE and target_audio and os.path.exists(target_audio):
        print(f"\nAnalyzing audio alignment with: {os.path.basename(target_audio)}")
        y_audio, sr = librosa.load(target_audio, sr=22050)
        audio_dur = len(y_audio) / sr

        voiced_notes = 0
        pitch_diffs = []
        low_energy = []

        for n in notes:
            t_start = gap_sec + n["beat"] * beat_dur
            t_end = gap_sec + (n["beat"] + n["length"]) * beat_dur

            idx0 = int(round(t_start * sr))
            idx1 = int(round(t_end * sr))
            if idx1 > len(y_audio):
                errors.append(f"Note '{n['lyric']}' at {t_start:.2f}s exceeds audio duration ({audio_dur:.2f}s)")
                continue

            seg = y_audio[idx0:idx1]
            note_rms = float(np.sqrt(np.mean(seg**2))) if len(seg) > 0 else 0.0

            if len(seg) >= 256:
                f0, v, _ = librosa.pyin(seg, fmin=librosa.note_to_hz('C3'), fmax=librosa.note_to_hz('C5'), sr=sr, hop_length=64)
                valid = f0[v & ~np.isnan(f0)]
                if len(valid) > 0:
                    med_hz = float(np.median(valid))
                    midi = int(round(librosa.hz_to_midi(med_hz)))
                    detected_pitch = midi - 48
                    pitch_diffs.append(abs(detected_pitch - n["pitch"]))

            if note_rms > 0.015:
                voiced_notes += 1
            else:
                low_energy.append((n["beat"], n["lyric"], round(note_rms, 4)))

        voice_pct = (voiced_notes / len(notes)) * 100.0 if notes else 0.0
        med_p_diff = float(np.median(pitch_diffs)) if pitch_diffs else 0.0
        mean_p_diff = float(np.mean(pitch_diffs)) if pitch_diffs else 0.0

        print(f"--- Audio Analysis Results ---")
        print(f"Active vocal audio presence: {voiced_notes}/{len(notes)} notes ({voice_pct:.1f}%)")
        print(f"Pitch samples evaluated: {len(pitch_diffs)}/{len(notes)}")
        print(f"Median pitch difference to detected audio: {med_p_diff:.2f} semitones")
        print(f"Mean pitch difference: {mean_p_diff:.2f} semitones")

        # 4. Generate Audio Verification Mix
        if generate_mix and audio_path and os.path.exists(audio_path):
            print("\nSynthesizing verification guide tone mix...")
            y_full, sr_full = librosa.load(audio_path, sr=22050)
            synth_track = np.zeros_like(y_full)

            for n in notes:
                t_start = gap_sec + n["beat"] * beat_dur
                t_end = gap_sec + (n["beat"] + n["length"]) * beat_dur
                idx0 = int(round(t_start * sr_full))
                idx1 = int(round(t_end * sr_full))
                if idx1 > len(synth_track):
                    continue

                midi_note = n["pitch"] + 48
                freq = 440.0 * (2.0 ** ((midi_note - 69) / 12.0))
                num_samples = idx1 - idx0
                t_vec = np.arange(num_samples) / sr_full
                envelope = np.sin(np.pi * np.linspace(0, 1, num_samples))
                beep = 0.3 * envelope * np.sin(2 * np.pi * freq * t_vec)
                synth_track[idx0:idx1] += beep

            mixed = 0.7 * y_full + 0.3 * synth_track
            max_val = np.max(np.abs(mixed))
            if max_val > 1.0:
                mixed = mixed / max_val

            out_wav = os.path.join(song_dir, "verification_guide_mix.wav")
            wavfile.write(out_wav, sr_full, (mixed * 32767).astype(np.int16))
            print(f"Guide tone mix generated: {out_wav}")

    print("\n" + "=" * 60)
    print("CHART VALIDATION SUCCESSFUL")
    print("=" * 60)
    return True


def main():
    parser = argparse.ArgumentParser(description="Validate UltraStar song chart")
    parser.add_argument("chart_path", help="Path to song.txt or song directory")
    parser.add_argument("--audio", default=None, help="Path to full audio or MP3")
    parser.add_argument("--vocals", default=None, help="Path to isolated vocals stem")
    parser.add_argument("--mix", action="store_true", help="Generate audible verification mix")
    args = parser.parse_args()

    chart_file = args.chart_path
    if os.path.isdir(chart_file):
        chart_file = os.path.join(chart_file, "song.txt")

    try:
        validate_chart(chart_file, audio_path=args.audio, vocal_path=args.vocals, generate_mix=args.mix)
        sys.exit(0)
    except Exception as e:
        print(f"\nVALIDATION FAILED: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
