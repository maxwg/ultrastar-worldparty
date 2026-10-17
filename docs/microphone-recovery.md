# Microphone setup and reconnect recovery

The main menu now opens microphone setup directly. Back returns to the menu that
opened setup. Each entry rescans devices and reconstructs the selectors, keeping
saved channel-to-player mappings by the existing device-name matching contract.
A microphone attached after startup can therefore be selected without restarting.

The microphone selector hides recognized software loopback/monitor inputs by
default. `Show virtual audio inputs` in Options → Advanced reveals them on the
next microphone-setup entry. An input with a saved, active channel-to-player
mapping remains visible even when the setting is off. Names are only a heuristic:
only explicit virtual/loopback markers are hidden, and unknown device names are
left available. Enumeration and capture mappings are not removed by this filter.

SDL capture hotplug events close the removed capture handle and clear its buffers.
When the same named microphone returns, linked capture channels reopen. Playback
is not restarted. Unnamed/default and ambiguous duplicate-name devices are not
automatically substituted; reopen setup to select them. A changed channel count or
format may likewise require reopening setup. Previously unseen devices are shown
on the next setup entry, not inserted into a live selector list.

Both scoring and the continuous pitch display reject input older than 250 ms.
Previously scoring could repeatedly analyse the last note after capture stopped.
The initialized SDL backend remains available when startup finds zero microphones.

## Verified locally

- Linux full FPC build passes; existing 62 pitch and 17 navigation assertions pass.
- Actual main menu → microphone setup → Back → repeat, synthetic SDL dummy device:
  exit 0; screenshots confirm setup and return destination.
- No capture device can open at startup (test-only shim), then becomes available
  before opening setup: visible device selector and repeated setup pass, exit 0.
- During synthetic singing, injected SDL capture-remove and capture-add events
  produce disconnect/reconnect logs and a newly opened callback stream, exit 0.
- These are deterministic event/callback tests, not physical USB unplug tests.
  Real USB/Bluetooth devices, driver changes, and multiple identical microphone
  names remain hardware-validation gaps. SDL handles hotplug events; both SDL
  and BASS now also check for stalled capture as described below.
- `tests/record_capture_state_test.pas` feeds synthetic PCM through production
  capture-buffer and pitch logic using a fake backend/device. Its `CaptureStop`
  calls model capture lifecycle entrypoints only; this test does not exercise
  menus, a linked game executable, SDL callbacks, or physical hardware.

SDL documents remove-event `which` as an opened device ID and add-event `which` as
an enumeration index: https://wiki.libsdl.org/SDL2/SDL_AudioDeviceEvent . Closing a
device waits for its callback to finish before returning:
https://wiki.libsdl.org/SDL2/SDL_CloseAudioDevice .

## Monitoring volume, dropouts and latency

Enable **Microphone playback** in **Options → Sound**, then adjust **Mic monitor
volume** from 0% to 50% (20% default). This controls a copy of raw microphone PCM
before software MicBoost. Pitch detection and scoring keep their existing input.
The combined monitor RMS is limited to half the backing-track RMS (about 6 dB
below it), with a separate peak cap. A muted/silent backing track mutes monitoring;
without a song, setup monitoring uses a quiet fixed ceiling. Gain reductions are
immediate and recovery takes about 50 ms to avoid abrupt level jumps.

Confirmed software problems fixed in this pass:

- Wrapped ring-buffer reads previously overwrote the start of the output block.
- BASS monitoring previously slowed the microphone by 1%, grew its push queue,
  then periodically restarted it. It now pulls original-rate PCM without the
  song-sized playback queue, using the bundled BASS 2.4.12 no-buffer attribute.
- SDL monitoring previously allowed a half-second application queue and 4096
  source frames of read-ahead. The queue now holds at most 40 ms of fresh PCM;
  voice conversion reads 256 frames at a time. Temporary underruns render silence
  and resume on the next callback, without treating the microphone as finished.
- Automatic capture requests are 512 frames for SDL and 10 ms for BASS. Automatic
  SDL playback uses 512 frames when monitoring is enabled. Explicit user buffer
  settings still apply. Enabling monitoring after SDL playback initialization
  requires restarting the app to select the smaller automatic output buffer.

Every two seconds, active capture devices are checked for stopped streams or no
new PCM for at least 1.5 seconds. This uses callback freshness, so quiet/unpitched
singing does not trigger a restart. Recovery clears stale pitch state and retries
the same input. SDL requires one matching named device; BASS checks the original
name/driver identity and refuses ambiguous duplicates. A missing, renamed or
ambiguous input can still require microphone setup; a different default device
is never silently substituted.

Run `tests/run_monitor_tests.ps1 -CompilerRoot <FPC-root>` on Windows for the real
queue/render and production soft-mixer/converter tests. They cover wrap integrity,
overflow freshness, underrun/resume, gain and multi-mic ceilings, input immutability,
and mono 44.1-to-stereo 48 kHz conversion. The game E2E fixture enables monitoring
while synthetic singing is scored, exercises the volume and background-music
selectors, checks their exit/save behavior, and captures the actual options UI.

These checks use synthetic PCM and dummy playback. Physical microphone dropout
recovery and acoustic input-to-speaker latency have not been measured. The 40 ms
limit bounds the application queue, not total driver/device/Bluetooth latency.
