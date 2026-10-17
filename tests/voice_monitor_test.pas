program VoiceMonitorTest;
{$mode objfpc}{$H+}

uses
  Math, SysUtils, URingBuffer, UVoiceMonitor;

type
  TSmallIntArray = array of SmallInt;
  TByteArray = array of Byte;

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

procedure TestRingWrap;
var
  Ring: TRingBuffer;
  First, Second: TByteArray;
  Output: array[0..15] of Byte;
  I: Integer;
begin
  Ring := TRingBuffer.Create(16);
  try
    SetLength(First, 12);
    for I := 0 to High(First) do First[I] := I;
    Check(Ring.Write(PByteArray(@First[0]), Length(First)) = 12,
      'ring accepts first tagged segment');
    FillChar(Output, SizeOf(Output), $CC);
    Check(Ring.Read(PByteArray(@Output[3]), 10) = 10,
      'ring reads prefix before wrap');
    Check((Output[3] = 0) and (Output[12] = 9) and (Output[2] = $CC),
      'first read respects destination offset');

    SetLength(Second, 10);
    for I := 0 to High(Second) do Second[I] := 100 + I;
    Check(Ring.Write(PByteArray(@Second[0]), Length(Second)) = 10,
      'ring writes second segment across end');
    FillChar(Output, SizeOf(Output), $CC);
    Check(Ring.Read(PByteArray(@Output[2]), 12) = 12,
      'ring reads wrapped segment');
    Check((Output[1] = $CC) and (Output[2] = 10) and (Output[3] = 11),
      'wrapped read starts with unread old bytes at destination offset');
    for I := 0 to 9 do
      Check(Output[I + 4] = 100 + I,
        'wrapped bytes stay ordered and uncorrupted');
  finally
    Ring.Free;
  end;
end;

procedure TestQueueOverflowAndUnderrun;
var
  Queue: TVoiceMonitorQueue;
  InputSamples, OutputSamples: TSmallIntArray;
  PartialInput, PartialOutput: TByteArray;
  I, ReadCount: Integer;
begin
  Queue := TVoiceMonitorQueue.Create(1000, SizeOf(SmallInt));
  try
    SetLength(InputSamples, 60);
    for I := 0 to High(InputSamples) do InputSamples[I] := I + 1;
    Check(Queue.Capacity = 80, '40ms queue capacity uses complete S16 frames');
    Queue.Write(PByteArray(@InputSamples[0]), Length(InputSamples) * SizeOf(SmallInt));
    Check(Queue.Available = Queue.Capacity, 'queue remains bounded at capacity');
    SetLength(OutputSamples, Queue.Capacity div SizeOf(SmallInt));
    ReadCount := Queue.Read(PByteArray(@OutputSamples[0]), Queue.Capacity);
    Check(ReadCount = Queue.Capacity, 'queue drains a full frame-aligned block');
    for I := 0 to High(OutputSamples) do
      Check(OutputSamples[I] = I + 21,
        'overflow drops stale samples and preserves freshest ordered audio');

    FillChar(OutputSamples[0], Length(OutputSamples) * SizeOf(SmallInt), $7F);
    ReadCount := Queue.Read(PByteArray(@OutputSamples[0]), 8);
    Check(ReadCount = 8, 'empty queue returns requested aligned frame count');
    Check((OutputSamples[0] = 0) and (OutputSamples[3] = 0),
      'empty queue fully zero-pads underrun');

    InputSamples[0] := -1234;
    InputSamples[1] := 2345;
    Queue.Write(PByteArray(@InputSamples[0]), 2 * SizeOf(SmallInt));
    ReadCount := Queue.Read(PByteArray(@OutputSamples[0]), 2 * SizeOf(SmallInt));
    Check((ReadCount = 4) and (OutputSamples[0] = -1234) and
      (OutputSamples[1] = 2345), 'queue resumes with fresh audio after underrun');
  finally
    Queue.Free;
  end;

  Queue := TVoiceMonitorQueue.Create(1000, 4);
  try
    SetLength(PartialInput, 5);
    PartialInput[0] := 10; PartialInput[1] := 11;
    PartialInput[2] := 12; PartialInput[3] := 13;
    PartialInput[4] := 99;
    Queue.Write(PByteArray(@PartialInput[0]), Length(PartialInput));
    Check(Queue.Available = 4, 'partial trailing input frame is ignored');
    SetLength(PartialOutput, 5);
    FillChar(PartialOutput[0], Length(PartialOutput), $CC);
    ReadCount := Queue.Read(PByteArray(@PartialOutput[0]), Length(PartialOutput));
    Check(ReadCount = 4, 'queue read is rounded down to whole output frames');
    Check((PartialOutput[0] = 10) and (PartialOutput[3] = 13) and
      (PartialOutput[4] = $CC), 'partial frame never leaks into queue output');
  finally
    Queue.Free;
  end;
