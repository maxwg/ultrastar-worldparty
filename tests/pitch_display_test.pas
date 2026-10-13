program PitchDisplayTest;
{$mode objfpc}{$H+}
uses Math, SysUtils, UPitchDisplay;
var Samples: array[0..4095] of SmallInt; I,J,K,Count: Integer; Rate,Hz:Double; P:TPitchEstimate; LongSamples:array[0..8191]of SmallInt;
const BoundaryHz:array[0..4]of Double=(50.5,55.0,60.0,1174.659,1450.0);
procedure Check(Ok:Boolean; const Why:string);
begin Inc(Count); if not Ok then begin WriteLn('FAIL: ',Why); Halt(1); end; end;
begin
  Count:=0;
  Check(PitchName(60)='C4','middle C');
  Check(PitchName(69)='A4','concert A');
  Check(PitchName(68)='G#4','sharp');
  Check(PitchName(-1)='B-2','negative pitch');
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
  WriteLn(Count,' assertions passed');
end.
