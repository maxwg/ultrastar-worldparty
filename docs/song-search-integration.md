# Song search integration

## Installed Windows collection search (2026-10-17)

Typing, F3, or the search icon in normal song selection opens the combined
collection search as a compact four-column, three-row cover grid. Local artist/title
matches appear first, followed by a separately aligned USDB section. Duplicate artist/title pairs are hidden using Unicode lowercasing,
normalized whitespace and straight/curly apostrophe equivalence. Named versions
such as `(Live)` remain distinct. No existing song files are deleted.

Search is debounced for 200 ms and USDB searches artist OR title. The adapter
returns a bounded first page, deduplicated by source ID; display rows also hide
songs already present locally. Arrow keys navigate cards; PageUp/PageDown or
the wheel change pages. Cards show local cover art, artist/title and source
badges. Enter or a card click opens the local song or remote source details. F2 opens explicit sign-in.
The idle session is kept in helper memory for this application's lifetime;
passwords are cleared after submission and never written to configuration.

Selecting a USDB card downloads immediately after source details load, tries
the next listed source if one fails, then refreshes the library and starts the
installed song automatically. Manual source selection remains available. The
integrated screen explicitly opts into the adapter's existing download support;
the older developer metadata screen still does not. Media is staged outside
the scanned songs folder, checked with ffprobe, and the chart is published last.
The destination is the writable local game `songs` directory. Completion rescans
and queues the installed folder for karaoke playback once song selection
finishes initializing. Leaving during an operation terminates the owned
helper; Windows downloader/probe descendants use non-inheritable kill-on-close
Jobs. Interrupted staging is outside the library and cannot appear playable.

Configure `[Catalog]` / `Python` and `Adapter` with absolute paths in the game
config, or use the existing command-line overrides. Optional `Credentials`
references an existing JSON credential file without copying its values. F2 then
Enter retries using that file when the typed fields are blank. Opening search
automatically attempts stored sign-in once the helper is ready. It waits while
busy, preserves an existing session, and avoids repeated attempts after failure. yt-dlp and ffprobe must be
available to the helper. No account is created automatically.

Verification: full clean i386-win32 release compilation; 42 adapter tests (one
existing POSIX-only skip), 378 bridge assertions, five identity assertions, and
121 grid bounds/overlap/hit-target assertions and nine auto-sign-in state checks. Saved credentials from the
installed UltraStar CLI successfully authenticated through the live adapter:
Adele returned seven results and source details returned two verified media
links. Credential values were not printed or copied. A live download of Adele - Lovesong (USDB 28904) succeeded using the second
listed source after the first proved unavailable; ffprobe verified its audio.
The Windows SDL/OpenGL end-to-end test now verifies rendered UI, rescan and
automatic karaoke playback with synthetic media and dummy audio callbacks.
Physical microphone and speaker operation remain unverified in this session.

## Historical metadata-only developer screen


Reference inspected: martiinii/ultrastar-cli at
85e549cca96c578e02e235db9a13e609d82fcb95 (MIT).
https://github.com/martiinii/ultrastar-cli

The current developer-only slice now includes a small in-game metadata search
screen backed by the versioned JSON-lines adapter. It remains disabled unless
both `-catalog-python <absolute executable>` and
`-catalog-adapter <absolute script>` are supplied, and those files exist.
There is no PATH or working-directory search, auto-install, or package change.
The screen supports explicit sign-in, search, keyboard result selection, and
source details. Tab and Shift+Tab move focus; Up/Down select or scroll results;
Enter fetches source details only for the selected numeric song ID. Escape
returns to the same result and scroll position before closing the screen.
Source details show catalog metadata and YouTube video IDs without opening
links. There is no download action. Downloads stay disabled because the game
never passes the adapter's opt-in flag. Local rescan remains available in the same menu.

The reference is an interactive Ink/React
terminal program, not a stable headless JSON service. It searches USDB via HTML
forms, retrieves note-chart text, resolves YouTube media, and invokes yt-dlp.
Availability of a chart does not prove availability, correct synchronization, or
permission to download its corresponding recording.

Do not launch its stock entry point invisibly: `src/session.ts` automatically
registers an account using a generated Gmail address and stores credentials.
An integration must use explicit user setup instead, without silently creating
accounts or copying browser credentials.

The current slice does not retrieve playable chart content, download media,
write the local library, or make results playable. Those are later, separately
reviewed steps. Existing local song search and rescan remain unchanged.

Requirements before calling this complete:
- An explicit, versioned machine-readable adapter, with no shell interpolation.
- Responsive background search/download and cancellation; bounded process cleanup.
- Source IDs and duplicate detection, safe filenames/path containment, complete
  header preservation (split at the first colon), HTML decoding and UTF-8 handling.
