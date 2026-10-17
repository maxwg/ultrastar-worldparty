program VoiceMonitorStreamTest;
{$mode objfpc}{$H+}

uses
  Math, SysUtils, UMusic, UAudioPlayback_SoftMixer;

type
  THeadlessSoftMixer = class(TAudioPlayback_SoftMixer)
  protected
    function InitializeAudioPlaybackEngine: Boolean; override;
    function StartAudioPlaybackEngine: Boolean; override;
    procedure StopAudioPlaybackEngine; override;
    function FinalizeAudioPlaybackEngine: Boolean; override;
    function GetLatency: Double; override;
  public
    function GetName: string; override;
  end;

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

function THeadlessSoftMixer.InitializeAudioPlaybackEngine: Boolean;
begin
  { Exercise the production mixer at its native 48kHz stereo S16 format. }
  FormatInfo := TAudioFormatInfo.Create(2, 48000, asfS16);
  Result := True;
end;

function THeadlessSoftMixer.StartAudioPlaybackEngine: Boolean;
begin
  Result := True;
end;

procedure THeadlessSoftMixer.StopAudioPlaybackEngine;
begin
end;

function THeadlessSoftMixer.FinalizeAudioPlaybackEngine: Boolean;
begin
  Result := True;
end;

function THeadlessSoftMixer.GetName: string;
begin
  Result := 'headless production soft mixer';
end;

function THeadlessSoftMixer.GetLatency: Double;
begin
  Result := 0;
end;

function IsSilent(const Buffer: array of Byte): Boolean;
var I: Integer;
begin
  Result := True;
  for I := 0 to High(Buffer) do
    if Buffer[I] <> 0 then Exit(False);
end;

procedure ReadMixerBlock(Mixer: TAudioMixerStream; var Buffer: array of Byte);
begin
  FillChar(Buffer[0], Length(Buffer), $CC);
  Check(Mixer.ReadData(PByteArray(@Buffer[0]), Length(Buffer)) = Length(Buffer),
    'production mixer returns a complete small callback block');
end;

var
  Engine: THeadlessSoftMixer;
  Voice: TAudioVoiceStream;
  InputFormat: TAudioFormatInfo;
  Input: array[0..1322] of SmallInt;
  Output: array[0..511] of Byte;
  I, J, Frame, Sign, PreviousSign, CrossingCount, FirstCrossing,
    LastCrossing, ValidFrames, TotalOutputFrames, ZeroBlocks: Integer;
  TotalInputFrames, InputCrossings, InputPreviousSign, SourceFramesToWrite: Integer;
  SourceFrameRemainder: Double;
  LeftSample, RightSample: SmallInt;
  EstimatedHz: Double;
  GotVoiceAfterUnderrun, GotAnyVoice: Boolean;
