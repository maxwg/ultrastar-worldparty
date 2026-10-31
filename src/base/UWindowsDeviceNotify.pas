{*
    UltraStar WorldParty - Karaoke Game
    Windows Audio Device Notification System
*}

unit UWindowsDeviceNotify;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  SysUtils,
  sdl2
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF}
  ;

procedure InitWindowsDeviceNotifications;
procedure FinalizeWindowsDeviceNotifications;
procedure RegisterSDLWindowForDeviceNotifications(Window: PSDL_Window);
procedure UnregisterSDLWindowForDeviceNotifications;
procedure OnWindowsDeviceChangeDetected;
function CheckAndResetAudioDeviceChangePending: Boolean;
procedure HandleAudioDeviceChange;

implementation

uses
  ULog,
  URecord,
  UMusic,
  UDisplay,
  UGraphic,
  UScreenOptionsMicrophones;

const
  WM_DEVICECHANGE = $0219;
  DBT_DEVNODES_CHANGED = $0007;
  DBT_CONFIGCHANGED = $0018;
  DBT_DEVICEARRIVAL = $8000;
  DBT_DEVICEREMOVECOMPLETE = $8004;
  DBT_DEVTYP_DEVICEINTERFACE = $00000005;
  DEVICE_NOTIFY_WINDOW_HANDLE = $00000000;
  DEVICE_NOTIFY_ALL_INTERFACE_CLASSES = $00000004;

{$IFDEF MSWINDOWS}
type
  DEV_BROADCAST_DEVICEINTERFACE_W = record
    dbcc_size: DWORD;
    dbcc_devicetype: DWORD;
    dbcc_reserved: DWORD;
    dbcc_classguid: TGUID;
    dbcc_name: array [0..0] of WideChar;
  end;

  TRegisterDevNotify = function(hRecipient: HWND; NotificationFilter: Pointer; Flags: DWORD): Pointer; stdcall;
  TUnregisterDevNotify = function(hHandle: Pointer): BOOL; stdcall;

var
  hUser32: HMODULE = 0;
  RegisterDeviceNotificationW: TRegisterDevNotify = nil;
  UnregisterDeviceNotification: TUnregisterDevNotify = nil;
  hRegisteredDevNotify: Pointer = nil;
  RegisteredHWnd: HWND = 0;
{$ENDIF}

var
  DeviceChangePending: Boolean = False;
  DeviceChangeTick: Cardinal = 0;
  HookInstalled: Boolean = False;

{$IFDEF MSWINDOWS}
procedure WindowsAudioMessageHook(userdata, hWnd: Pointer; mesage: UInt32; wParam: UInt64; lParam: SInt64); cdecl;
var
  WParamLo: DWORD;
begin
  try
    if mesage = WM_DEVICECHANGE then
    begin
      WParamLo := DWORD(wParam and $FFFFFFFF);
      case WParamLo of
        DBT_DEVNODES_CHANGED,
        DBT_DEVICEARRIVAL,
        DBT_DEVICEREMOVECOMPLETE,
        DBT_CONFIGCHANGED:
        begin
          OnWindowsDeviceChangeDetected;
        end;
      end;
    end;
  except
  end;
end;
{$ENDIF}

procedure InitWindowsDeviceNotifications;
begin
  {$IFDEF MSWINDOWS}
  if HookInstalled then Exit;

  hUser32 := LoadLibrary('user32.dll');
  if hUser32 <> 0 then
  begin
    @RegisterDeviceNotificationW := GetProcAddress(hUser32, 'RegisterDeviceNotificationW');
    @UnregisterDeviceNotification := GetProcAddress(hUser32, 'UnregisterDeviceNotification');
  end;

  SDL_SetWindowsMessageHook(@WindowsAudioMessageHook, nil);
  HookInstalled := True;
  if Assigned(Log) then
    Log.LogStatus('Installed Windows device notification message hook', 'DeviceNotify');
  {$ENDIF}
end;

procedure FinalizeWindowsDeviceNotifications;
begin
  UnregisterSDLWindowForDeviceNotifications;
  {$IFDEF MSWINDOWS}
  if HookInstalled then
  begin
    SDL_SetWindowsMessageHook(nil, nil);
    HookInstalled := False;
  end;
  if hUser32 <> 0 then
  begin
    FreeLibrary(hUser32);
    hUser32 := 0;
    RegisterDeviceNotificationW := nil;
    UnregisterDeviceNotification := nil;
  end;
  {$ENDIF}
end;

