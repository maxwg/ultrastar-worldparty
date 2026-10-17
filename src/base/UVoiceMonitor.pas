{ Bounded live microphone queue and monitor-only gain. GPL-3.0-or-later. }
unit UVoiceMonitor;
{$mode objfpc}{$H+}
interface
uses SysUtils, URingBuffer;
const VoiceMonitorQueueSeconds = 0.040;
type
  TVoiceMonitorQueue = class
  private
    Ring: TRingBuffer;
    FrameSize: Integer;
  public
    constructor Create(Rate: Double; AFrameSize: Integer);
    destructor Destroy; override;
    procedure Write(Buffer: PByteArray; Count: Integer);
    function Read(Buffer: PByteArray; Count: Integer): Integer;
    function Available: Integer;
    function Capacity: Integer;
  end;
  TMonitorSamples = array[0..MaxInt div SizeOf(SmallInt)-1] of SmallInt;
  PMonitorSamples = ^TMonitorSamples;
  TVoiceMonitorState = record Gain: Double; end;
procedure RenderVoiceMonitor(var State: TVoiceMonitorState;
  Input, Output: PMonitorSamples; Count: Integer; Rate, MusicRMS, Volume: Double;
  Microphones: Integer);
implementation
uses Math;
constructor TVoiceMonitorQueue.Create(Rate: Double; AFrameSize: Integer);
begin
  inherited Create;
  FrameSize := Max(1, AFrameSize);
  Ring := TRingBuffer.Create(Max(1, Ceil(Rate*VoiceMonitorQueueSeconds))*FrameSize);
end;
destructor TVoiceMonitorQueue.Destroy;
begin Ring.Free; inherited; end;
procedure TVoiceMonitorQueue.Write(Buffer: PByteArray; Count: Integer);
begin
  if (Buffer <> nil) and (Count > 0) then Ring.Write(Buffer, Count-Count mod FrameSize);
end;
function TVoiceMonitorQueue.Read(Buffer: PByteArray; Count: Integer): Integer;
begin
  Result := 0;
  if (Buffer = nil) or (Count <= 0) then Exit;
  Count := Count-Count mod FrameSize;
  FillChar(Buffer^, Count, 0);
  Ring.Read(Buffer, Count);
  { Temporary underrun is silence, never EOF; the next callback resumes live. }
  Result := Count;
end;
function TVoiceMonitorQueue.Available: Integer;
begin Result := Ring.Available; end;
function TVoiceMonitorQueue.Capacity: Integer;
begin Result := Ring.Size; end;
procedure RenderVoiceMonitor(var State: TVoiceMonitorState;
  Input, Output: PMonitorSamples; Count: Integer; Rate, MusicRMS, Volume: Double;
  Microphones: Integer);
var I, Peak: Integer; Energy, RMS, Target, Ceiling, Release: Double;
begin
  if (Count <= 0) or (Input = nil) or (Output = nil) then Exit;
  Volume := EnsureRange(Volume, 0, 0.5);
  Microphones := Max(1, Microphones);
  Energy := 0; Peak := 0;
  for I := 0 to Count-1 do
  begin Energy := Energy+Sqr(Input^[I]/32768.0); Peak := Max(Peak, Abs(Integer(Input^[I]))); end;
  RMS := Sqrt(Energy/Count);
  { No backing track: a quiet setup monitor. A silent/muted song: silence. }
  if MusicRMS < 0 then Ceiling := 0.025 else Ceiling := EnsureRange(MusicRMS, 0, 1)*0.5;
  Ceiling := Ceiling/Microphones;
  Target := Volume;
  if RMS > 0 then Target := Min(Target, Ceiling/RMS);
  if Peak > 0 then Target := Min(Target, 0.20*32768/(Microphones*Peak));
  { Immediate limiting; gentle release avoids pumping as gain comes back. }
  State.Gain := Min(State.Gain, Target);
  Release := 1-Exp(-1/Max(1, Rate*0.050));
  for I := 0 to Count-1 do
  begin
    State.Gain := State.Gain+Release*(Target-State.Gain);
    Output^[I] := Round(Input^[I]*State.Gain);
  end;
end;
end.
