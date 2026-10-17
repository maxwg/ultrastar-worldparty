{*
    UltraStar WorldParty - Karaoke Game
	
	UltraStar WorldParty is the legal property of its developers, 
	whose names	are too numerous to list here. Please refer to the 
	COPYRIGHT file distributed with this source distribution.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program. Check "LICENSE" file. If not, see 
	<http://www.gnu.org/licenses/>.
 *}

unit UAudioInput_Bass;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Classes,
  SysUtils,
  URecord,
  UMusic;

implementation

uses
  UMain,
  UIni,
  ULog,
  UAudioCore_Bass,
  UTextEncoding,
  UCommon,    // (Note: for MakeLong on non-windows platforms)
  sdl2,
  {$IFDEF MSWINDOWS}
  Windows,    // (Note: for MakeLong)
  {$ENDIF}
  bass;       // (Note: DWORD is redefined here -> insert after Windows-unit)

type
  TAudioInput_Bass = class(TAudioInputBase)
    private
      fLastHealthCheck: Cardinal;
      fHealthCheckStarted: boolean;
      function EnumDevices(): boolean;
    public
      function GetName: String; override;
      function InitializeRecord: boolean; override;
      function FinalizeRecord: boolean; override;
      procedure CheckCaptureHealth; override;
  end;

  TBassInputDevice = class(TAudioInputDevice)
    private
      RecordStream: HSTREAM;
      RecordInitialized: boolean;
      BassDeviceID: DWORD; // DeviceID used by BASS
      RawDeviceName: AnsiString;
      RawDeviceDriver: AnsiString;
      SingleIn: boolean;

      function DeviceIdentityMatches: boolean;
      function DeviceIdentityIsAmbiguous: boolean;
      function SelectCaptureDevice: boolean;
      function SetInputSource(SourceIndex: integer): boolean;
      function GetInputSource(): integer;
    public
      function Open(): boolean;
      function Close(): boolean;
      function Start(): boolean; override;
      function Stop(): boolean;  override;

      function GetVolume(): single;        override;
      procedure SetVolume(Volume: single); override;
  end;

var
  BassCore: TAudioCore_Bass;


{ Global }

{*
 * Bass input capture callback.
 * Params:
 *   stream - BASS input stream
 *   buffer - buffer of captured samples
 *   len - size of buffer in bytes
 *   user - players associated with left/right channels
 *}