procedure RegisterSDLWindowForDeviceNotifications(Window: PSDL_Window);
{$IFDEF MSWINDOWS}
var
  wmInfo: TSDL_SysWMinfo;
  filter: DEV_BROADCAST_DEVICEINTERFACE_W;
  guidAudioCapture: TGUID;
  TargetHWnd: HWND;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if Window = nil then Exit;
  try
    InitWindowsDeviceNotifications;

    FillChar(wmInfo, SizeOf(wmInfo), 0);
    SDL_GetVersion(@wmInfo.version);
    if SDL_GetWindowWMInfo(Window, @wmInfo) <> SDL_TRUE then Exit;

    TargetHWnd := wmInfo.win.window;
    if (TargetHWnd = 0) or (TargetHWnd = RegisteredHWnd) then Exit;

    UnregisterSDLWindowForDeviceNotifications;

    if Assigned(RegisterDeviceNotificationW) then
    begin
      // KSCATEGORY_CAPTURE: {65E8773D-8F56-11D0-A3B9-00A0C9223196}
      guidAudioCapture := StringToGUID('{65E8773D-8F56-11D0-A3B9-00A0C9223196}');
      FillChar(filter, SizeOf(filter), 0);
      filter.dbcc_size := SizeOf(filter);
      filter.dbcc_devicetype := DBT_DEVTYP_DEVICEINTERFACE;
      filter.dbcc_classguid := guidAudioCapture;

      hRegisteredDevNotify := RegisterDeviceNotificationW(TargetHWnd, @filter,
        DEVICE_NOTIFY_WINDOW_HANDLE or DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
      RegisteredHWnd := TargetHWnd;

      if hRegisteredDevNotify <> nil then
      begin
        if Assigned(Log) then
          Log.LogStatus('Registered SDL window for audio device notifications: HWND=$' + IntToHex(TargetHWnd, 8), 'DeviceNotify');
      end
      else
      begin
        if Assigned(Log) then
          Log.LogWarn('RegisterDeviceNotificationW returned nil for HWND=$' + IntToHex(TargetHWnd, 8), 'DeviceNotify');
      end;
    end;
  except
    on E: Exception do
    begin
      if Assigned(Log) then
        Log.LogWarn('Failed to register SDL window for device notifications: ' + E.Message, 'DeviceNotify');
    end;
  end;
  {$ENDIF}
end;

procedure UnregisterSDLWindowForDeviceNotifications;
begin
  {$IFDEF MSWINDOWS}
  if (hRegisteredDevNotify <> nil) and Assigned(UnregisterDeviceNotification) then
  begin
    UnregisterDeviceNotification(hRegisteredDevNotify);
    hRegisteredDevNotify := nil;
  end;
  RegisteredHWnd := 0;
  {$ENDIF}
end;

procedure OnWindowsDeviceChangeDetected;
begin
  DeviceChangePending := True;
  DeviceChangeTick := SDL_GetTicks;
end;

function CheckAndResetAudioDeviceChangePending: Boolean;
begin
  Result := False;
  if DeviceChangePending and (Cardinal(SDL_GetTicks - DeviceChangeTick) >= 200) then
  begin
    // If a song is actively capturing audio or a screen transition is running, defer refresh
    if (AudioInput <> nil) and AudioInput.IsCapturing then
      Exit;
    if Assigned(Display) and ((Display.NextScreen <> nil) or (Display.NextScreenWithCheck <> nil)) then
      Exit;
    DeviceChangePending := False;
    Result := True;
  end;
end;

procedure HandleAudioDeviceChange;
begin
  if Assigned(Log) then
    Log.LogStatus('Audio device connect/disconnect event triggered device refresh', 'AudioInput');

  if AudioInput = nil then Exit;

  // If user is currently on the microphone setup screen, rebuild it live
  if Assigned(UGraphic.ScreenOptionsMicrophones) and
     (Display.CurrentScreen = @UGraphic.ScreenOptionsMicrophones) then
  begin
    UGraphic.ScreenOptionsMicrophones.HandleDeviceChange;
  end
  else
  begin
    // If not currently capturing during a song, refresh devices globally
    if not AudioInput.IsCapturing then
    begin
      AudioInput.RefreshDevices;
      if Assigned(UGraphic.ScreenOptionsMicrophones) and
         (Display.NextScreen <> @UGraphic.ScreenOptionsMicrophones) and
         (Display.NextScreenWithCheck <> @UGraphic.ScreenOptionsMicrophones) then
        FreeAndNil(UGraphic.ScreenOptionsMicrophones);
    end;
  end;
end;

end.
