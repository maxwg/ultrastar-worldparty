# Pitch practice display

This build defaults two independent settings to On in the `[Advanced]` INI section:

- `NoteNames`: labels target notes with scientific note names (e.g. G#4).
- `DetectedPitch`: displays continuous detected frequency, nearest note and cents offset, plus a subtle volume-weighted continuous pitch trace above the note bars.

Both controls are also available in Options → Advanced. During singing, F6 toggles note names and F7 toggles detected pitch. Settings persist. Scoring is unchanged. Rap/freestyle notes have no pitched label. Labels too wide for their target note are omitted to avoid collisions.

The display estimator consumes captured PCM directly, independently of the existing semitone-only scoring detector. It covers 50–1500 Hz, analyzes only the newest 4096 samples, rejects non-finite sample rates, and uses a normalized difference minimum with sub-sample interpolation. It never snaps the plotted pitch to a semitone or folds it into the target octave. Frequency is an estimate, not a ground-truth measurement; noise, polyphony, microphone quality and strong harmonics can affect it. Silence/DC/unvoiced noise are rejected in deterministic tests.

The official UltraStar format defines pitch zero as C4/MIDI 60: https://usdx.eu/format/. The overlay uses this exact coordinate convention. Off-screen pitch is identified as above/below range rather than silently octave-shifted. Current pitch is hidden while paused or outside the displayed phrase.

`tests/pitch_display_test.pas` exercises the real estimator at 44.1/48 kHz, fractional pitches, RMS volume, silence, DC, noise and invalid input. These synthetic tests do not establish live microphone accuracy or SDL rendering correctness.

The latest regression corpus also covers low/high-register voices with a stronger second harmonic, moderate noise, long-buffer freshness and invalid floating-point rates. The trace is cleared across pause and display toggles rather than connecting stale segments.
