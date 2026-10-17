{ Shared continuous voice analysis and scoring policy; GPL-3.0-or-later. }
unit UPitchDisplay;
{$mode objfpc}{$H+}
interface

type
  TPitchEstimate = record
    Valid, Voiced: Boolean;
    Hz, Midi, Volume, Confidence, RecentVolume: Double;
  end;
  TPitchTracker = record
    Initialized: Boolean;
    LastTick, LastVoicedTick: Cardinal;
    Midi, PendingMidi, NoiseFloor: Double;
    PendingCount: Integer;
  end;
procedure ResetPitchTracker(var State: TPitchTracker);
function TrackPitch(var State: TPitchTracker; const Pitch: TPitchEstimate;
  Tick: Cardinal; Automatic: Boolean): TPitchEstimate;
function ScoringPitch(const State: TPitchTracker; const Pitch: TPitchEstimate;
  Tick: Cardinal): TPitchEstimate;
function FoldPitchToTarget(Midi, TargetMidi: Double): Double;
function PitchMatchesNote(Midi, TargetMidi: Double; Difficulty: Integer): Boolean;
function EstimatePitch(const Samples: array of SmallInt; SampleRate: Double): TPitchEstimate;
function PitchName(Midi: Integer): string;
implementation
uses Math, SysUtils;

const
  MinimumPitchHz = 50.0;
  MaximumPitchHz = 1500.0;
  MaximumAnalysisSamples = 4096;

function PitchName(Midi: Integer): string;
const Names: array[0..11] of string = ('C','C#','D','D#','E','F','F#','G','G#','A','A#','B');
var Pc: Integer;
begin
  Pc := ((Midi mod 12) + 12) mod 12;
  Result := Names[Pc] + IntToStr(Floor(Midi / 12) - 1);
end;

function EstimatePitch(const Samples: array of SmallInt; SampleRate: Double): TPitchEstimate;
var
  Data, Difference: array[0..MaximumAnalysisSamples-1] of Double;
  I, J, N, Step, Offset, MinLag, MaxLag, Lag, Best, Window, Recent: Integer;
  Sum, Delta, Energy, Mean, Rate, Period, Denom: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  if IsNan(SampleRate) or IsInfinite(SampleRate) then Exit;
  if (SampleRate < 8000) or (SampleRate > 192000) or (Length(Samples) < 256) then Exit;
  { Average adjacent samples before decimating, keeping detection cost bounded. }
  Step := Max(1, Round(SampleRate / 15000));
  Offset := Max(0, Length(Samples)-MaximumAnalysisSamples);
  N := (Length(Samples)-Offset) div Step;
  Rate := SampleRate / Step;
  Mean := 0;
  Energy := 0;
  for I := 0 to N-1 do
  begin
    Sum := 0;
    for J := 0 to Step-1 do Sum := Sum + Samples[Offset+I*Step+J] / 32768.0;
    Data[I] := Sum / Step;
    Mean := Mean + Data[I];
  end;
  Mean := Mean / N;
  for I := 0 to N-1 do
  begin
    Data[I] := Data[I] - Mean;
    Energy := Energy + Sqr(Data[I]);
  end;
  Result.Volume := Sqrt(Energy / N);
  Recent := Min(N, Max(1, Round(Rate * 0.020)));
  Energy := 0; Sum := 0;
  for I := N-Recent to N-1 do
  begin
    Energy := Energy + Sqr(Data[I]);
    Sum := Sum + Data[I];
  end;
  { Remove the recent window's own DC offset. The older voiced window's mean
    must not make a newly silent microphone look loud enough to keep scoring. }
  Result.RecentVolume := Sqrt(Max(0, Energy / Recent - Sqr(Sum / Recent)));
  if (Result.Volume < 0.001) or (Result.RecentVolume < 0.001) then Exit;
  { Search one neighbor beyond the range for boundary interpolation. }
  MinLag := Max(2, Floor(Rate / MaximumPitchHz)-1);
  MaxLag := Min(N div 2 - 1, Ceil(Rate / MinimumPitchHz)+1);
  if MaxLag <= MinLag then Exit;
  Window := N - MaxLag;
  Difference[0] := 1;
  Sum := 0;
  { YIN cumulative mean normalized difference, first strong local minimum. }
  for Lag := 1 to MaxLag do
  begin
    Energy := 0;
    for I := 0 to Window-1 do
    begin
      Delta := Data[I] - Data[I+Lag];
      Energy := Energy + Delta*Delta;
    end;
    Sum := Sum + Energy;
    if Sum > 1e-15 then Difference[Lag] := Energy * Lag / Sum
    else Difference[Lag] := 1;
  end;
  Best := 0;
  Lag := MinLag;
  while Lag < MaxLag do
  begin
    if Difference[Lag] < 0.15 then
    begin
      while (Lag < MaxLag) and (Difference[Lag+1] < Difference[Lag]) do Inc(Lag);
      Best := Lag;
      Break;
    end;
    Inc(Lag);
  end;
  if Best = 0 then
  begin
    Best := MinLag + 1;
    for Lag := MinLag+2 to MaxLag-1 do
      if Difference[Lag] < Difference[Best] then Best := Lag;
    if Difference[Best] > 0.22 then Exit;
  end;
  if (Best <= MinLag) or (Best >= MaxLag) then Exit;
  Period := Best;
  Denom := Difference[Best-1] - 2*Difference[Best] + Difference[Best+1];
  if Abs(Denom) > 1e-12 then
    Period := Period + EnsureRange(0.5*(Difference[Best-1]-Difference[Best+1])/Denom, -0.5, 0.5);
  Result.Hz := Rate / Period;
  Result.Midi := 69 + 12 * Ln(Result.Hz/440) / Ln(2);
  Result.Confidence := 1 - Difference[Best];
  Result.Valid := (Result.Hz >= MinimumPitchHz) and (Result.Hz <= MaximumPitchHz);
  Result.Voiced := Result.Valid;