begin
  Assertions := 0;
  Engine := THeadlessSoftMixer.Create;
  InputFormat := nil;
  Voice := nil;
  try
    Check(Engine.InitializePlayback, 'headless subclass initializes production mixer');
    Check((Engine.GetAudioFormatInfo.Channels = 2) and
      (Round(Engine.GetAudioFormatInfo.SampleRate) = 48000) and
      (Engine.GetAudioFormatInfo.Format = asfS16),
      'production mixer uses configured stereo 48kHz S16 output');
    Engine.SetAppVolume(1.0);

    InputFormat := TAudioFormatInfo.Create(1, 44100, asfS16);
    Voice := Engine.CreateVoiceStream(CHANNELMAP_FRONT, InputFormat);
    Check(Voice <> nil, 'production voice stream opens mono 44.1kHz source');
    Check((Voice.GetAudioFormatInfo.Channels = 1) and
      (Round(Voice.GetAudioFormatInfo.SampleRate) = 44100),
      'voice stream retains mono source format before production conversion');

    ReadMixerBlock(Engine.GetMixer, Output);
    Check(IsSilent(Output), 'empty production voice queue renders callback silence');

    { Start with 30ms of source headroom. The production converter requests
      source in 256-frame chunks, so a short callback-sized write can otherwise
      make its queue zero-pad even when average producer and consumer rates
      match. Then produce at the exact rational 44.1kHz/48kHz cadence, one
      128-frame output callback at a time. }
    CrossingCount := 0;
    FirstCrossing := -1;
    LastCrossing := -1;
    PreviousSign := 0;
    ValidFrames := 0;
    TotalOutputFrames := 0;
    TotalInputFrames := 0;
    InputCrossings := 0;
    InputPreviousSign := 0;
    GotVoiceAfterUnderrun := False;
    for J := 0 to High(Input) do
    begin
      Input[J] := Round(12000 * Sin(2 * Pi * 440 *
        (TotalInputFrames + J) / 44100));
      if Input[J] > 0 then Sign := 1 else Sign := -1;
      if (InputPreviousSign <> 0) and (Sign <> InputPreviousSign) then
        Inc(InputCrossings);
      InputPreviousSign := Sign;
    end;
    Voice.WriteData(PByteArray(@Input[0]), SizeOf(Input));
    Inc(TotalInputFrames, Length(Input));

    SourceFrameRemainder := 0;
    for I := 0 to 219 do
    begin
      SourceFrameRemainder := SourceFrameRemainder + 128 * 44100 / 48000;
      SourceFramesToWrite := Trunc(SourceFrameRemainder);
      SourceFrameRemainder := SourceFrameRemainder - SourceFramesToWrite;
      for J := 0 to SourceFramesToWrite - 1 do
      begin
        Input[J] := Round(12000 * Sin(2 * Pi * 440 *
          (TotalInputFrames + J) / 44100));
        if Input[J] > 0 then Sign := 1 else Sign := -1;
        if (InputPreviousSign <> 0) and (Sign <> InputPreviousSign) then
          Inc(InputCrossings);
        InputPreviousSign := Sign;
      end;
      Voice.WriteData(PByteArray(@Input[0]), SourceFramesToWrite * SizeOf(SmallInt));
      Inc(TotalInputFrames, SourceFramesToWrite);

      ReadMixerBlock(Engine.GetMixer, Output);
      for Frame := 0 to 127 do
      begin
        LeftSample := PSmallInt(@Output[Frame * 4])^;
        RightSample := PSmallInt(@Output[Frame * 4 + 2])^;
        Check(LeftSample = RightSample,
          'production converter duplicates mono voice into both output channels');
        if Abs(Integer(LeftSample)) > 100 then
        begin
          Inc(ValidFrames);
          GotVoiceAfterUnderrun := True;
          if LeftSample > 0 then Sign := 1 else Sign := -1;
          if (PreviousSign <> 0) and (Sign <> PreviousSign) then
          begin
            Inc(CrossingCount);
            if FirstCrossing < 0 then FirstCrossing := TotalOutputFrames + Frame;
            LastCrossing := TotalOutputFrames + Frame;
          end;
          PreviousSign := Sign;
        end;
      end;
      Inc(TotalOutputFrames, 128);
    end;

    Check(GotVoiceAfterUnderrun,
      'production stream resumes with captured voice after an underrun');
    Check((ValidFrames > 20000) and (CrossingCount > 300),
      'small callback blocks carry sustained resampled voice');
    EstimatedHz := InputCrossings * 44100 / (2 * TotalInputFrames);
    Check(Abs(EstimatedHz - 440) <= 1,
      'known source PCM is actually 440Hz before renderer conversion');
    EstimatedHz := (CrossingCount - 1) * 48000 /
      (2 * (LastCrossing - FirstCrossing));
    WriteLn('Measured production-converted tone: ', FormatFloat('0.00', EstimatedHz),
      'Hz from ', CrossingCount, ' crossings / ', ValidFrames, ' non-zero frames');

    { After consuming the bounded queue and converter tail, empty callbacks
      must stay silent; a later write must restart audio without reopening. }
    ZeroBlocks := 0;
    for I := 0 to 19 do
    begin
      ReadMixerBlock(Engine.GetMixer, Output);
      if IsSilent(Output) then Inc(ZeroBlocks);
    end;
    Check(ZeroBlocks > 0, 'drained production queue eventually returns silence');

    for J := 0 to High(Input) do
      Input[J] := Round(8000 * Sin(2 * Pi * 330 * J / 44100));
    Voice.WriteData(PByteArray(@Input[0]), SizeOf(Input));
    GotAnyVoice := False;
    for I := 0 to 7 do
    begin
      ReadMixerBlock(Engine.GetMixer, Output);
      for Frame := 0 to 127 do
        if Abs(Integer(PSmallInt(@Output[Frame * 4])^)) > 100 then
          GotAnyVoice := True;
    end;
    Check(GotAnyVoice, 'same production stream recovers after drained silence');
    Check(Abs(EstimatedHz - 440) <= 2,
      '44.1-to-48k production conversion preserves pitch without detune');

    WriteLn('PASS: ', Assertions,
      ' production voice-stream/converter/underrun assertions; 440Hz -> ',
      FormatFloat('0.00', EstimatedHz), 'Hz');
  finally
    FreeAndNil(Voice);
    FreeAndNil(InputFormat);
    Engine.FinalizePlayback;
    Engine.Free;
  end;
end.
