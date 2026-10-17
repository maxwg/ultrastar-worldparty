{ Offline production-detector benchmark. Raw little-endian mono s16 PCM. }
program PitchBenchmark;
{$mode objfpc}{$H+}
uses Classes, SysUtils, Math, UPitchDisplay;
type
  TSamples = array of SmallInt;
  TTarget = packed record Midi, Onset: Double; end;
var
  PCM: TSamples;
  Window: array[0..4095] of SmallInt;
  Stream, Targets: TFileStream;
  Output: TextFile;
  State: TPitchTracker;
  Pitch, Tracked, Score: TPitchEstimate;
  Target: TTarget;
  Rate, Peak, BestWeight, Weight, Delta, Freq, LegacyMidi, Time: Double;
  PrevOnset: Double;
  PrevHit: array[0..2] of Boolean;
  Hit, LegacyHit: array[0..2] of Boolean;
  Tick: Cardinal;
  Hop, Last, Offset, I, J, L, Lag, Best, Count: Integer;
  LegacyValid, SameNote: Boolean;
begin
  if ParamCount <> 3 then
    raise Exception.Create('Usage: pitch_benchmark input.pcm sampleRate output.csv');
  DefaultFormatSettings.DecimalSeparator := '.';
  Rate := StrToFloat(ParamStr(2));
  Stream := TFileStream.Create(ParamStr(1), fmOpenRead);
  try
    SetLength(PCM, Stream.Size div 2);
    if Length(PCM) > 0 then Stream.ReadBuffer(PCM[0], Length(PCM)*2);
  finally Stream.Free; end;
  Targets := TFileStream.Create(ParamStr(1)+'.targets', fmOpenRead);
  AssignFile(Output, ParamStr(3)); Rewrite(Output);
  WriteLn(Output, 'time,valid,midi,confidence,rms,score_valid,score_midi,legacy_valid,legacy_midi,hit_easy,hit_medium,hit_hard,legacy_hit_easy,legacy_hit_medium,legacy_hit_hard');
  ResetPitchTracker(State);
  PrevOnset := -999;
  FillChar(PrevHit, SizeOf(PrevHit), 0);
  Hop := Round(Rate*0.020);
  Last := Hop;
  while Last <= Length(PCM) do
  begin
    FillChar(Window, SizeOf(Window), 0);
    Offset := Max(0, Last-Length(Window));
    Count := Last-Offset;
    Move(PCM[Offset], Window[Length(Window)-Count], Count*2);
    Time := Last/Rate;
    Tick := Round(Time*1000)+1;
    Pitch := EstimatePitch(Window, Rate);
    Tracked := TrackPitch(State, Pitch, Tick, True);
    Score := ScoringPitch(State, Tracked, Tick);
    { Frozen pre-change scoring detector, including its fixed 10% gate and
      original fixed-size divisor. It is intentionally not corrected here. }
    Peak := 0;
    for I := 0 to 1023 do Peak := Max(Peak, Abs(Window[I])/32768.0);
    LegacyValid := Peak >= 0.10;
    LegacyMidi := 0;
    if LegacyValid then
    begin
      BestWeight := -1; Best := 0;
      for J := 0 to 45 do
      begin
        Freq := 65.4064*Power(1.05946309436, J);
        Lag := Round(Rate/Freq);
        Weight := 0;
        for I := 0 to High(Window)-Lag do
        begin
          Delta := Abs(Window[I]-Window[I+Lag])/65535.0;
          Weight := Weight+Delta;
        end;
        Weight := 1-Weight/Length(Window);
        if Weight > BestWeight then begin BestWeight := Weight; Best := J; end;
      end;
      LegacyMidi := Best+36;
    end;
    Targets.ReadBuffer(Target, SizeOf(Target));
    SameNote := (Target.Midi > -100) and (PrevOnset = Target.Onset);
    for L := 0 to 2 do
    begin
      Hit[L] := (Target.Midi > -100) and Score.Valid and
        PitchMatchesNote(Score.Midi, Target.Midi, L) and
        (Tracked.Valid or (SameNote and PrevHit[L]));
      LegacyHit[L] := (Target.Midi > -100) and LegacyValid and
        (Abs(FoldPitchToTarget(LegacyMidi, Target.Midi)-Target.Midi) <= 2-L);
      PrevHit[L] := Hit[L];
    end;
    PrevOnset := Target.Onset;
    WriteLn(Output, Format('%.6f,%d,%.6f,%.6f,%.6f,%d,%.6f,%d,%.6f,%d,%d,%d,%d,%d,%d',
      [Time, Ord(Tracked.Valid), Tracked.Midi, Pitch.Confidence, Pitch.Volume,
       Ord(Score.Valid), Score.Midi, Ord(LegacyValid), LegacyMidi,
       Ord(Hit[0]), Ord(Hit[1]), Ord(Hit[2]),
       Ord(LegacyHit[0]), Ord(LegacyHit[1]), Ord(LegacyHit[2])]));
    Inc(Last, Hop);
  end;
  CloseFile(Output); Targets.Free;
end.
