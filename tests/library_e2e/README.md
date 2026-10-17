# Windows collection-search end-to-end test

Run from an existing Windows checkout with its game assets, the local Free
Pascal toolchain, Python, and FFmpeg:

```powershell
tests\library_e2e\run.ps1 -CompilerRoot <existing-local-toolchain-root>
tests\library_e2e\run.ps1 -CompilerRoot <existing-local-toolchain-root> -NoFade
```

The runner creates a fresh ignored `work/library-e2e-*` runtime. It builds a
separate executable with `LIBRARY_E2E`; the installed release does not include
the harness or the alternate audio backend. Fonts, themes, and other static
assets are referenced by directory junctions. Config, songs, databases, logs,
and screenshots belong to the fresh runtime. No real credentials are read.

The actual Windows SDL/OpenGL game and its production input, catalog bridge,
grid, rescanning, and singing-screen code are exercised. A local adapter
fixture supplies fourteen remote results, fails the first source, and publishes
a synthetic chart plus a twenty-second FFmpeg-generated audio/video fixture on
the second source. SDL's dummy audio driver pumps real decoder/mixer callbacks;
this verifies playback progression, not speakers or physical microphone input.

Checks include complete batched and transition text, automatic stored sign-in,
local/remote ordering, wrapping to the last page, repeated Enter containment,
source fallback, publication, rescan, selecting the correct installed song,
singing-screen entry without an error popup, and advancing playback position.
Adapter operation counts and the game error log are checked after the process
exits. The outer Windows Job supervises the game and its helper descendants.

Each runtime retains `e2e-result.txt`, `adapter-trace.txt`, `Error.log`, and three
actual OpenGL screenshots. A timeout or unexpected game exception fails the run.

Real USDB authentication/search/cache and an actual media installation are
separate live checks; the offline adapter does not validate remote availability.
