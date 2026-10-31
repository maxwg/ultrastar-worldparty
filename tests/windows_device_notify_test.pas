program WindowsDeviceNotifyTest;
{$mode objfpc}{$H+}
uses
  SysUtils,
  sdl2,
  UWindowsDeviceNotify;

var
  Assertions: Integer;

procedure Check(Condition: Boolean; const Why: String);
begin
  Inc(Assertions);
  if not Condition then
  begin
    WriteLn('FAIL: ', Why);
    Halt(1);
  end;
end;

procedure TestDebounceAndPending;
var
  I: Integer;
begin
  WriteLn('Testing Debounce and Pending behavior...');

  // Initially should not be pending
  Check(not CheckAndResetAudioDeviceChangePending, 'Initially no device change should be pending');

  // Trigger one notification
  OnWindowsDeviceChangeDetected;

  // Immediately (<200ms), pending check should return False due to debounce
  Check(not CheckAndResetAudioDeviceChangePending, 'Pending check should return False immediately (debounce < 200ms)');

  // Wait 100ms - still debouncing (<200ms)
  SDL_Delay(100);
  Check(not CheckAndResetAudioDeviceChangePending, 'Pending check should return False at 100ms');

  // Wait another 120ms (total > 200ms)
  SDL_Delay(120);
  Check(CheckAndResetAudioDeviceChangePending, 'Pending check should return True after 220ms');

  // Next check should be reset to False
  Check(not CheckAndResetAudioDeviceChangePending, 'Pending check should be reset to False immediately after consuming');

  // Test rapid bursts (simulating Windows firing 5 DBT_DEVNODES_CHANGED messages in 150ms)
  for I := 1 to 5 do
  begin
    OnWindowsDeviceChangeDetected;
    SDL_Delay(30);
    Check(not CheckAndResetAudioDeviceChangePending, 'Pending check should remain False during rapid notification burst');
  end;

  // Wait 220ms after final burst
  SDL_Delay(220);
  Check(CheckAndResetAudioDeviceChangePending, 'Pending check should trigger once after burst settles');
  Check(not CheckAndResetAudioDeviceChangePending, 'Pending check should reset after consuming burst');
end;

procedure TestWindowRegistrationSafeguards;
begin
  WriteLn('Testing window registration safeguards...');
  // Initialize notification subsystems
  InitWindowsDeviceNotifications;

  // Nil window should safely exit without crash
  RegisterSDLWindowForDeviceNotifications(nil);

  // Unregistering when none registered should be safe
  UnregisterSDLWindowForDeviceNotifications;
  UnregisterSDLWindowForDeviceNotifications;

  // Finalize should be safe
  FinalizeWindowsDeviceNotifications;
  FinalizeWindowsDeviceNotifications;
end;

begin
  Assertions := 0;
  if SDL_Init(0) < 0 then
  begin
    WriteLn('SDL_Init failed: ', SDL_GetError);
    Halt(1);
  end;

  try
    TestDebounceAndPending;
    TestWindowRegistrationSafeguards;
    WriteLn(Format('PASS: %d Windows device notification assertions', [Assertions]));
  finally
    SDL_Quit;
  end;
end.