- A visible account/setup-needed state; no automatic registration. UI sign-in
  is explicit and credentials are sent only to the child adapter over its local
  stdin request; there is no database/INI setting or logging of credentials.
  Optional convenience: launching the game with `-catalog-credentials <path>`
  (absolute JSON file holding `{"user": ..., "pass": ...}`) lets the song
  catalog screen sign in with empty typed fields via a `credentials_file`
  request field — only the file path travels, values are never echoed in
  events, logs, or status, and typed entries still take precedence. The
  adapter also accepts `--credentials <path>` at launch as a fallback for the
  same file; unavailable files, bad JSON, or unusable fields fail closed with
  the stable error codes `missing_credentials`, `credentials_file_unreadable`,
  and `credentials_file_invalid`.
- The helper is scoped to the screen's process lifetime. Hiding the screen queues
  a versioned quit with its own request ID, then immediately terminates that
  exact owned child; hide does not wait for network work and does not claim it
  received the quit acknowledgement. Reopening starts a fresh signed-out process
  after the old owned child exits. The adapter's current status/login/search
  paths do not create subprocesses; a future download flow needs a separately
  reviewed descendant-lifetime design.
- The bridge uses a 64-KiB bounded outbound queue and nonblocking pipe writes.
  Linux startup sets `O_NONBLOCK`; each `write` temporarily blocks and consumes
  only its own `SIGPIPE`, then restores the calling thread's prior signal mask.
  The application source does not set a process-wide `SIGPIPE` disposition. On
  Windows the bridge requests `PIPE_NOWAIT` on the `TProcess` input pipe; if that
  anonymous-pipe mode is unsupported, startup fails closed. Windows
  Win32 FPC 3.2.2 keeps escaped accented song names intact: the bridge
  pre-decodes `\\uXXXX` escapes above U+007F into UTF-8 bytes, parses responses
  with a temporary `DefaultSystemCodePage=CP_UTF8` window, and emits typed
  request values as ASCII-only `\\uXXXX` JSON escapes. The full five-argument
  bridge suite passes on i386-win32 (363 assertions, including the previously
  failing escaped-accent typed-metadata checks), with a wire-level test
  locking the single-escape contract for typed outbound values. Typed astral
  characters in worst-case codepoints follow the same escape paths.
  The three pending-write
  errors use explicit equality/or checks; a
  compiled portable regression exercises Win32 values 232, 997, and 536, while
  a source check ties the Windows branch to its named constants. This does not
  verify anonymous-pipe behavior on Windows. Linux also starts a transport-owned waitpid monitor before launching
  the helper; it is the sole waitpid owner and reaps the exact child even after
  the screen is hidden and stops polling. A short lock serializes its
  nonblocking waitpid/status publication with the hide-path PID kill, preventing
  kill-after-reap PID reuse; no blocking wait is performed under that lock. The
  hide path only queues quit and sends SIGKILL to that helper PID; it does not
  wait for the monitor, worker, or network timeout. An offline regression
  confirms the child is reaped without any further session Poll while an
  unrelated sentinel process survives.
- Status is a process-local snapshot. A later `authentication_required` response
  clears the UI's signed-in state. The bridge accepts only matching request IDs,
  ignores stale frames, caps response JSONL frames at 65,536 bytes, and rejects
  any unexpected download capability. A login success must carry boolean
  `ok: true` alongside `auth_state: "signed_in"`; missing, mistyped, or
  inconsistent login fields fail closed.
- Correct chart/media pairing and honest unavailable-region/media errors.
- Temporary staging excluded from song scans, validate chart and referenced audio,
  then atomic completion; interrupted downloads must not appear playable.
- Fixture tests for hostile names/paths, duplicates, cancellation, missing media,
  malformed HTML, nonzero downloader exit and repeated clicks.

Prefer adapting the small backend boundary with attribution over embedding the
terminal UI or adding a second independent song library/database.

A developer-only backend/test slice is described in
[song-catalog-backend.md](song-catalog-backend.md). The bridge's current
offline fake-transport and inert-child coverage is in `tests/catalog_bridge/`.
This is source-only and not packaged or a release claim. The current test host
ran CPython 3.13.5 x64 and Free Pascal 3.2.2 x64, including a clean full-app
compile/link with no missing shared libraries. Layout tests check all 15 text
rectangles for bounds and pairwise non-overlap at 320x240 through 1920x1080;
dynamic status/input/result rows are single-line, UTF-8 truncated for display,
without changing result metadata. Linux offscreen synthetic GUI checks
exercised result selection, source loading,
success/error, scrolling and Escape retention. ASCII controls in remote metadata
are replaced by spaces in display copies only, preserving original values and
UTF-8 bytes. These checks used an inert adapter and do not establish live catalog
authentication, physical audio behavior, or Windows GUI correctness.
`Path.unlink(missing_ok=True)`
suggests Python 3.8 as a source API floor, but Python 3.8 compatibility has not
been executed or claimed.

