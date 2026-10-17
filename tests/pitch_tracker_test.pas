program PitchTrackerTest;
{$mode objfpc}{$H+}

uses
  Math, SysUtils, UPitchDisplay;

type
  TSampleBuffer = array of SmallInt;

procedure Check(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

function MidiHz(Midi: Double): Double;
begin
  Result := 440 * Power(2, (Midi - 69) / 12);
end;

function MakePitch(Midi, RecentVolume: Double; Valid: Boolean = True): TPitchEstimate;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Valid := Valid;
  Result.Voiced := Valid;
  Result.Midi := Midi;
  Result.Hz := MidiHz(Midi);
  Result.Volume := RecentVolume;
  Result.RecentVolume := RecentVolume;
  Result.Confidence := 0.98;
end;

procedure FillSine(var Samples: TSampleBuffer; SampleRate, Midi, Amplitude: Double);
var
  I: Integer;
  Phase, Frequency: Double;
begin
  Frequency := MidiHz(Midi);
  for I := 0 to High(Samples) do
  begin
    Phase := 2 * Pi * Frequency * I / SampleRate;
    Samples[I] := EnsureRange(Round(Amplitude * Sin(Phase)), -32768, 32767);
  end;
end;

procedure FillWhiteNoise(var Samples: TSampleBuffer; Amplitude: Integer);
var
  I: Integer;
  Seed: LongWord;
  Value: Integer;
begin
  Seed := $13579BDF;
  for I := 0 to High(Samples) do
  begin
    Seed := Seed * 1664525 + 1013904223;
    Value := Integer((Seed shr 16) and $7FFF) - 16384;
    Samples[I] := EnsureRange(Round(Value * Amplitude / 16384), -32768, 32767);
  end;
end;

procedure TestVibratoSmoothing;
var
  State: TPitchTracker;
  Samples: TSampleBuffer;
  Raw, Tracked: TPitchEstimate;
  I: Integer;
  InputSquares, OutputSquares: Double;
  FractionalSeen: Boolean;
begin
  ResetPitchTracker(State);
  SetLength(Samples, 4096);
  InputSquares := 0;
  OutputSquares := 0;
  FractionalSeen := False;
  for I := 0 to 39 do
  begin
    FillSine(Samples, 48000, 60 + 0.25 * Sin(2 * Pi * I / 10), 6000);
    Raw := EstimatePitch(Samples, 48000);
    Check(Raw.Valid, 'Vibrato frame should have a valid pitch estimate');
    Tracked := TrackPitch(State, Raw, I * 20, False);
    Check(Tracked.Valid, 'Vibrato should remain voiced through smoothing');
    InputSquares := InputSquares + Sqr(Raw.Midi - 60);
    OutputSquares := OutputSquares + Sqr(Tracked.Midi - 60);
    if Abs(Tracked.Midi - Round(Tracked.Midi)) > 0.05 then
      FractionalSeen := True;
  end;
  Check(OutputSquares < InputSquares * 0.8,
    'Vibrato smoothing should reduce jitter');
  Check(FractionalSeen,
    'Pitch smoothing must preserve fractional pitch instead of snapping to semitones');
end;

procedure TestFastLeapsAndOctaveGlitch;
var
  State: TPitchTracker;
  Estimate, Tracked: TPitchEstimate;
begin
  ResetPitchTracker(State);
  Estimate := MakePitch(60, 0.03);
  Tracked := TrackPitch(State, Estimate, 0, False);
  Check(Tracked.Valid, 'Initial voiced pitch should be accepted');

  Estimate := MakePitch(64, 0.03);
  Tracked := TrackPitch(State, Estimate, 20, False);
  Check(Tracked.Valid and (Tracked.Midi >= 63.0),
    'A real four-semitone step should be followed within one frame');

  Estimate := MakePitch(72, 0.03);
  Tracked := TrackPitch(State, Estimate, 40, False);
  Check(not Tracked.Valid,
    'A one-frame octave-sized change should be rejected as a harmonic glitch');

  Estimate := MakePitch(72, 0.03);
  Tracked := TrackPitch(State, Estimate, 60, False);
  Check(Tracked.Valid and (Abs(Tracked.Midi - 72) < 0.01),
    'A repeated octave-sized change should be accepted as a real leap');

  Estimate := MakePitch(84, 0.03);
  Tracked := TrackPitch(State, Estimate, 80, False);
  Check(not Tracked.Valid,
    'An isolated octave glitch after a stable note should be rejected');
  Estimate := MakePitch(72, 0.03);
  Tracked := TrackPitch(State, Estimate, 100, False);
  Check(Tracked.Valid and (Abs(Tracked.Midi - 72) < 0.1),
    'The correct voiced pitch should return immediately after a rejected glitch');
end;

procedure TestScoringGraceAndReset;
var
  State: TPitchTracker;
  Voiced, WrongVoiced, Silence, Scored: TPitchEstimate;
  Samples: TSampleBuffer;
begin
  ResetPitchTracker(State);
  Voiced := MakePitch(60, 0.03);
  TrackPitch(State, Voiced, 1000, False);
  WrongVoiced := MakePitch(66, 0.03);
  WrongVoiced := TrackPitch(State, WrongVoiced, 1020, False);
  Check(not WrongVoiced.Valid and WrongVoiced.Voiced,
    'An isolated voiced tritone-sized candidate can be rejected while retaining its voiced status');
  Scored := ScoringPitch(State, WrongVoiced, 1020);
  Check(not Scored.Valid,
    'A rejected but voiced wrong-pitch frame must not receive silence grace');

  Silence := MakePitch(0, 0, False);

  Scored := ScoringPitch(State, Silence, 1040);
  Check(Scored.Valid and (Abs(Scored.Midi - 60) < 0.01),
    'Tracker may bridge an unvoiced gap through 60 ms');
  Scored := ScoringPitch(State, Silence, 1061);
  Check(not Scored.Valid, 'Scoring grace must expire after 60 ms');

  { Pure tracker scope only: this does not test UNote's same-chart-note guard. }
  ResetPitchTracker(State);
  Scored := ScoringPitch(State, Silence, 2000);
  Check(not Scored.Valid, 'Reset tracker must not return a stale scoring pitch');
  SetLength(Samples, 4096);
  FillChar(Samples[0], Length(Samples) * SizeOf(SmallInt), 0);
  Silence := EstimatePitch(Samples, 48000);
  Check(not Silence.Valid, 'Digital silence must not be classified as voiced');
  Scored := TrackPitch(State, Silence, 2020, True);
  Check(not Scored.Valid, 'Silence must remain unvoiced after tracker reset');
end;

procedure TestAutomaticSensitivity;
var
  State, VoiceState: TPitchTracker;
  Samples: TSampleBuffer;
  Noise, QuietVoice, Tracked: TPitchEstimate;
  I: Integer;
begin
  SetLength(Samples, 4096);
  FillWhiteNoise(Samples, 6000);
  Noise := EstimatePitch(Samples, 48000);
  Check(not Noise.Valid, 'Broadband noise should not be classified as a pitched voice');

  ResetPitchTracker(State);
  for I := 0 to 29 do
  begin
    Noise.Valid := False;
    Noise.RecentVolume := 0.04;
    TrackPitch(State, Noise, I * 20, True);
  end;
  Check((State.NoiseFloor > 0.0004) and (State.NoiseFloor < 0.005),
    'Automatic sensitivity should learn a bounded floor without letting a short breath poison the next vowel');

  Tracked := TrackPitch(State, MakePitch(69, 0.03), 580, True);
  Check(Tracked.Valid, 'A voiced frame can seed scoring after noise-floor learning');
  QuietVoice := MakePitch(66, 0.001);
  Tracked := TrackPitch(State, QuietVoice, 600, True);
  Check(not Tracked.Valid and Tracked.Voiced,
    'Automatic amplitude gating should preserve that a rejected candidate was voiced');
  Check(not ScoringPitch(State, Tracked, 600).Valid,
    'Automatic gating of a voiced wrong pitch must not turn it into scoring grace');

  { RMS is about 0.011, representative of a quiet vowel after a loud breath. }
  FillSine(Samples, 48000, 69, 500);
  QuietVoice := EstimatePitch(Samples, 48000);
  Check(QuietVoice.Valid, 'Quiet voiced signal remains estimable after noise-floor learning');
  Tracked := TrackPitch(State, QuietVoice, 600, True);
  Check(Tracked.Valid,
    'A quiet vowel following a short loud breath should pass automatic gating');
  for I := 31 to 70 do
  begin
    Tracked := TrackPitch(State, QuietVoice, I * 20, True);
    Check(Tracked.Valid,
      'Automatic sensitivity must retain continuous quiet voiced input');
  end;
  Check(State.NoiseFloor < 0.005,
    'Continuous voice must not train the automatic noise floor upward');

  FillSine(Samples, 48000, 69, 100);
  QuietVoice := EstimatePitch(Samples, 48000);
  Check(QuietVoice.Valid, 'Quiet sinusoid should still yield a voiced estimate');
  ResetPitchTracker(VoiceState);
  for I := 0 to 39 do
  begin
    Tracked := TrackPitch(VoiceState, QuietVoice, I * 20, True);
    Check(Tracked.Valid, 'Automatic sensitivity must pass continuous quiet voiced input');
  end;
  Check(VoiceState.NoiseFloor < 0.001,
    'Continuous voiced input must not be absorbed into the noise floor');
end;

procedure TestToleranceAndSilenceControls;
var
  Difficulty, Octaves, Sign: Integer;
  Target, Tolerance, Boundary: Double;
  Samples: TSampleBuffer;
  Silence: TPitchEstimate;
begin
  Target := 60;
  for Difficulty := 0 to 2 do
  begin
    Tolerance := 2 - Difficulty + 0.5;
    for Sign := -1 to 1 do
      if Sign <> 0 then
      begin
        Boundary := Target + Sign * Tolerance;
        Check(PitchMatchesNote(Boundary, Target, Difficulty),
          'Difficulty tolerance boundary should be inclusive');
        Check(not PitchMatchesNote(Boundary + Sign * 0.01, Target, Difficulty),
          'Pitch just outside difficulty tolerance should not match');
      end;

    Check(not PitchMatchesNote(Target + 4, Target, Difficulty),
      'A voiced pitch four semitones wrong should miss at every difficulty');
    for Octaves := -2 to 2 do
      Check(PitchMatchesNote(Target + Octaves * 12 + Tolerance * 0.8,
                             Target, Difficulty),
        'Pitch tolerance should be invariant across octaves');
  end;

  SetLength(Samples, 4096);
  FillChar(Samples[0], Length(Samples) * SizeOf(SmallInt), 0);
  Silence := EstimatePitch(Samples, 48000);
  Check(not Silence.Valid, 'Silence must not produce a pitch match candidate');
end;

begin
  TestVibratoSmoothing;
  TestFastLeapsAndOctaveGlitch;
  TestScoringGraceAndReset;
  TestAutomaticSensitivity;
  TestToleranceAndSilenceControls;
  WriteLn('Pitch tracker tests passed.');
end.
