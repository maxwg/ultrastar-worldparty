# UltraStar WorldParty

Karaoke for up to six players, with pitch and rhythm scoring. This fork adds
artist navigation, microphone recovery, pitch feedback, and local + USDB search.

## Search, download, sing

Type on song selection or press **F3** to open search. Your songs appear first,
followed by new matches from [USDB](https://usdb.animux.de). The compact 5 × 3
grid uses full-card cover art with a dark text gradient. Click a USDB card or
press **Enter** to download; unavailable sources are retried automatically.
Verified downloads start singing automatically and remain in your library.

- **Arrows / mouse wheel:** browse; Up from the first row wraps to the end.
- **Tab:** switch search/cards. **F2:** USDB account. **Esc:** back/cancel.
- Artist + title duplicates are hidden without deleting files.
- Saved credentials sign in automatically; recent searches/details are cached.

See [improvements and local paths](README-improvements.md).

## Build and verify

Use the existing Windows Free Pascal toolchain:

```powershell
tools\build_windows.ps1 -CompilerRoot <local-fpc-toolchain-root>
tests\library_e2e\run.ps1 -CompilerRoot <local-fpc-toolchain-root>
```

The Windows E2E harness runs the real SDL/OpenGL app with isolated fixtures:
search, sign-in, grid navigation, source fallback, autoplay, and persistence
after restart. Its audio is synthetic; physical microphones/speakers need a
hardware check. Live USDB and actual media installation are separate checks.

For Linux: `./autogen.sh`, `./configure`, `make`. See
[CONTRIBUTING.md](CONTRIBUTING.md) for dependencies and focused tests.

## More

[Artist navigation](docs/artist-navigation.md) ·
[Pitch display](docs/pitch-display.md) ·
[Microphone recovery](docs/microphone-recovery.md) ·
[Search integration](docs/song-search-integration.md) ·
[Catalog backend](docs/song-catalog-backend.md)

Based on [UltraStar WorldParty](https://github.com/ultrastares/ultrastar-worldparty).
Credits: [COPYRIGHT.txt](COPYRIGHT.txt). License: [GPLv3](LICENSE), with bundled
notices in [game/licenses](game/licenses). This is a development fork.
