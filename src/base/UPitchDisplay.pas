{ Continuous pitch display; GPL-3.0-or-later. Independent of scoring. }
unit UPitchDisplay;
{$mode objfpc}{$H+}
interface

type
  TPitchEstimate = record
    Valid: Boolean;
    Hz, Midi, Volume, Confidence: Double;
  end;
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
  Data: array of Double;
  Difference: array of Double;
  I, J, N, Step, Offset, MinLag, MaxLag, Lag, Best, Window: Integer;
  Sum, Delta, Energy, Mean, Rate, Period, Denom: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  if IsNan(SampleRate) or IsInfinite(SampleRate) then Exit;
  if (SampleRate < 8000) or (SampleRate > 192000) or (Length(Samples) < 256) then Exit;
  { Average adjacent samples before decimating, keeping detection cost bounded. }
  Step := Max(1, Floor(SampleRate / 24000));
  Offset := Max(0, Length(Samples)-MaximumAnalysisSamples);
  N := (Length(Samples)-Offset) div Step;
  Rate := SampleRate / Step;
  SetLength(Data, N);
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
  if Result.Volume < 0.003 then Exit;
  { Search one neighbor beyond the range for boundary interpolation. }
  MinLag := Max(2, Floor(Rate / MaximumPitchHz)-1);
  MaxLag := Min(N div 2 - 1, Ceil(Rate / MinimumPitchHz)+1);
  if MaxLag <= MinLag then Exit;
  Window := N - MaxLag;
  SetLength(Difference, MaxLag + 1);
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
  if (Best <= MinLag) or (Best >= MaxLag) then Exit;
  Period := Best;
  Denom := Difference[Best-1] - 2*Difference[Best] + Difference[Best+1];
  if Abs(Denom) > 1e-12 then
    Period := Period + EnsureRange(0.5*(Difference[Best-1]-Difference[Best+1])/Denom, -0.5, 0.5);
  Result.Hz := Rate / Period;
  Result.Midi := 69 + 12 * Ln(Result.Hz/440) / Ln(2);
  Result.Confidence := 1 - Difference[Best];
  Result.Valid := (Result.Hz >= MinimumPitchHz) and (Result.Hz <= MaximumPitchHz);
end;
end.
