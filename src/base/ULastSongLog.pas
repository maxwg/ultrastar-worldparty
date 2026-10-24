{*
    UltraStar WorldParty - Karaoke Game
    Last Played Song Debug Session Logger
*}

unit ULastSongLog;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

uses
  SysUtils,
  Classes,
  Math,
  UPath,
  UPathUtils,
  UPlatform,
  USong,
  UMusic,
  URecord,
  ULog,
  UPitchDisplay;

type
  TLastSongLog = class
  private
    FSessionActive: Boolean;
    FStartTime: QWord;
    FLogRows: TStringList;
    FCurrentSong: TSong;
    FCurrentSongTitle: UTF8String;
    FCurrentSongArtist: UTF8String;
    FCurrentSongBPM: Real;
    FCurrentSongGAP: Real;
    FCurrentSongFullPath: string;
    FCurrentSongMp3: string;
    FTotalBeats: Integer;
    FTotalVoicedBeats: Integer;
    FTotalHitBeats: Integer;
    FTotalBackfilledBeats: Integer;
    FTotalCentsErr: Double;
    FCentsCount: Integer;
    FDebugDir: IPath;

    procedure CopyFileIfExists(const SourcePath, DestPath: string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure StartSession(const Song: TSong);
    procedure LogBeat(TimeSec: Real; Beat: Integer; NoteFragment: Pointer;
      const Sound: TCaptureBuffer; Hit: Boolean; BackfillCount: Integer);
    procedure FinishSession(ScoreNormal, ScoreGolden, ScoreLine, ScoreTotal: Integer);
    procedure AbortSession;

    property SessionActive: Boolean read FSessionActive;
    property DebugDir: IPath read FDebugDir;
  end;

var
  LastSongLog: TLastSongLog;

implementation

constructor TLastSongLog.Create;
begin
  inherited Create;
  FSessionActive := False;
  FLogRows := TStringList.Create;
  FDebugDir := nil;
end;

destructor TLastSongLog.Destroy;
begin
  FreeAndNil(FLogRows);
  inherited Destroy;
end;

procedure TLastSongLog.CopyFileIfExists(const SourcePath, DestPath: string);
var
  InStream, OutStream: TFileStream;
begin
  if not FileExists(SourcePath) then Exit;
  try
    InStream := TFileStream.Create(SourcePath, fmOpenRead or fmShareDenyNone);
    try
      OutStream := TFileStream.Create(DestPath, fmCreate);
      try
        OutStream.CopyFrom(InStream, InStream.Size);
      finally
        OutStream.Free;
      end;
    finally
      InStream.Free;
    end;
  except
    on E: Exception do
      Log.LogWarn('Failed to copy file ' + SourcePath + ' to ' + DestPath + ': ' + E.Message, 'LastSongLog');
  end;
end;

procedure TLastSongLog.StartSession(const Song: TSong);
begin
  FLogRows.Clear;
  FSessionActive := False;
  if Song = nil then Exit;

  FCurrentSong := Song;
  FCurrentSongTitle := Song.Title;
  FCurrentSongArtist := Song.Artist;
  FCurrentSongBPM := Song.BPM;
  FCurrentSongGAP := Song.GAP;
  FCurrentSongFullPath := string(Song.FullPath);
  if Song.Path <> nil then
    FCurrentSongMp3 := Song.Path.Append(Song.Mp3).ToNative
  else
    FCurrentSongMp3 := '';

  FTotalBeats := 0;
  FTotalVoicedBeats := 0;
  FTotalHitBeats := 0;
  FTotalBackfilledBeats := 0;
  FTotalCentsErr := 0.0;
  FCentsCount := 0;
  FStartTime := GetTickCount64;

  FDebugDir := Platform.GetGameUserPath.Append('LastSongDebug');
  try
    ForceDirectories(FDebugDir.ToNative);
  except
    on E: Exception do
      Log.LogWarn('Unable to create debug directory ' + FDebugDir.ToNative + ': ' + E.Message, 'LastSongLog');
  end;

  FLogRows.Add('TimeSec,Beat,TargetMidi,TargetName,TargetType,SungHz,SungMidi,ScoreMidi,CentsOffset,Confidence,Voiced,Hit,BackfillBeats,Volume');
  FSessionActive := True;
  Log.LogStatus('Started debug session for song: ' + FCurrentSongArtist + ' - ' + FCurrentSongTitle, 'LastSongLog');
end;

procedure TLastSongLog.LogBeat(TimeSec: Real; Beat: Integer; NoteFragment: Pointer;
  const Sound: TCaptureBuffer; Hit: Boolean; BackfillCount: Integer);
var
  Fragment: PLineFragment;
  TargetMidi, TargetTone: Integer;
  TargetName, TargetType: string;
  SungHz, SungMidi, ScoreMidi, Confidence, CentsOffset, Vol: Double;
  Voiced: Boolean;
  Row: string;
begin
  if not FSessionActive or (FLogRows = nil) then Exit;

  Inc(FTotalBeats);
  Fragment := PLineFragment(NoteFragment);
  if (Fragment <> nil) then
  begin
    TargetTone := Fragment^.Tone;
    TargetMidi := TargetTone + 60;
    TargetName := PitchName(TargetMidi);
    case Fragment^.NoteType of
      ntNormal:    TargetType := 'Normal';
      ntGolden:    TargetType := 'Golden';
      ntRap:       TargetType := 'Rap';
      ntRapGolden: TargetType := 'RapGolden';
      ntFreestyle: TargetType := 'Freestyle';
    else
      TargetType := 'Other';
    end;
  end
  else
  begin
    TargetTone := -1;
    TargetMidi := -1;
    TargetName := 'None';
    TargetType := 'None';
  end;

  SungHz := 0; SungMidi := 0; ScoreMidi := 0; Confidence := 0; Voiced := False; Vol := 0;
  CentsOffset := 0;

  if Sound <> nil then
  begin
    Vol := Sound.RawPitch.Volume;
    if Sound.RawPitch.Valid then
    begin
      Inc(FTotalVoicedBeats);
      SungHz := Sound.RawPitch.Hz;
      SungMidi := Sound.RawPitch.Midi;
      Confidence := Sound.RawPitch.Confidence;
      Voiced := Sound.RawPitch.Voiced;
      if TargetMidi > 0 then
      begin
        CentsOffset := (FoldPitchToTarget(SungMidi, TargetMidi) - TargetMidi) * 100.0;
        FTotalCentsErr := FTotalCentsErr + Abs(CentsOffset);
        Inc(FCentsCount);
      end;
    end;
    if Sound.ScorePitch.Valid then
      ScoreMidi := Sound.ScorePitch.Midi;
  end;

  if Hit then
    Inc(FTotalHitBeats);

  if BackfillCount > 0 then
    Inc(FTotalBackfilledBeats, BackfillCount);

  Row := Format('%.3f,%d,%d,%s,%s,%.1f,%.2f,%.2f,%.1f,%.2f,%s,%s,%d,%.4f',
    [TimeSec, Beat, TargetMidi, TargetName, TargetType,
     SungHz, SungMidi, ScoreMidi, CentsOffset, Confidence,
     BoolToStr(Voiced, True), BoolToStr(Hit, True), BackfillCount, Vol]);

  FLogRows.Add(Row);
end;

procedure TLastSongLog.FinishSession(ScoreNormal, ScoreGolden, ScoreLine, ScoreTotal: Integer);
var
  Summary: TStringList;
  AvgCents: Double;
  HitPct: Double;
  AudioExt, DestAudio: string;
  ChartPath: string;
  CapBuf: TCaptureBuffer;
begin
  if not FSessionActive then Exit;
  FSessionActive := False;

  if FDebugDir = nil then
    FDebugDir := Platform.GetGameUserPath.Append('LastSongDebug');

  try
    ForceDirectories(FDebugDir.ToNative);
  except
  end;

  // 1. Save pitch trace CSV
  try
    FLogRows.SaveToFile(FDebugDir.Append('pitch_trace.csv').ToNative);
  except
    on E: Exception do
      Log.LogWarn('Failed to save pitch_trace.csv: ' + E.Message, 'LastSongLog');
  end;

  // 2. Save session summary
  Summary := TStringList.Create;
  try
    AvgCents := 0;
    if FCentsCount > 0 then
      AvgCents := FTotalCentsErr / FCentsCount;

    HitPct := 0;
    if FTotalVoicedBeats > 0 then
      HitPct := (FTotalHitBeats * 100.0) / FTotalVoicedBeats;

    Summary.Add('=== UltraStar WorldParty - Last Played Song Debug Summary ===');
    Summary.Add('Date/Time:       ' + DateTimeToStr(Now));
    Summary.Add('Artist:          ' + string(FCurrentSongArtist));
    Summary.Add('Title:           ' + string(FCurrentSongTitle));
    Summary.Add(Format('BPM:             %.2f', [FCurrentSongBPM]));
    Summary.Add(Format('GAP:             %.1f ms', [FCurrentSongGAP]));
    Summary.Add('Chart File:      ' + FCurrentSongFullPath);
    Summary.Add('Audio File:      ' + FCurrentSongMp3);
    Summary.Add('');
    Summary.Add('--- Performance & Pitch Analysis ---');
    Summary.Add(Format('Total Song Beats Evaluated: %d', [FTotalBeats]));
    Summary.Add(Format('Voiced Beats (Singing):     %d', [FTotalVoicedBeats]));
    Summary.Add(Format('Hit Beats:                  %d (%.1f%% of voiced)', [FTotalHitBeats, HitPct]));
    Summary.Add(Format('Backfilled Onset Beats:     %d', [FTotalBackfilledBeats]));
    Summary.Add(Format('Average Pitch Accuracy:     +/- %.1f cents', [AvgCents]));
    Summary.Add('');
    Summary.Add('--- Final Scores ---');
    Summary.Add(Format('Score Normal:     %d', [ScoreNormal]));
    Summary.Add(Format('Score Golden:     %d', [ScoreGolden]));
    Summary.Add(Format('Score Line Bonus: %d', [ScoreLine]));
    Summary.Add(Format('Total Score:      %d / 10000', [ScoreTotal]));
    Summary.Add('');
    Summary.Add('--- Debug Files in this Directory ---');
    Summary.Add('- session_info.txt: This summary');
    Summary.Add('- pitch_trace.csv:  Per-beat millisecond pitch, confidence, target note, and hit log');
    Summary.Add('- song_chart.txt:   Original song chart with note timings and lyrics');
    Summary.Add('- recorded_mic.wav: Raw microphone audio captured during singing (Player 1)');
    Summary.Add('- song_audio.*:     Copy of the song track (if under 60MB)');

    Summary.SaveToFile(FDebugDir.Append('session_info.txt').ToNative);
  finally
    Summary.Free;
  end;

  // 3. Copy original song chart
  ChartPath := FCurrentSongFullPath;
  if (ChartPath = '') and (FCurrentSong <> nil) and (FCurrentSong.Path <> nil) then
    ChartPath := FCurrentSong.Path.Append('song.txt').ToNative;

  if FileExists(ChartPath) then
    CopyFileIfExists(ChartPath, FDebugDir.Append('song_chart.txt').ToNative);

  // 4. Copy song audio file (if under 60 MB)
  if FileExists(FCurrentSongMp3) then
  begin
    AudioExt := ExtractFileExt(FCurrentSongMp3);
    DestAudio := FDebugDir.Append('song_audio' + AudioExt).ToNative;
    CopyFileIfExists(FCurrentSongMp3, DestAudio);
  end;

  // 5. Save recorded microphone audio WAV
  if Length(AudioInputProcessor.Sound) > 0 then
  begin
    CapBuf := AudioInputProcessor.Sound[0];
    if (CapBuf <> nil) and (CapBuf.LogBuffer <> nil) then
    begin
      CapBuf.LockAnalysisBuffer();
      try
        if CapBuf.LogBuffer.Size > 0 then
          Log.SaveWavFile(CapBuf.LogBuffer, CapBuf.AudioFormat, FDebugDir.Append('recorded_mic.wav'));
      finally
        CapBuf.UnlockAnalysisBuffer();
      end;
    end;
  end;

  Log.LogStatus('Last played song debug package saved to: ' + FDebugDir.ToNative, 'LastSongLog');
end;

procedure TLastSongLog.AbortSession;
begin
  FSessionActive := False;
  FLogRows.Clear;
end;

initialization
  LastSongLog := TLastSongLog.Create;

finalization
  FreeAndNil(LastSongLog);

end.