end;
procedure ResetPitchTracker(var State: TPitchTracker);
begin
  FillChar(State, SizeOf(State), 0);
  State.NoiseFloor := 0.0004;
end;

function TrackPitch(var State: TPitchTracker; const Pitch: TPitchEstimate;
  Tick: Cardinal; Automatic: Boolean): TPitchEstimate;
var Gate, Delta, Alpha, NoiseLevel: Double;
begin
  Result := Pitch;
  if State.NoiseFloor = 0 then State.NoiseFloor := 0.0004;
  if Automatic then
  begin
    Gate := Max(0.0012, Min(0.015, State.NoiseFloor * 2.5));
    Result.Valid := Result.Valid and (Pitch.RecentVolume >= Gate);
    { Only unvoiced input trains the floor: sustained quiet singing is not noise. }
    if not Pitch.Valid then
    begin
      NoiseLevel := Min(0.02, Pitch.RecentVolume);
      { Learn a quieter room quickly, but never let one breath/consonant raise
        the gate enough to erase the following quiet vowel. }
      if NoiseLevel < State.NoiseFloor then Alpha := 0.12 else Alpha := 0.002;
      State.NoiseFloor := State.NoiseFloor + Alpha*(NoiseLevel-State.NoiseFloor);
    end;
  end;
  if not Result.Valid then
  begin
    State.PendingCount := 0;
    Exit;
  end;
  if State.Initialized and (Cardinal(Tick-State.LastVoicedTick) <= 100) then
  begin
    Delta := Result.Midi-State.Midi;
    { Reject a single-frame octave/harmonic flip, but follow real leaps in 20ms. }
    if Abs(Delta) >= 6 then
    begin
      if (State.PendingCount > 0) and (Abs(Result.Midi-State.PendingMidi) < 1) then
        Inc(State.PendingCount)
      else State.PendingCount := 1;
      State.PendingMidi := Result.Midi;
      if State.PendingCount < 2 then
      begin
        Result.Valid := False;
        Exit;
      end;
      State.Midi := Result.Midi;
    end
    else
    begin
      { Time-based one-pole filter, fast on note changes, gentle on vibrato. }
      Alpha := 1-Exp(-Max(1, Cardinal(Tick-State.LastTick))/25.0);
      if Abs(Delta) > 0.8 then Alpha := Max(0.8, Alpha);
      State.Midi := State.Midi + Alpha*Delta;
    end;
  end
  else State.Midi := Result.Midi;
  State.PendingCount := 0;
  State.Initialized := True;
  State.LastVoicedTick := Tick;
  State.LastTick := Tick;
  Result.Midi := State.Midi;
  Result.Hz := 440*Power(2, (Result.Midi-69)/12);
end;

function ScoringPitch(const State: TPitchTracker; const Pitch: TPitchEstimate;
  Tick: Cardinal): TPitchEstimate;
begin
  Result := Pitch;
  { Only a short unvoiced gap may be bridged. UNote additionally requires the
    same already-hit chart note; silence at an onset cannot earn points. }
  if not Result.Valid and not Result.Voiced and State.Initialized and
     (Cardinal(Tick-State.LastVoicedTick) <= 60) then
  begin
    Result.Valid := True;
    Result.Midi := State.Midi;
    Result.Hz := 440*Power(2, (Result.Midi-69)/12);
  end;
end;

function FoldPitchToTarget(Midi, TargetMidi: Double): Double;
begin
  Result := Midi - 12*Floor((Midi-TargetMidi+6)/12);
end;

function PitchMatchesNote(Midi, TargetMidi: Double; Difficulty: Integer): Boolean;
begin
  { Matches the traditional rounded pitch classes, including the half-semitone
    quantization margin. Hard remains strict; Easy/Medium keep their ranges. }
  Result := Abs(FoldPitchToTarget(Midi, TargetMidi)-TargetMidi) <=
    (2-EnsureRange(Difficulty, 0, 2)+0.5);
end;
end.
