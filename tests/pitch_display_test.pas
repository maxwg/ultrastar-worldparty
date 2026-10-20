program PitchDisplayTest;
{$mode objfpc}{$H+}
uses Math, SysUtils, UPitchDisplay;
var Samples: array[0..4095] of SmallInt; I,J,K,Count: Integer; Rate,Hz:Double; P:TPitchEstimate; LongSamples:array[0..8191]of SmallInt;
    Tracker: TPitchTracker; Hop, Frame, FirstOnset: Integer; Phase: Double;
const BoundaryHz:array[0..4]of Double=(50.5,55.0,60.0,1174.659,1450.0);
procedure Check(Ok:Boolean; const Why:string);
begin Inc(Count); if not Ok then begin WriteLn('FAIL: ',Why); Halt(1); end; end;
begin
  Count:=0;
  Check(PitchName(60)='C4','middle C');
  Check(PitchName(69)='A4','concert A');
  Check(PitchName(68)='G#4','sharp');
  Check(PitchName(-1)='B-2','negative pitch');
  Check(GradeDisplayPitch(69,69,2)=pfAccurate,'exact note is accurate');
  Check(GradeDisplayPitch(81.4,69,2)=pfAccurate,'octave fold retains accurate color');
  Check(GradeDisplayPitch(69.8,69,2)=pfOff,'hard wrong pitch is off');
  Check(GradeDisplayPitch(69.8,69,1)=pfClose,'medium tolerated pitch is close');
  Check(GradeDisplayPitch(71.1,69,0)=pfClose,'easy tolerated pitch is close');
  Check(GradeDisplayPitch(71.6,69,0)=pfOff,'out of easy tolerance is off');
  Check(DisplayPitchErrorCents(69,69)=0,'target note is zero cents');
  Check(DisplayPitchErrorCents(81,69)=0,'octave-equivalent note is zero cents');
  Check(DisplayPitchErrorCents(70.75,69)=175,'sharp by target-relative cents');
  Check(DisplayPitchErrorCents(67.25,69)=-175,'flat by target-relative cents');
  Check(DisplayPitchErrorCents(68.1,69)=-90,'near-note tuning uses target, not sung note');
  Check(OnsetBackfillBeats(480,8,1,False)=1,'125ms onset can backfill one beat');
  Check(OnsetBackfillBeats(120,8,1,False)=0,'500ms beat is not a 180ms grace');
  Check(OnsetBackfillBeats(800,8,2,False)=2,'two short beats may fit 180ms');
  Check(OnsetBackfillBeats(480,8,2,False)=0,'late onset must not be overcredited');
  Check(OnsetBackfillBeats(480,1,1,False)=0,'ended short note is never credited');
  Check(OnsetBackfillBeats(480,8,1,True)=0,'wrong onset is not retroactively forgiven');
  Check(OnsetBackfillBeats(0,8,1,False)=0,'invalid chart BPM never backfills');
  for K:=0 to 1 do begin
    Rate:=44100+K*3900;
    for J:=0 to 4 do begin
      Hz:=82.4069*Power(2,J*0.73);
      for I:=0 to High(Samples) do Samples[I]:=Round(10000*Sin(2*Pi*Hz*I/Rate));
      P:=EstimatePitch(Samples,Rate);
      Check(P.Valid,'sine voiced');
      Check(Abs(1200*Ln(P.Hz/Hz)/Ln(2))<8,'fractional pitch accuracy');
      Check((P.Volume>0.20) and (P.Volume<0.23),'RMS volume');
    end;
  end;
  FillChar(Samples,SizeOf(Samples),0); P:=EstimatePitch(Samples,44100); Check(not P.Valid,'silence');
  for I:=0 to High(Samples) do Samples[I]:=12000;
  P:=EstimatePitch(Samples,44100); Check(not P.Valid,'DC rejected');
  RandSeed:=47;
  for I:=0 to High(Samples) do Samples[I]:=Random(20000)-10000;
  P:=EstimatePitch(Samples,44100); Check(not P.Valid,'unvoiced noise rejected');
  P:=EstimatePitch(Samples,0); Check(not P.Valid,'invalid rate');
  P:=EstimatePitch(Samples,NaN); Check(not P.Valid,'NaN rate');
  P:=EstimatePitch(Samples,Infinity); Check(not P.Valid,'infinite rate');
  for K:=0 to 1 do begin
    Rate:=44100+K*3900;
    for J:=0 to High(BoundaryHz) do begin
      Hz:=BoundaryHz[J];
      for I:=0 to High(Samples) do Samples[I]:=Round(6000*Sin(2*Pi*Hz*I/Rate)+9000*Sin(4*Pi*Hz*I/Rate));
      P:=EstimatePitch(Samples,Rate);
      Check(P.Valid,'harmonic low/high voice valid');
      Check(Abs(1200*Ln(P.Hz/Hz)/Ln(2))<15,'strong second harmonic keeps fundamental');
    end;
  end;
  RandSeed:=17;
  for I:=0 to High(Samples) do Samples[I]:=Round(10000*Sin(2*Pi*220*I/48000))+Random(2000)-1000;
  P:=EstimatePitch(Samples,48000);
  Check(P.Valid and (Abs(P.Hz-220)<1),'noisy voiced tone');
  for I:=0 to High(LongSamples) do LongSamples[I]:=Round(10000*Sin(2*Pi*440*I/48000));
  for I:=4096 to High(LongSamples) do LongSamples[I]:=Round(10000*Sin(2*Pi*220*I/48000));
  P:=EstimatePitch(LongSamples,48000);
  Check(P.Valid and (Abs(P.Hz-220)<1),'long input uses latest bounded window');
  for I:=0 to 3071 do Samples[I]:=Round(12000*Sin(2*Pi*50.5*I/44100));
  for I:=3072 to High(Samples) do Samples[I]:=0;
  P:=EstimatePitch(Samples,44100);
  Check(P.RecentVolume<0.00001,'new silence rejects older window DC offset');
  Check(not P.Valid,'a quiet latest frame cannot keep scoring a previous low note');
  { At 12 kHz the decimation step is 1 and N reaches all 4096 samples.
    Compile with -Cr to catch the prefix-sum N+1 boundary regression. }
  for I := 0 to High(Samples) do
    Samples[I] := Round(12000*Sin(2*Pi*440*I/12000));
  P := EstimatePitch(Samples,12000);
  Check(P.Valid and (Abs(P.Hz-440)<3),'undecimated full-window pitch is bounded');
  { Start from an empty microphone capture buffer and inject one 20 ms chunk
    at a time. This tests detection onset rather than a fully filled sine. }
  Hop := 882;
  FillChar(Samples, SizeOf(Samples), 0);
  ResetPitchTracker(Tracker);
  FirstOnset := -1;
  Phase := 0;
  for Frame := 1 to 10 do begin
    for I := 0 to High(Samples)-Hop do Samples[I] := Samples[I+Hop];
    for I := High(Samples)-Hop+1 to High(Samples) do begin
      Samples[I] := Round(12000*Sin(Phase));
      Phase := Phase + 2*Pi*440/44100;
    end;
    P := EstimatePitch(Samples,44100);
    P := TrackPitch(Tracker,P,Frame*20,True);
    if (FirstOnset < 0) and P.Valid and (Abs(P.Hz-440)<8) then
      FirstOnset := Frame*20;
  end;
  Check((FirstOnset > 0) and (FirstOnset <= 180), 'fresh A4 starts tracking within 180ms');
  WriteLn('A4 synthetic first-pitch onset: ', FirstOnset, 'ms');
  WriteLn(Count,' assertions passed');
end.