## Current keyboard validation (2026-10-16)

The Linux bridge suite passes 352 assertions, and the selection/focus suite
passes 282 assertions, including reverse Tab navigation that preserves the
selected song and detail scroll position. Layout/input and portable-expression
checks also pass. A clean full application compile passes with 37 existing
warnings and 341 notes. The source-details UI was exercised in an offscreen
Linux runtime; the later Shift+Tab addition is covered by the pure navigation
suite and full compile, not an SDL keyboard-injection runtime check.

Downloads remain disabled. Before exposing installation, resolve descendant
ownership on helper termination, choose an explicit scanned install directory,
and validate progress/cancellation/publication handling. Do not infer release
readiness from the offline metadata/source-details tests.

## Responsiveness and downloads (2026-10-17)

Up from the first grid row wraps to the last result, making USDB matches easy
to reach. Search accepts input during its opening transition and dispatches all
Unicode characters in SDL_TEXTINPUT events rather than discarding all but the
first. Other screens retain their transition input policy.

USDB queries and chart/source details have a five-minute process-memory cache,
bounded to 64 entries per cache and cleared on sign-in. Credentials are never
cached on disk. Query results are copied before returning them to callers.

Downloads prefer H.264 MP4 plus M4A streams with FFmpeg merging, with combined
format fallback. Errors show a bounded diagnostic message. Windows stderr is
captured together with stdout. Job cleanup checks zero active processes after
termination; the lifetime process counter can include helpers that exited
between polls and is not evidence of a leak. Atomic Job assignment and
kill-on-close ownership remain enforced.

## End-to-end audit (2026-10-17)

The reproducible `tests/library_e2e/run.ps1` test passes with fades on and off.
It found and fixed two actual handoff defects: rescan completion could replace
an in-progress screen transition and skip the song screen OnShow/Refresh; INI
reload replaced microphone configuration arrays without rebinding device indices.
Both failures were reproduced in the real game before the fixes. Missing cover
art now uses the default cover without trying to decode a directory as an image.

The harness drives the real SDL event loop and Windows OpenGL renderer, checks
fourteen remote cards across pages, sends repeated Enter, observes one failed
source plus one successful retry, and verifies the correct installed chart in
the singing screen with advancing playback time. Actual screenshots were visually
inspected; both final runs have clean game error logs and no extra source/download
requests. Audio hardware is replaced only in this test build by SDL dummy input
and output; physical microphone accuracy and speaker output are not claimed.

Additional native tests cover cancellation with descendants, an unrelated live
sentinel, bounded output flooding, merged diagnostics, and already-exited helper
process accounting (five checks). The live USDB repeat-query and repeat-details
cache checks caused zero additional HTTP requests while preserving results.

## Luna review follow-up (2026-10-17)

Three GPT-6 Luna reviews covered UI/input, backend/process ownership, and
integration/fixtures. The parent reviewed every finding and patch. Sign-in
submissions now coalesce during startup and ignore repeated Enter while a login
is active; typing on the sign-in button leaves the query unchanged. Incomplete
artist/title metadata follows the library loader policy instead of being merged
into one row. Search trims and caps values before both cache lookup and the
upstream request, with an offline regression for whitespace-equivalent queries.

The real SDL harness now holds login in flight until repeated submits have been
dispatched, requires exactly one login, and checks local-first ordering and
local/local, local/remote and remote/remote deduplication. Both fade modes pass,
as do the 43-test contract suite (one platform skip), five native Job tests and
Windows path checks. The clean release build succeeds. Physical microphone and
speaker verification remains outside this synthetic-audio test.

## Cover-card polish (2026-10-17)

The grid now fits fifteen cards without section spacer cells. Cover art fills
each card using centered cropping; a bottom gradient and pixel-measured text
keep titles readable. Source badges distinguish local songs from USDB matches.
One-click download shows the selected song and an activity indicator, with
automatic fallback and playback. Escape cancels the active owned helper and
restores search. Concise usage and installation paths are in
`README-improvements.md`.

Actual OpenGL grid, wrap, download and singing frames were inspected. The E2E
harness covers six unique local charts, local/remote duplicates, fourteen new
remote matches, long accented captions, both fade modes, and persistence after
a fresh launch. A separate cancellation run leaves no installed chart and
restores searchable results. Live USDB login/search/details/cache checks pass.