function MicrophoneCallback(stream: HSTREAM; buffer: Pointer;
    len: integer; inputDevice: Pointer): boolean; {$IFDEF MSWINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
begin
  AudioInputProcessor.HandleMicrophoneData(buffer, len, inputDevice);
  Result := true;
end;


{ TBassInputDevice }

function TBassInputDevice.DeviceIdentityMatches(): boolean;
var
  DeviceInfo: BASS_DEVICEINFO;
begin
  FillChar(DeviceInfo, SizeOf(DeviceInfo), 0);
  Result := BASS_RecordGetDeviceInfo(BassDeviceID, DeviceInfo) and
    (DeviceInfo.name <> nil) and (AnsiString(DeviceInfo.name) = RawDeviceName);
  if Result and (RawDeviceDriver <> '') then
    Result := (DeviceInfo.driver <> nil) and
      (AnsiString(DeviceInfo.driver) = RawDeviceDriver);
end;

function TBassInputDevice.DeviceIdentityIsAmbiguous(): boolean;
var
  i: integer;
  OtherDevice: TBassInputDevice;
begin
  Result := False;
  if RawDeviceName = '' then
    Exit;

  for i := 0 to High(AudioInputProcessor.DeviceList) do
  begin
    if AudioInputProcessor.DeviceList[i] = Self then
      Continue;
    if not (AudioInputProcessor.DeviceList[i] is TBassInputDevice) then
      Continue;
    OtherDevice := TBassInputDevice(AudioInputProcessor.DeviceList[i]);
    if (OtherDevice.RawDeviceName = RawDeviceName) and
      (OtherDevice.RawDeviceDriver = RawDeviceDriver) then
      Exit(True);
  end;
end;

function TBassInputDevice.SelectCaptureDevice(): boolean;
begin
  Result := false;
  if not DeviceIdentityMatches() then
  begin
    Log.LogError('BASS capture device identity changed; refusing to select a different device',
      'TBassInputDevice.SelectCaptureDevice');
    Exit;
  end;
  if not BASS_RecordSetDevice(BassDeviceID) then
  begin
    Log.LogError('BASS_RecordSetDevice['+Name+']: ' + BassCore.ErrorGetString(),
      'TBassInputDevice.SelectCaptureDevice');
    Exit;
  end;
  Result := true;
end;

function TBassInputDevice.GetInputSource(): integer;
var
  SourceCnt: integer;
  i: integer;
  flags: DWORD;
begin
  // get input-source config (subtract virtual device to get BASS indices)
  SourceCnt := Length(Source)-1;

  // find source
  Result := -1;
  for i := 0 to SourceCnt-1 do
  begin
    // get input settings
    flags := BASS_RecordGetInput(i, nil);
    if (flags = DWORD(-1)) then
    begin
      Log.LogError('BASS_RecordGetInput: ' + BassCore.ErrorGetString(), 'TBassInputDevice.GetInputSource');
      Exit;
    end;

    // check if current source is selected
    if ((flags and BASS_INPUT_OFF) = 0) then
    begin
      // selected source found
      Result := i;
      Exit;
    end;
  end;
end;

function TBassInputDevice.SetInputSource(SourceIndex: integer): boolean;
var
  SourceCnt: integer;
  i: integer;
  flags: DWORD;
begin
  Result := false;

  // check for invalid source index
  if (SourceIndex < 0) then
    Exit;

  // get input-source config (subtract virtual device to get BASS indices)
  SourceCnt := Length(Source)-1;

  // turn on selected source (turns off the others for single-in devices)
  if (not BASS_RecordSetInput(SourceIndex, BASS_INPUT_ON, -1)) then
  begin
    Log.LogError('BASS_RecordSetInput: ' + BassCore.ErrorGetString(), 'TBassInputDevice.Start');
    Exit;
  end;

  // turn off all other sources (not needed for single-in devices)
  if (not SingleIn) then
  begin
    for i := 0 to SourceCnt-1 do
    begin
      if (i = SourceIndex) then
        continue;
      // get input settings
      flags := BASS_RecordGetInput(i, nil);
      if (flags = DWORD(-1)) then
      begin
        Log.LogError('BASS_RecordGetInput: ' + BassCore.ErrorGetString(), 'TBassInputDevice.GetInputSource');
        Exit;
      end;
      // deselect source if selected
      if ((flags and BASS_INPUT_OFF) = 0) then
        BASS_RecordSetInput(i, BASS_INPUT_OFF, -1);
    end;
  end;

  Result := true;
end;

function TBassInputDevice.Open(): boolean;
var
  FormatFlags: DWORD;
  SourceIndex: integer;
  Latency: integer;
begin
  Result := false;

  if not DeviceIdentityMatches() then
  begin
    Log.LogError('BASS capture device identity changed; refusing to open a different device',
      'TBassInputDevice.Open');
    Exit;
  end;

  if (not BASS_RecordInit(BassDeviceID)) then
  begin
    Log.LogError('BASS_RecordInit['+Name+']: ' +
                 BassCore.ErrorGetString(), 'TBassInputDevice.Open');
    Exit;
  end;
  RecordInitialized := true;

  if not DeviceIdentityMatches() then
  begin
    Log.LogError('BASS capture device changed during initialization', 'TBassInputDevice.Open');
    Close();
    Exit;
  end;

  if (not BassCore.ConvertAudioFormatToBASSFlags(AudioFormat.Format, FormatFlags)) then
  begin
    Log.LogError('Unhandled sample-format', 'TBassInputDevice.Open');
    Close();
    Exit;
  end;

  { Use BASS's callback period field, honoring explicit per-device settings. }
  Latency := Ini.InputDeviceConfig[CfgIndex].Latency;
  if Latency <= 0 then Latency := 10;
  if Latency < 5 then Latency := 5;
  if Latency > 100 then Latency := 100;

  // start capturing in paused state
  RecordStream := BASS_RecordStart(Round(AudioFormat.SampleRate), AudioFormat.Channels,
                    MakeLong(FormatFlags or BASS_RECORD_PAUSE, Latency),
                    @MicrophoneCallback, Self);
  if (RecordStream = 0) then
  begin
    Log.LogError('BASS_RecordStart: ' + BassCore.ErrorGetString(), 'TBassInputDevice.Open');
    Close();
    Exit;
  end;

  // save current source selection and select new source
  SourceIndex := Ini.InputDeviceConfig[CfgIndex].Input-1;
  if (SourceIndex = -1) then
  begin
    // nothing to do if default source is used
    SourceRestore := -1;
  end
  else
  begin
    // store current source-index and select new source
    SourceRestore := GetInputSource();
    SetInputSource(SourceIndex);
  end;

  Result := true;
end;

{* Start input-capturing on this device. *}
function TBassInputDevice.Start(): boolean;
begin
  Result := false;

  // recording already started -> stop first
  if ((RecordStream <> 0) or RecordInitialized) and not Stop() then
  begin
    Log.LogError('Unable to clean up the previous BASS capture before restart',
      'TBassInputDevice.Start');
    Exit;
  end;

  // TODO: Do not open the device here (takes too much time).
  if not Open() then
    Exit;

  if (not BASS_ChannelPlay(RecordStream, true)) then
  begin
    Log.LogError('BASS_ChannelPlay: ' + BassCore.ErrorGetString(), 'TBassInputDevice.Start');
    Stop();
    Exit;
  end;

  Result := true;
end;

{* Stop input-capturing on this device. *}
function TBassInputDevice.Stop(): boolean;
var
  DeviceSelected: boolean;
  StopError: integer;
begin
  Result := true;

  { Stop the channel handle even if the device vanished or its ID was reused. }
  if (RecordStream <> 0) and not BASS_ChannelStop(RecordStream) then
  begin
    StopError := BASS_ErrorGetCode();
    { An invalid handle is already stopped; RecordFree below remains the cleanup check. }
    if StopError <> BASS_ERROR_HANDLE then
    begin
      Log.LogError('BASS_ChannelStop: ' + BassCore.ErrorGetString(), 'TBassInputDevice.Stop');
      Result := false;
    end;
  end;

  if not RecordInitialized then
    Exit;

  DeviceSelected := SelectCaptureDevice();
  if not DeviceSelected then
  begin
    { Do not free the currently selected, possibly unrelated BASS device. }
    Result := false;
    Exit;
  end;

  // TODO: Do not close the device here (takes too much time).
  if not Close() then Result := false;
end;

function TBassInputDevice.Close(): boolean;
begin
  Result := false;
  if not RecordInitialized then
  begin
    RecordStream := 0;
    Exit(true);
  end;
  if not SelectCaptureDevice() then Exit;

  // restore source selection
  if (SourceRestore >= 0) then
  begin
    SetInputSource(SourceRestore);
  end;

  // free data
  if (not BASS_RecordFree()) then
  begin
    Log.LogError('BASS_RecordFree: ' + BassCore.ErrorGetString(), 'TBassInputDevice.Close');
    Exit;
  end
  else
  begin
    Result := true;
  end;

  RecordInitialized := false;
  RecordStream := 0;
end;

function TBassInputDevice.GetVolume(): single;
var
  SourceIndex: integer;
  lVolume: Single;
begin
  lVolume := 0;
  Result := 0;

  SourceIndex := Ini.InputDeviceConfig[CfgIndex].Input-1;
  if (SourceIndex = -1) then
  begin
    // if default source used find selected source
    SourceIndex := GetInputSource();
    if (SourceIndex = -1) then
      Exit;
  end;

  if (BASS_RecordGetInput(SourceIndex, PSingle(lVolume)) = DWORD(-1)) then
  begin
    Log.LogError('BASS_RecordGetInput: ' + BassCore.ErrorGetString() , 'TBassInputDevice.GetVolume');
    Exit;
  end;
  Result := lVolume;
end;

procedure TBassInputDevice.SetVolume(Volume: single);
var
  SourceIndex: integer;
begin
  SourceIndex := Ini.InputDeviceConfig[CfgIndex].Input-1;
  if (SourceIndex = -1) then
  begin
    // if default source used find selected source
    SourceIndex := GetInputSource();
    if (SourceIndex = -1) then
      Exit;
  end;

  // clip volume to valid range
  if (Volume > 1.0) then
    Volume := 1.0
  else if (Volume < 0) then
    Volume := 0;

  if (not BASS_RecordSetInput(SourceIndex, 0, Volume)) then
  begin
    Log.LogError('BASS_RecordSetInput: ' + BassCore.ErrorGetString() , 'TBassInputDevice.SetVolume');
  end;
end;


{ TAudioInput_Bass }

function  TAudioInput_Bass.GetName: String;
begin
  result := 'BASS_Input';
end;

function TAudioInput_Bass.EnumDevices(): boolean;
var
  Descr:      UTF8String;
  SourceName: PChar;
  Flags:      integer;
  BassDeviceID: integer;
  BassDevice:   TBassInputDevice;
  DeviceIndex:  integer;
  DeviceInfo: BASS_DEVICEINFO;
  SourceIndex:  integer;
  RecordInfo: BASS_RECORDINFO;
begin
  result := false;

  DeviceIndex := 0;
  BassDeviceID := 0;
  SetLength(AudioInputProcessor.DeviceList, 0);

  // checks for recording devices and puts them into an array
  while true do
  begin
    if (not BASS_RecordGetDeviceInfo(BassDeviceID, DeviceInfo)) then
      break;

    // try to initialize the device
    if not BASS_RecordInit(BassDeviceID) then
    begin
      Log.LogStatus('Failed to initialize BASS Capture-Device['+inttostr(BassDeviceID)+']',
                    'TAudioInput_Bass.InitializeRecord');
    end
    else
    begin
      SetLength(AudioInputProcessor.DeviceList, DeviceIndex+1);

      // TODO: free object on termination
      BassDevice := TBassInputDevice.Create();
      AudioInputProcessor.DeviceList[DeviceIndex] := BassDevice;

      BassDevice.BassDeviceID := BassDeviceID;
      if DeviceInfo.name <> nil then
        BassDevice.RawDeviceName := AnsiString(DeviceInfo.name)
      else
        BassDevice.RawDeviceName := '';
      if DeviceInfo.driver <> nil then
        BassDevice.RawDeviceDriver := AnsiString(DeviceInfo.driver)
      else
        BassDevice.RawDeviceDriver := '';

      // BASS device names seem to be encoded with local encoding
      // TODO: works for windows, check Linux + Mac OS X
      Descr := DecodeStringUTF8(DeviceInfo.name, encAuto);

      BassDevice.Name := UnifyDeviceName(Descr, DeviceIndex);

      // zero info-struct as some fields might not be set (e.g. freq is just set on Vista and MacOSX)
      FillChar(RecordInfo, SizeOf(RecordInfo), 0);
      // retrieve recording device info
      BASS_RecordGetInfo(RecordInfo);

      // check if BASS has capture-freq. info
      if (RecordInfo.freq > 0) then
      begin
        // use current input sample rate (available only on Windows Vista and OSX).
        // Recording at this rate will give the best quality and performance, as no resampling is required.
        // FIXME: does BASS use LSB/MSB or system integer values for 16bit?
        BassDevice.AudioFormat := TAudioFormatInfo.Create(2, RecordInfo.freq, asfS16)
      end
      else
      begin
        // BASS does not provide an explizit input channel count (except BASS_RECORDINFO.formats)
        // but it doesn't fail if we use stereo input on a mono device
        // -> use stereo by default
        BassDevice.AudioFormat := TAudioFormatInfo.Create(2, 44100, asfS16)
      end;

      // get info if multiple input-sources can be selected at once
      BassDevice.SingleIn := RecordInfo.singlein;

      // init list for capture buffers per channel
      SetLength(BassDevice.CaptureChannel, BassDevice.AudioFormat.Channels);

      BassDevice.MicSource := -1;
      BassDevice.SourceRestore := -1;

      // add a virtual default source (will not change mixer-settings)
      SetLength(BassDevice.Source, 1);
      BassDevice.Source[0].Name := DEFAULT_SOURCE_NAME;

      // add real input sources
      SourceIndex := 1;

      // process each input
      while true do
      begin
        SourceName := BASS_RecordGetInputName(SourceIndex-1);

        {$IFDEF DARWIN}
        // Under MacOSX the SingStar Mics have an empty InputName.
        // So, we have to add a hard coded Workaround for this problem
        // FIXME: - Do we need this anymore? Doesn't the (new) default source already solve this problem?
        //        - Normally a nil return value of BASS_RecordGetInputName() means end-of-list, so maybe
        //          BASS is not able to detect any mic-sources (the default source will work then).
        //        - Does BASS_RecordGetInfo() return true or false? If it returns true in this case
        //          we could use this value to check if the device exists.
        //          Please check that, eddie.
        //          If it returns false, then the source is not detected and it does not make sense to add a second
        //          fake device here.
        //          What about BASS_RecordGetInput()? Does it return a value <> -1?
        //        - Does it even work at all with this fake source-index, now that input switching works?
        //          This info was not used before (sources were never switched), so it did not matter what source-index was used.
        //          But now BASS_RecordSetInput() will probably fail.
        if ((SourceName = nil) and (SourceIndex = 1) and (Pos('USBMIC Serial#', Descr) > 0)) then
          SourceName := 'Microphone'
        {$ENDIF}
        
        if (SourceName = nil) then
          break;

        SetLength(BassDevice.Source, Length(BassDevice.Source)+1);
        // BASS source names seem to be encoded with local encoding
        // TODO: works for windows, check Linux + Mac OS X
        BassDevice.Source[SourceIndex].Name := DecodeStringUTF8(SourceName, encAuto);

        // get input-source info
        {$push} {$R-}
        Flags := BASS_RecordGetInput(SourceIndex, nil);
        {$POP}
        if (Flags <> -1) then
        begin
          // chech if current source is a mic (and none was set before)
          if ((Flags and BASS_INPUT_TYPE_MIC) <> 0) and
             (BassDevice.MicSource = -1) then
          begin
            BassDevice.MicSource := SourceIndex;
          end;
        end;

        Inc(SourceIndex);
      end;

      // FIXME: this call hangs in FPC (windows) every 2nd time USDX is called.
      //   Maybe because the sound-device was not released properly?
      BASS_RecordFree;

      Inc(DeviceIndex);
    end;

    Inc(BassDeviceID);
  end;

  result := true;
end;

function TAudioInput_Bass.InitializeRecord(): boolean;
begin
  BassCore := TAudioCore_Bass.GetInstance();
  if not BassCore.CheckVersion then
  begin
    Result := false;
    Exit;
  end;
  Result := EnumDevices();
end;

function TAudioInput_Bass.FinalizeRecord(): boolean;
begin
  CaptureStop;
  Result := inherited FinalizeRecord;
end;

procedure TAudioInput_Bass.CheckCaptureHealth;
var
  Tick: Cardinal;
  DeviceIndex, ChannelIndex: Integer;
  Device: TBassInputDevice;
  HasLinkedChannel, AllChannelsStale, Recover: Boolean;
  SameDevice, Stopped: Boolean;
begin
  Tick := SDL_GetTicks;
  if fHealthCheckStarted and (Cardinal(Tick-fLastHealthCheck) < 2000) then
    Exit;
  fLastHealthCheck := Tick;
  fHealthCheckStarted := True;

  for DeviceIndex := 0 to High(AudioInputProcessor.DeviceList) do
  begin
    if not (AudioInputProcessor.DeviceList[DeviceIndex] is TBassInputDevice) then
      Continue;
    Device := TBassInputDevice(AudioInputProcessor.DeviceList[DeviceIndex]);
    HasLinkedChannel := False;
    AllChannelsStale := True;
    for ChannelIndex := 0 to High(Device.CaptureChannel) do
      if Assigned(Device.CaptureChannel[ChannelIndex]) then
      begin
        HasLinkedChannel := True;
        if Device.CaptureChannel[ChannelIndex].CaptureAge < 1500 then
          AllChannelsStale := False;
      end;
    if not HasLinkedChannel then
      Continue;

    Recover := Device.RecordStream = 0;
    if not Recover then
      Recover := BASS_ChannelIsActive(Device.RecordStream) = BASS_ACTIVE_STOPPED;
    if not Recover then
      Recover := AllChannelsStale;
    if not Recover then
      Continue;

    SameDevice := Device.DeviceIdentityMatches() and
      not Device.DeviceIdentityIsAmbiguous();
    if SameDevice then
      Log.LogStatus('BASS capture stalled; restarting ' + Device.Name,
        'TAudioInput_Bass.CheckCaptureHealth')
    else if Device.DeviceIdentityMatches() then
      Log.LogError('BASS capture device identity is ambiguous; refusing automatic recovery',
        'TAudioInput_Bass.CheckCaptureHealth')
    else
      Log.LogError('BASS capture device is missing or changed; refusing to reopen another input',
        'TAudioInput_Bass.CheckCaptureHealth');

    Stopped := Device.Stop();
    for ChannelIndex := 0 to High(Device.CaptureChannel) do
      if Assigned(Device.CaptureChannel[ChannelIndex]) then
        Device.CaptureChannel[ChannelIndex].Clear;

    if not SameDevice then
      Continue;
    if not Stopped then
    begin
      Log.LogError('BASS capture cleanup failed; restart deferred',
        'TAudioInput_Bass.CheckCaptureHealth');
      Continue;
    end;
    if Device.Start() then
      Log.LogStatus('BASS capture restarted ' + Device.Name,
        'TAudioInput_Bass.CheckCaptureHealth')
    else
      Log.LogError('BASS capture restart failed ' + Device.Name + ': ' + BassCore.ErrorGetString(),
        'TAudioInput_Bass.CheckCaptureHealth');
  end;
end;


initialization
  MediaManager.Add(TAudioInput_Bass.Create);

end.