end;

function RMS(const Samples: TSmallIntArray; StartAt, Count: Integer): Double;
var
  I: Integer;
  Energy: Double;
begin
  Energy := 0;
  for I := StartAt to StartAt + Count - 1 do
    Energy := Energy + Sqr(Samples[I] / 32768.0);
  Result := Sqrt(Energy / Count);
end;

function Peak(const Samples: TSmallIntArray): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Samples) do
    Result := Max(Result, Abs(Integer(Samples[I])));
end;

procedure FillSignal(var Samples: TSmallIntArray; Value: SmallInt);
var I: Integer;
begin
  for I := 0 to High(Samples) do Samples[I] := Value;
end;

procedure RenderConstant(Value: SmallInt; Volume, MusicRMS: Double;
  Microphones: Integer; out Input, Output: TSmallIntArray);
var
  State: TVoiceMonitorState;
begin
  SetLength(Input, 48000);
  SetLength(Output, Length(Input));
  FillSignal(Input, Value);
  FillChar(State, SizeOf(State), 0);
  RenderVoiceMonitor(State, PMonitorSamples(@Input[0]), PMonitorSamples(@Output[0]),
    Length(Input), 48000, MusicRMS, Volume, Microphones);
end;

procedure TestMonitorGainAndCaps;
var
  Input, Output, Original: TSmallIntArray;
  State: TVoiceMonitorState;
  I, MixedPeak: Integer;
  Combined: Int64;
begin
  RenderConstant(5000, 0.20, 0.80, 1, Input, Output);
  Original := Copy(Input);
  Check((RMS(Output, 12000, 36000) / RMS(Input, 12000, 36000) > 0.19) and
    (RMS(Output, 12000, 36000) / RMS(Input, 12000, 36000) < 0.21),
    'steady monitor level follows requested low gain');
  for I := 0 to High(Input) do
    Check(Input[I] = Original[I], 'monitor rendering leaves capture PCM unchanged');

  RenderConstant(5000, 0.40, 0.80, 1, Input, Output);
  Check((RMS(Output, 12000, 36000) / RMS(Input, 12000, 36000) > 0.39) and
    (RMS(Output, 12000, 36000) / RMS(Input, 12000, 36000) < 0.41),
    'steady monitor level scales independently with requested gain');

  RenderConstant(16000, 0.50, 0.20, 1, Input, Output);
  Check(RMS(Output, 12000, 36000) <= 0.101,
    'monitor RMS stays below half the backing-track RMS');
  Check(Peak(Output) < 32768, 'RMS-limited monitor signal cannot clip');

  RenderConstant(16000, 0.50, -1.0, 1, Input, Output);
  Check(RMS(Output, 12000, 36000) <= 0.026,
    'no-backing-track setup uses a quiet RMS ceiling');

  RenderConstant(30000, 0.50, 0.60, 6, Input, Output);
  MixedPeak := Peak(Output);
  Combined := Int64(MixedPeak) * 6;
  Check(MixedPeak <= 1093, 'six-microphone per-channel peak is capped');
  Check(Combined <= 6554, 'six microphone peaks together stay under 20 percent full scale');

  SetLength(Input, 8);
  SetLength(Output, 8);
  for I := 0 to High(Input) do Input[I] := 32767;
  Input[0] := -32768;
  FillChar(State, SizeOf(State), 0);
  RenderVoiceMonitor(State, PMonitorSamples(@Input[0]), PMonitorSamples(@Output[0]),
    Length(Input), 48000, 1.0, 0.5, 1);
  Check(Peak(Output) <= 6554, 'hard peak limiter caps positive and negative full scale');

  FillChar(State, SizeOf(State), 0);
  RenderVoiceMonitor(State, PMonitorSamples(@Input[0]), PMonitorSamples(@Output[0]),
    Length(Input), 48000, 1.0, 0.0, 1);
  for I := 0 to High(Output) do
    Check(Output[I] = 0, 'muted monitor emits silence');

  FillChar(Input[0], Length(Input) * SizeOf(SmallInt), 0);
  State.Gain := 0.3;
  RenderVoiceMonitor(State, PMonitorSamples(@Input[0]), PMonitorSamples(@Output[0]),
    Length(Input), 0, 0.0, 0.5, 1);
  Check((not IsNan(State.Gain)) and (not IsInfinite(State.Gain)),
    'silence and zero-rate edge keep monitor gain finite');
  for I := 0 to High(Output) do
    Check(Output[I] = 0, 'silence remains silence through monitor renderer');
end;

begin
  Assertions := 0;
  TestRingWrap;
  TestQueueOverflowAndUnderrun;
  TestMonitorGainAndCaps;
  WriteLn('PASS: ', Assertions, ' voice monitor queue/render assertions');
end.
