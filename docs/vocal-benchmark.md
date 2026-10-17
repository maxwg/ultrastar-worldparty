# Recorded-vocal benchmark

[Results JSON](../tests/fixtures/vocal-benchmark-results.json) records the final
40-clip run, per-recording metrics, dataset/annotation hashes, executable hash
and exact production-source hashes. No audio is committed.

The source is [Vocadito v3](https://zenodo.org/records/5578807), by Rachel Bittner,
Katherine Pasalo, Juan Jose Bosch, Gabriel Meseguer Brocal and David Rubinstein
(CC BY 4.0). It contains actual solo singing, human F0 labels and two independent
note annotations. The published archive MD5 is verified before extraction.

Clips 1–10 are development recordings; 11–40 form the fixed held-out group.
The split is by recording, not guaranteed to be by singer. No thresholds were
tuned to held-out results. Each clip uses mono PCM and a 20 ms analysis hop.
Human note frequencies become integer chart notes by nearest-semitone rounding;
F0 reference labels stay continuous. Both pipelines use the same trailing
4096 samples and fixed 2048-sample window-center compensation, without individual
alignment adjustments.

## Held-out results

Mean note-only score out of 10,000 across the 30 held-out recordings. A1/A2 are
the two independent note annotations. The old pipeline uses its original coarse
detector and default 10% gate; the new pipeline uses Auto sensitivity and the
shared continuous tracker. These gains reflect the combined change.

| Difficulty | Previous A1 | Previous A2 | New A1 | New A2 |
| --- | ---: | ---: | ---: | ---: |
| Easy | 6,739 | 6,734 | 9,280 | 9,281 |
| Medium | 6,672 | 6,600 | 9,153 | 9,061 |
| Hard | 5,191 | 5,057 | 7,121 | 6,953 |

Actual digital-silence input scores **0** throughout. A modeled +4-semitone
wrong-pitch control averages 150/281 on Easy (A1/A2), far below correct singing.
The real game also scores actual +4-semitone microphone PCM and silence at zero;
correct synthetic singing and unpitched rap each earn all 9,000 note points.

Filtered-pitch voiced recall rises from 67.8% to 92.7%; mean absolute pitch error
on detected voiced frames falls from 72.9 to 36.5 cents. False voice detections
on human-labeled unvoiced frames rise slightly, from 14.3% to 15.2%. Silence and
wrong-note controls remain separate from these annotation-boundary statistics.

The offline score aggregates production matching decisions over eligible 20 ms
note frames, normalized to 10,000. It excludes golden-note weighting, line
bonuses and the game's beat clock. The Windows E2E test separately exercises
actual score accumulation and rendering. Reference notes describe the recorded
performances; this is not a test against independently published song sheets.
It does not reproduce room noise, accompaniment bleed or hardware latency.

## Reproduce

```powershell
tests\run_pitch_tests.ps1 -CompilerRoot <root> -Capture
tests\run_pitch_tests.ps1 -CompilerRoot <root> -Vocals -Split all
tests\library_e2e\run.ps1 -CompilerRoot <root>
tests\library_e2e\run.ps1 -CompilerRoot <root> -PitchControl wrong
tests\library_e2e\run.ps1 -CompilerRoot <root> -PitchControl silence
tests\library_e2e\run.ps1 -CompilerRoot <root> -PitchControl rap
```

The vocal runner downloads the 58.5 MB archive to ignored `work/vocal-benchmark`
and writes JSON receipts there. `--self-test` on `tests/vocal_benchmark.py`
checks report aggregation without downloading or running audio. The build
receipt rejects a stale harness if its production source has changed.
