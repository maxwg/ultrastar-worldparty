# UltraStar2 improvements

## Everyday flow

1. Launch **ultrastar2** from Start. Type on song selection or press **F3**.
2. Browse your local songs first, then USDB matches in a 15-card grid.
3. Select a USDB card once. The app finds media, retries unavailable sources,
   verifies the download, refreshes the library and starts karaoke automatically.
4. The downloaded song stays in your collection, including after restarting.

## What changed

- Cover art fills each card; a bottom gradient keeps titles readable.
- Matches without cover art use a colored music tile.
- No blank section padding. Local/USDB badges and a gold selection outline.
- Complete Unicode text input, including during the opening animation.
- Latest-query background filtering; stale work is discarded instead of queued.
- Async cover decoding, a 64-cover cache, and one small GPU upload per frame.
- Idle frames and selection changes reuse measured labels and cached covers.
- Committed text handles AltGr; held toggles don't fire repeatedly.
- Regular UltraStar background, cover buttons, mouse scaling and hover selection.
- Up wraps to the final USDB result; paging and mouse targets match the grid.
- Automatic saved-account sign-in; repeated submits/downloads are coalesced.
- YouTube downloads and media helpers inherit a hidden console to preserve focus.
- Five-minute in-memory search/details caches, limited to 64 entries each.
- Artist + title deduplication hides repeated charts without deleting files.
- Microphone setup replaces the old Listen tile; reload rebinds device settings.
- Stable thin pitch line by default; F7 restores thick bars, F8 shows true Hz/note.
- One continuous detector for scoring and display, updated on fresh PCM every 20 ms.
- Automatic mic sensitivity and short, same-note dropout grace; Easy stays forgiving.
- Mic monitor volume in Options → Sound: 20% default, with a song-relative cap.
- Short live audio queues, no monitor detuning/reset loop, and stalled-input recovery.
- Real-vocal benchmark and production capture/scoring/render checks.
- Existing artist navigation remains available.

## Local installation and USDB paths

| Item | Location |
| --- | --- |
| USDB website | https://usdb.animux.de |
| Checkout | `D:\ultrastar` |
| App / Start shortcut target | `D:\ultrastar\game\WorldParty.exe` |
| Existing C-drive songs | `C:\Program Files (x86)\UltraStar WorldParty\songs` |
| Downloaded USDB songs | `D:\ultrastar\game\songs\USDB-<song-id>` |
| Configuration | `D:\ultrastar\game\config.ini`, section `[Catalog]` |
| USDB adapter | `D:\ultrastar\tools\song_catalog.py` |
| Saved account file | `C:\Users\maxwg\AppData\Local\ultrascrap-cli\Cache\credentials.json` |

The configuration references the existing account file. No credential values
are included in this repository. Python, yt-dlp, FFmpeg and ffprobe use the
existing local installation.

## Verification

Real Windows SDL/OpenGL screenshots are inspected during the polish pass. The
isolated E2E test covers sign-in, typing, local-first deduplication, wrap,
download fallback, autoplay, and a fresh launch finding the installed song.
The adapter contract and native process-cleanup tests cover errors, cancellation
and child-process ownership.

Live USDB sign-in/search/cache and an actual media installation have been checked.
Remote media availability can change. Automated playback uses dummy audio;
physical microphone and speaker output still need a hardware check.

Microphone monitoring has separate gain from scoring. Its combined RMS level is
capped at half the backing track; quiet setup monitoring works without a song.
See [microphone controls and recovery](docs/microphone-recovery.md) for tests and
the remaining physical-device latency checks.
