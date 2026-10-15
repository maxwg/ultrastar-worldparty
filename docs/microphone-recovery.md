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
  Windows/BASS, real USB/Bluetooth devices, driver changes, and multiple identical
  microphone names remain hardware-validation gaps. BASS gets explicit setup
  rescan and stale-sample protection; automatic hotplug reopening is SDL-specific.
- `tests/record_capture_state_test.pas` feeds synthetic PCM through production
  capture-buffer and pitch logic using a fake backend/device. Its `CaptureStop`
  calls model capture lifecycle entrypoints only; this test does not exercise
  menus, a linked game executable, SDL callbacks, or physical hardware.

SDL documents remove-event `which` as an opened device ID and add-event `which` as
an enumeration index: https://wiki.libsdl.org/SDL2/SDL_AudioDeviceEvent . Closing a
device waits for its callback to finish before returning:
https://wiki.libsdl.org/SDL2/SDL_CloseAudioDevice .
