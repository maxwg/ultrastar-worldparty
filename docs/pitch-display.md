# Pitch and microphone feedback

The thin, stable pitch trace is **On by default**. It replaces the thick sung
bars while retaining the target notes. It follows fractional pitch rather than
snapping to a target; octave folding matches UltraStar's scoring convention.
A fixed width, contrasting outline, short smoothing filter and rejection of
single-frame octave glitches keep it readable. Unvoiced passages break the line.

- **F6 / NoteNames:** target note labels (C4, G#4).
- **F7 / DetectedPitch:** thin trace; Off restores the original sung bars.
- **F8 / PitchReadout:** optional true sung note, Hz and cents. Off by default.

These switches persist under `[Advanced]` and are available in Options → Advanced.
The readout keeps the actual sung octave even when the trace is folded to the
chart. Chart pitch zero is C4/MIDI 60, per the [UltraStar format](https://usdx.eu/format/).
Pause, phrase changes and capture gaps clear stale connections. Rap/freestyle
notes have no scientific pitch label.

## Shared detector and scoring

Display and scoring use the same continuous YIN-style normalized-difference
estimator with sub-sample interpolation. Its source is the original
[YIN method](https://doi.org/10.1121/1.1458024). Analysis updates at most every
20 ms when fresh PCM is available, independently of score beats. Repeated calls
reuse the result. The capture mutex protects only a short PCM snapshot, never DSP.
Bounded, decimated analysis uses fixed scratch arrays rather than per-frame
allocations. The input window remains the newest 4096 samples.

Easy remains the default. The traditional Easy/Medium/Hard tolerances are
preserved, including the half-semitone quantization margin. Brief unvoiced gaps
may keep the last pitch for **at most 60 ms**, only inside an already-hit chart
note. A new note, sustained silence or confidently wrong pitch cannot use this
allowance. Rap keeps its energy-based activity scoring, including unpitched
syllables. The visible line never fills these unvoiced gaps. Disconnected capture
expires after 250 ms and clears both display and scoring state.

## Automatic microphone sensitivity

Options → Microphones → Threshold now defaults to **Auto**. It adapts the voice
gate per channel to the unvoiced noise floor and normalizes pitch comparisons,
so a quiet microphone does not need manual boost to score. Noise-floor increases
are slow; decreases are fast, preventing a breath from hiding the next vowel.
Continuous voiced input does not train the noise floor. The previous 5–20%
manual gates remain available and existing saved manual choices are preserved.
This installation selects Auto. Existing device/player assignments and manual
volume/boost controls remain available. Auto sensitivity does not repair already
clipped audio or measure hardware latency.

## Verification

`tests/run_pitch_tests.ps1 -CompilerRoot <root>` builds and runs synthetic
pitch/tracker regressions. They cover fractional pitch, strong harmonics, noise,
quiet voices, vibrato, real jumps, octave glitches, grace expiry and difficulty
boundaries. `record_capture_state_test.pas` additionally checks the production
capture path, channel remapping, reconnect, cache reuse and stale input.

`tests/library_e2e/run.ps1` injects two chart-aligned synthetic microphone notes
through the real capture path in the Windows SDL/OpenGL application. It checks
actual score accumulation and captures singing screenshots, alongside search,
download and restart tests. It uses dummy playback audio, not physical hardware.

The [real-vocal benchmark](vocal-benchmark.md) uses isolated human singing and
independent note/F0 annotations. Synthetic and recorded-audio tests cannot prove
live accuracy for every microphone, room or singer. Capture backends normally
use 44.1 kHz; 50–1500 Hz coverage is tested at 44.1/48 kHz. At unusually high
sample rates, the fixed window limits low-frequency coverage (about 95 Hz at
192 kHz). Overlapping singers or loud backing music can also confuse a
monophonic pitch detector.
