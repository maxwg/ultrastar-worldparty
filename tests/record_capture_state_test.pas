program RecordCaptureStateTest;
{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cmem,
  cthreads,
  {$ENDIF}
  Math,
  SDL2,
  SysUtils,
  UIni,
  UNote,
  UMusic,
  URecord;

type
  TFakeInputDevice = class(TAudioInputDevice)
    StartCount: Integer;
    StopCount: Integer;
    StartResult: Boolean;
    function Start: Boolean; override;
    function Stop: Boolean; override;
    function GetVolume: Single; override;
    procedure SetVolume(Volume: Single); override;
  end;

  TFakeAudioInput = class(TAudioInputBase)
    function GetName: String; override;
    function InitializeRecord: Boolean; override;
  end;

var
  Buffer: TCaptureBuffer;
  AudioProcessor: TAudioInputProcessor;
  AudioBackend: TFakeAudioInput;
  InputDevice: TFakeInputDevice;
  Assertions: Integer;
  Sample: Byte;
  NoiseSeed: LongWord;
  SampleIndex: Integer;
  PCM: array[0..8191] of SmallInt;
  Frequency: Double;

{$IFDEF MSWINDOWS}
var
  LastMockTicks: Cardinal = 0;
  MockTicksStarted: Boolean = False;

procedure SetMockTicks(Ticks: Cardinal);
var
  Delay: Cardinal;
begin
  { SDL_GetTicks is real on Windows; simulate advances by sleeping only the
    requested delta so expiry tests exercise the production clock path. }
  if MockTicksStarted then
  begin
    Delay := Ticks - LastMockTicks;
    if Delay > 0 then SDL_Delay(Delay);
  end;
  if not MockTicksStarted then
    SDL_Delay(1); { avoid the production zero-tick sentinel on the first frame }
  LastMockTicks := Ticks;
  MockTicksStarted := True;
end;
{$ELSE}
procedure SetMockTicks(Ticks: Cardinal); cdecl;
  external 'SDL2' name 'SDL_TestSetTicks';
{$ENDIF}

procedure Check(Condition: Boolean; const Why: String);
begin
  Inc(Assertions);
  if not Condition then
  begin
    WriteLn('FAIL: ', Why);
    Halt(1);
  end;
end;

function TFakeInputDevice.Start: Boolean;
begin
  Inc(StartCount);
  Result := StartResult;
end;

function TFakeInputDevice.Stop: Boolean;
begin
  Inc(StopCount);
  Result := True;
end;

function TFakeInputDevice.GetVolume: Single;
begin
  Result := 0;
end;

procedure TFakeInputDevice.SetVolume(Volume: Single);
begin
end;

function TFakeAudioInput.GetName: String;
begin
  Result := 'fake';
end;

function TFakeAudioInput.InitializeRecord: Boolean;
begin
  Result := True;
end;

begin
  Assertions := 0;
  Ini := TIni.Create;
  Buffer := TCaptureBuffer.Create;
  try
    Buffer.ToneValid := True;
    Buffer.Tone := 7;
    Buffer.ToneAbs := 19;
    Buffer.RawPitch.Valid := True;
    Buffer.RawPitch.Hz := 440;
    Buffer.RawPitch.Midi := 31;
    Check(Buffer.ToneString = 'G1', 'low voice readout uses the true octave below C2');
    Buffer.AnalysisBuffer[0] := 1234;
    Sample := 123;
    Buffer.LogBuffer.WriteBuffer(Sample, SizeOf(Sample));

    Buffer.Clear;

    Check(not Buffer.ToneValid, 'scoring tone invalidated');
    Check(Buffer.Tone = -1, 'scoring tone reset');
    Check(Buffer.ToneAbs = -1, 'absolute scoring tone reset');
    Check(not Buffer.RawPitch.Valid, 'continuous pitch invalidated');
    Check(not Buffer.ScorePitch.Valid, 'scoring pitch invalidated');
    Check(not Buffer.VoiceActive, 'rap activity state reset');
    Check(Buffer.RawPitch.Hz = 0, 'continuous pitch value reset');
    Check(Buffer.AnalysisBuffer[0] = 0, 'analysis PCM cleared');
    Check(Buffer.LogBuffer.Size = 0, 'recorded PCM log cleared');
  finally
    Buffer.Free;
  end;

  AudioProcessor := AudioInputProcessor;
  AudioBackend := TFakeAudioInput.Create;
  InputDevice := TFakeInputDevice.Create;
  try
    SetLength(Ini.InputDeviceConfig, 1);
    Ini.InputDeviceConfig[0].Name := 'fake mic';
    SetLength(Ini.InputDeviceConfig[0].ChannelToPlayerMap, 2);
    Ini.InputDeviceConfig[0].ChannelToPlayerMap[0] := 1;
    Ini.InputDeviceConfig[0].ChannelToPlayerMap[1] := CHANNEL_OFF;

    InputDevice.CfgIndex := 0;
    InputDevice.Name := 'fake mic';
    InputDevice.AudioFormat := TAudioFormatInfo.Create(2, 44100, asfS16);
    SetLength(InputDevice.CaptureChannel, 2);
    InputDevice.StartResult := True;
    SetLength(AudioProcessor.DeviceList, 1);
    AudioProcessor.DeviceList[0] := InputDevice;
    PlayersPlay := 1;
    Ini.VoicePassthrough := 0;
    Ini.DetectedPitch := 0;
    Ini.ThresholdIndex := High(IThreshold);
    Ini.SavePlayback := 0;

    { Song A starts on player 1's first input channel. }
    AudioBackend.CaptureStart;
    Check(InputDevice.StartCount = 1, 'first song starts assigned device');
    Check(InputDevice.CaptureChannel[0] = AudioProcessor.Sound[0],
      'first song maps player 1');
    Check(InputDevice.CaptureChannel[1] = nil, 'unused channel stays unlinked');

    { Feed a synthetic A4 sine through the production interleaving and pitch path. }
    SetMockTicks(1000);
    Frequency := 440;
    for SampleIndex := 0 to 4095 do
    begin
      PCM[SampleIndex * 2] := Round(Sin(2 * Pi * Frequency * SampleIndex / 44100) * 12000);
      PCM[SampleIndex * 2 + 1] := PCM[SampleIndex * 2];
    end;
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(AudioProcessor.Sound[0].ToneValid, 'synthetic tone produces a scoring note with F7 pitch display off');
    Check(AudioProcessor.Sound[0].RawPitch.Valid, 'synthetic tone produces detected pitch with F7 pitch display off');
    Check(AudioProcessor.Sound[0].ToneString = 'A4', 'microphone preview reports the detected scientific note');
    Check(Abs(AudioProcessor.Sound[0].RawPitch.Hz - Frequency) < 15,
      'synthetic A4 pitch is measured within tolerance');
    Check((AudioProcessor.Sound[0].ToneAbs >= 0) and
      ((AudioProcessor.Sound[0].ToneAbs mod 12) = 9),
      'synthetic A4 maps to the correct scoring pitch class');

    { Automatic sensitivity should accept a quiet voice, independent of F7. }
    SetMockTicks(1030);
    Frequency := 440;
    for SampleIndex := 0 to 4095 do
    begin
      PCM[SampleIndex * 2] := Round(Sin(2 * Pi * Frequency * SampleIndex / 44100) * 250);
      PCM[SampleIndex * 2 + 1] := PCM[SampleIndex * 2];
    end;
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(AudioProcessor.Sound[0].ToneValid and AudioProcessor.Sound[0].RawPitch.Valid,
      'automatic sensitivity accepts a quiet voiced signal');

    { Broadband noise stays unvoiced; a later silence also expires score grace. }
    SetMockTicks(1060);
    NoiseSeed := $13579BDF;
    for SampleIndex := 0 to 8191 do
    begin
      NoiseSeed := NoiseSeed * 1664525 + 1013904223;
      PCM[SampleIndex] := SmallInt((NoiseSeed shr 16) and $7FFF) - 16384;
    end;
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(not AudioProcessor.Sound[0].ToneValid and
      not AudioProcessor.Sound[0].RawPitch.Valid,
      'broadband noise is not treated as a voiced scoring tone');
    Check(AudioProcessor.Sound[0].VoiceActive,
      'broadband unpitched activity remains available for rap-note scoring');

    SetMockTicks(1121);
    FillChar(PCM, SizeOf(PCM), 0);
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(not AudioProcessor.Sound[0].ScorePitch.Valid,
      'silence after the short grace period does not keep a stale scoring pitch');
    Check(not AudioProcessor.Sound[0].VoiceActive,
      'silence does not remain active for rap-note scoring');

    { Repeated calls on unchanged PCM use the cached estimate. }
    SetMockTicks(1200);
    for SampleIndex := 0 to 4095 do
    begin
      PCM[SampleIndex * 2] := Round(Sin(2 * Pi * 440 * SampleIndex / 44100) * 12000);
      PCM[SampleIndex * 2 + 1] := PCM[SampleIndex * 2];
    end;
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Frequency := AudioProcessor.Sound[0].RawPitch.Midi;
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(AudioProcessor.Sound[0].ToneValid and
      (AudioProcessor.Sound[0].RawPitch.Midi = Frequency),
      'same-PCM analysis reuses a stable cached pitch estimate');

    { Same voiced PCM stays fresh for the capture timeout; an invalid frame
      then gets at most 60ms of scoring grace. }
    SetMockTicks(1210);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(AudioProcessor.Sound[0].ScorePitch.Valid,
      'unchanged voiced PCM remains valid inside the 250ms freshness window');
    SetMockTicks(1220);
    FillChar(PCM, SizeOf(PCM), 0);
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(not AudioProcessor.Sound[0].ToneValid and
      AudioProcessor.Sound[0].ScorePitch.Valid,
      'new silence is unvoiced but receives the short scoring grace');
    SetMockTicks(1261);
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(not AudioProcessor.Sound[0].ScorePitch.Valid,
      'scoring grace expires 61ms after the last voiced frame');

    { Song B has two players, so CaptureStart must stop/relink/restart cleanly. }
    AudioProcessor.Sound[0].ToneValid := True;
    AudioProcessor.Sound[0].Tone := 8;
    Ini.InputDeviceConfig[0].ChannelToPlayerMap[0] := 2;
    Ini.InputDeviceConfig[0].ChannelToPlayerMap[1] := 1;
    PlayersPlay := 2;
    AudioBackend.CaptureStart;
    Check(InputDevice.StopCount = 1, 'song switch stops previous capture');
    Check(InputDevice.StartCount = 2, 'song switch restarts capture');
    Check(InputDevice.CaptureChannel[0] = AudioProcessor.Sound[1],
      'song switch applies changed channel map');
    Check(InputDevice.CaptureChannel[1] = AudioProcessor.Sound[0],
      'song switch maps second channel to player 1');
    Check(not AudioProcessor.Sound[0].ToneValid and
      (AudioProcessor.Sound[0].Tone = -1), 'song switch clears prior scoring note');

    { Distinct channel tones follow Song B's changed player map. }
    SetMockTicks(1300);
    Frequency := 220;
    for SampleIndex := 0 to 4095 do
    begin
      PCM[SampleIndex * 2] := Round(Sin(2 * Pi * Frequency * SampleIndex / 44100) * 12000);
      PCM[SampleIndex * 2 + 1] := Round(Sin(2 * Pi * 330 * SampleIndex / 44100) * 12000);
    end;
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[1].AnalyzeBuffer;
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(AudioProcessor.Sound[1].ToneValid and AudioProcessor.Sound[0].ToneValid,
      'song B synthetic tone reaches both mapped players');
    Check(Abs(AudioProcessor.Sound[1].RawPitch.Hz - Frequency) < 15,
      'song B channel 1 pitch follows changed audio mapping');
    Check(Abs(AudioProcessor.Sound[0].RawPitch.Hz - 330) < 15,
      'song B channel 2 pitch follows changed audio mapping');

    { A valid note expires when no new audio arrives for 250 ms. }
    SetMockTicks(1550);
    AudioProcessor.Sound[1].AnalyzeBuffer;
    AudioProcessor.Sound[0].AnalyzeBuffer;
    Check(not AudioProcessor.Sound[1].ToneValid and
      not AudioProcessor.Sound[1].RawPitch.Valid,
      '250ms capture gap invalidates previously valid pitch');

    { Silence does not create a scoring note. }
    SetMockTicks(1600);
    FillChar(PCM, SizeOf(PCM), 0);
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[1].AnalyzeBuffer;
    Check(not AudioProcessor.Sound[1].ToneValid and
      not AudioProcessor.Sound[1].RawPitch.Valid,
      'silence invalidates both scoring and detected pitch');

    { Simulate menu-exit capture stop and a temporarily unavailable device. }
    AudioBackend.CaptureStop;
    Check(InputDevice.StopCount = 2, 'capture-stop entrypoint stops capture');
    InputDevice.StartResult := False;
    AudioBackend.CaptureStart;
    Check(InputDevice.StartCount = 3, 'unavailable device start attempted');
    InputDevice.StartResult := True;
    AudioBackend.CaptureStart;
    Check(InputDevice.StopCount = 3, 'failed start is cleaned before retry');
    Check(InputDevice.StartCount = 4, 'device reconnect retries capture');
    Check(InputDevice.CaptureChannel[0] = AudioProcessor.Sound[1],
      'reconnect preserves current channel mapping');
    SetMockTicks(1800);
    Frequency := 330;
    for SampleIndex := 0 to 4095 do
    begin
      PCM[SampleIndex * 2] := Round(Sin(2 * Pi * Frequency * SampleIndex / 44100) * 12000);
      PCM[SampleIndex * 2 + 1] := PCM[SampleIndex * 2];
    end;
    AudioProcessor.HandleMicrophoneData(PByteArray(@PCM[0]), SizeOf(PCM), InputDevice);
    AudioProcessor.Sound[1].AnalyzeBuffer;
    Check(AudioProcessor.Sound[1].ToneValid and
      (Abs(AudioProcessor.Sound[1].RawPitch.Hz - Frequency) < 15),
      'reconnected capture processes a fresh synthetic tone');
    AudioBackend.CaptureStop;
    Check(InputDevice.StopCount = 4, 'final capture-stop entrypoint stops capture');
    WriteLn('PASS: ', Assertions, ' production capture-state/lifecycle assertions');
  finally
    AudioBackend.CaptureStop;
    AudioProcessor.DeviceList := nil;
    InputDevice.Free;
    AudioBackend.Free;
    AudioProcessor.Free;
    FreeAndNil(Ini);
  end;
end.
