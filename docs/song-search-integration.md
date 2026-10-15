# Experimental song-search integration

Reference inspected: martiinii/ultrastar-cli at
85e549cca96c578e02e235db9a13e609d82fcb95 (MIT).
https://github.com/martiinii/ultrastar-cli

The current developer-only slice now includes a small in-game metadata search
screen backed by the versioned JSON-lines adapter. It remains disabled unless
both `-catalog-python <absolute executable>` and
`-catalog-adapter <absolute script>` are supplied, and those files exist.
There is no PATH or working-directory search, auto-install, or package change.
The screen supports explicit sign-in and search only; it has no details or
download action. Downloads stay disabled because the game never passes the
adapter's opt-in flag. Local rescan remains available in the same menu.

The reference is an interactive Ink/React
terminal program, not a stable headless JSON service. It searches USDB via HTML
forms, retrieves note-chart text, resolves YouTube media, and invokes yt-dlp.
Availability of a chart does not prove availability, correct synchronization, or
permission to download its corresponding recording.

Do not launch its stock entry point invisibly: `src/session.ts` automatically
registers an account using a generated Gmail address and stores credentials.
An integration must use explicit user setup instead, without silently creating
accounts or copying browser credentials.

The current slice does not select or retrieve chart details, download media,
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
  anonymous-pipe mode is unsupported, startup fails closed. This behavior has
  not been executed on Windows, so this slice is not a completed Windows UI
  feature. The three pending-write errors use explicit equality/or checks; a
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
ran CPython 3.12.14 x64 and Free Pascal 3.2.2 x64, including a clean full-app
compile/link with no missing shared libraries. Layout tests check all 15 text
rectangles for bounds and pairwise non-overlap at 320x240 through 1920x1080;
dynamic status/input/result rows are single-line, UTF-8 truncated for display,
without changing result metadata. No interactive GUI runtime or screenshot
test was recorded for this source-only candidate. `Path.unlink(missing_ok=True)`
suggests Python 3.8 as a source API floor, but Python 3.8 compatibility has not
been executed or claimed.
