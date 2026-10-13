# Local Linux verification, 2026-10-13

- Base WorldParty: 556539dfbdee70416071982f83246c8185159bcd.
- USDX reference: c88370cc5c8e46f3cb685bd95aeb582fbd5dedb9.
- Final optimized release rebuild and synthetic-input runtime both pass (exit 0).
- Full FPC 3.2.2 Linux build passes with the bundled Pascal FFmpeg 4.x bindings and official FFmpeg 4.2.7 C libraries. The directory named ffmpeg-4.0 actually requires libavutil >=56.31 and libavcodec >=58.54; FFmpeg 4.0 is too old, and modern FFmpeg 7 is incompatible.
- 17 artist-navigation assertions passed (79 deterministic assertions total).
- 62 real-estimator assertions passed, covering 44.1/48 kHz fractional tones, RMS volume, silence, DC, noise, non-finite rates, harmonic low/high-register voices, and newest-window selection.
- SDL offscreen OpenGL runtime: actual screens captured via test-only LD_PRELOAD hook. Four locally synthesized copyright-free fixtures; synthetic PCM capture passes through the actual audio callback and production pitch estimator.
- Artist rail clicking B and Z selected Baker and Zebra, respectively; the selected letter highlighted correctly.
- Target C4/D4/E4/G4 labels and unsnapped C4 frequency/cents were visibly rendered. Scoring bars remained separate. The synthetic frequency varies continuously and the trace follows it without target-octave folding.
- Advanced settings screen visibly contains both controls without overlapping the existing controls or Back button.
- F6/F7 hide both labels and trace, then restore them; saved INI contains NoteNames=On and DetectedPitch=On.
- Fresh config selects Artist sorting and enables both new display settings.
- Three repeated normal startup/quit tests and the synthetic song, letter-navigation and toggle runs all exited 0 with empty stderr after Linux allocator correction.
- Original unmodified source built in a separate baseline also failed normal shutdown with EAccessViolation in SYSTEM.WAITFREE_VAR / interface finalization, exit 217. Adding the C allocator in that baseline made the same test exit 0. The Linux-only cmem correction also fixes all repeated tests in the modified build. This supports an allocator/foreign-thread interaction; exact corruption origin has not been proven.
- No Windows build, real microphone, real singing accuracy or multiplayer device test has been performed. Synthetic input and headless rendering are not live microphone validation.

## Test harness

`tests/ui_capture.c` is a test-only preload shim: it captures actual SDL/OpenGL frames, injects UI events, can supply synthetic microphone PCM, and quits via SDL_QUIT. It is never linked into the shipped executable. Set WP_CAPTURE to an existing output folder. WP_TEST_RAIL tests B/Z clicks; WP_TEST_TOGGLES toggles F6/F7; WP_SYNTH_PITCH supplies synthetic PCM; WP_QUIT_SHOT=1 runs a short quit test. WP_OPTIONS tests the Advanced settings screen. `tests/make_pitch_fixtures.py` generates the four test songs. The normal app never generates microphone input.

## Linux shutdown correction reference

Free Pascal documents cmem as its C allocator replacement and requires installing the memory manager before other units: https://docs.freepascal.org/docs-html/3.0.0/rtl/cmem/index.html . The change is Linux-only and precedes cthreads; it is not a USDX port.

Final polish: 50–1500 Hz search with interpolation neighbors, higher analysis rate for high-register precision, bounded latest-window analysis, and trace reset across pause/toggles. Final optimized build and synthetic toggle runtime pass, exit 0.
