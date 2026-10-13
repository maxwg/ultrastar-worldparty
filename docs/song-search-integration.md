# In-game song discovery: inspected integration boundary

Reference inspected: martiinii/ultrastar-cli at
85e549cca96c578e02e235db9a13e609d82fcb95 (MIT).
https://github.com/martiinii/ultrastar-cli

This is not integrated or enabled yet. The reference is an interactive Ink/React
terminal program, not a stable headless JSON service. It searches USDB via HTML
forms, retrieves note-chart text, resolves YouTube media, and invokes yt-dlp.
Availability of a chart does not prove availability, correct synchronization, or
permission to download its corresponding recording.

Do not launch its stock entry point invisibly: `src/session.ts` automatically
registers an account using a generated Gmail address and stores credentials.
An integration must use explicit user setup instead, without silently creating
accounts or copying browser credentials.

The smallest useful in-game flow is: search artist/title → choose a chart/version
→ show source, language and media match → explicit Download → progress/cancel →
validate a complete staged song folder → publish into the configured song library
→ rescan and select for Play. Existing songs must never be overwritten silently.

Requirements before calling this complete:
- An explicit, versioned machine-readable adapter, with no shell interpolation.
- Responsive background search/download and cancellation; bounded process cleanup.
- Source IDs and duplicate detection, safe filenames/path containment, complete
  header preservation (split at the first colon), HTML decoding and UTF-8 handling.
- A visible account/setup-needed state; no automatic registration.
- Correct chart/media pairing and honest unavailable-region/media errors.
- Temporary staging excluded from song scans, validate chart and referenced audio,
  then atomic completion; interrupted downloads must not appear playable.
- Fixture tests for hostile names/paths, duplicates, cancellation, missing media,
  malformed HTML, nonzero downloader exit and repeated clicks.

Prefer adapting the small backend boundary with attribution over embedding the
terminal UI or adding a second independent song library/database.
