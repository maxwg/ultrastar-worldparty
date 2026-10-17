# Windows collection-search end-to-end test

Run from an existing Windows checkout with its game assets, the local Free
Pascal toolchain, Python, and FFmpeg:

```powershell
tests\library_e2e\run.ps1 -CompilerRoot <existing-local-toolchain-root>
tests\library_e2e\run.ps1 -CompilerRoot <existing-local-toolchain-root> -NoFade
tests\library_e2e\run.ps1 -CompilerRoot <existing-local-toolchain-root> -NoFade -CancelDownload
tests\library_e2e\run.ps1 -CompilerRoot <existing-local-toolchain-root> -WideWindow
```

The runner creates a fresh ignored `work/library-e2e-*` runtime. It builds a
separate executable with `LIBRARY_E2E`; the installed release does not include
the harness or the alternate audio backend. Fonts, themes, and other static
assets are referenced by directory junctions. Config, songs, databases, logs,
and screenshots belong to the fresh runtime. No real credentials are read.

The actual Windows SDL/OpenGL game and its production input, catalog bridge,
background search index, async thumbnail loader and normal cover-button renderer,
grid, rescanning, and singing-screen code are exercised. A local adapter
fixture supplies six unique local songs, duplicate local/remote charts and
fourteen unique remote results. Original portrait, square and landscape covers
exercise cropping and caption contrast; a long accented title checks text bounds.
It fails the first source, and publishes
a synthetic chart plus a twenty-second FFmpeg-generated audio/video fixture on
the second source. SDL's dummy audio driver pumps real decoder/mixer callbacks;
this verifies playback progression, not speakers or physical microphone input.

Checks include complete batched and transition text, automatic stored sign-in,
local/remote ordering, wrapping to the last page, repeated Enter containment,
source fallback, publication, rescan, selecting the correct installed song,
singing-screen entry without an error popup, and advancing playback position.
Another application launch verifies the download is still in the scanned library.
The cancellation variant holds a real helper download active until Escape kills
the owned process and restores signed-in search, without publishing a song.
Adapter operation counts and the game error log are checked after the process
exits. The outer Windows Job supervises the game and its helper descendants.

The runner also executes a 20,003-chart index stress test and exact Unicode
decoder checks. Mixed native key/text bursts include doubled letters and AltGr.
Cover decoding deliberately pauses for 50 ms in this test build; typing must
remain exact. Cached page returns require zero new decodes, idle frames must
not remeasure labels, and a physical-coordinate mouse click tests viewport
scaling. E2E window titles are unique so tests can coexist with a running game.

Each successful playback runtime retains `e2e-first-launch.txt`, `e2e-result.txt`
(the restart receipt), `adapter-trace.txt`, `Error.log`, and four
actual OpenGL screenshots. A timeout or unexpected game exception fails the run.

Real USDB authentication/search/cache and an actual media installation are
separate live checks; the offline adapter does not validate remote availability.
