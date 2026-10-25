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
    FSessionStartDateTime: TDateTime;
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
    FDropoutBeats: Integer;
    FMaxCaptureAgeMs: Cardinal;
    FTotalCentsErr: Double;
    FCentsCount: Integer;
    FDebugDir: IPath;
    FSessionHistoryDir: IPath;
    FSessionFolderName: string;

    procedure CopyFileIfExists(const SourcePath, DestPath: string; MaxBytes: Int64 = 0);
    function SanitizeFolderSegment(const S: string): string;
    procedure PruneOldHistoryFolders(const HistoryRoot: string; MaxKeep: Integer);
    procedure SaveSessionPackage(const StatusLabel: string;
      ScoreNormal, ScoreGolden, ScoreLine, ScoreTotal: Integer);
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
  FSessionHistoryDir := nil;
end;

destructor TLastSongLog.Destroy;
begin
  FreeAndNil(FLogRows);
  inherited Destroy;
end;

function TLastSongLog.SanitizeFolderSegment(const S: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    Ch := S[I];
    if Ch in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_'] then
      Result := Result + Ch
    else if Ch in [' ', '.'] then
    begin
      if (Length(Result) > 0) and (Result[Length(Result)] <> '_') then
        Result := Result + '_';
    end;
    if Length(Result) >= 48 then
      Break;
  end;
  if Result = '' then
    Result := 'Song';
end;

procedure TLastSongLog.PruneOldHistoryFolders(const HistoryRoot: string; MaxKeep: Integer);
var
  SR: TSearchRec;
  Folders: TStringList;
  FolderPath: string;
  InnerSR: TSearchRec;
begin
  if not DirectoryExists(HistoryRoot) then Exit;
  Folders := TStringList.Create;
  try
    Folders.Sorted := True;
    if FindFirst(IncludeTrailingPathDelimiter(HistoryRoot) + '*', faDirectory, SR) = 0 then
    begin
      try
        repeat
          if ((SR.Attr and faDirectory) <> 0) and (SR.Name <> '.') and (SR.Name <> '..') then
            Folders.Add(SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;

    while Folders.Count > MaxKeep do
    begin
      FolderPath := IncludeTrailingPathDelimiter(HistoryRoot) + Folders[0];
      if FindFirst(IncludeTrailingPathDelimiter(FolderPath) + '*', faAnyFile, InnerSR) = 0 then
      begin
        try
          repeat
            if (InnerSR.Name <> '.') and (InnerSR.Name <> '..') then
              SysUtils.DeleteFile(IncludeTrailingPathDelimiter(FolderPath) + InnerSR.Name);
          until FindNext(InnerSR) <> 0;
        finally
          FindClose(InnerSR);
        end;
      end;
      RemoveDir(FolderPath);
      Folders.Delete(0);
    end;
  finally
    Folders.Free;
  end;
end;

procedure TLastSongLog.CopyFileIfExists(const SourcePath, DestPath: string; MaxBytes: Int64);
var
  InStream, OutStream: TFileStream;
begin
  if not FileExists(SourcePath) then Exit;
  try
    InStream := TFileStream.Create(SourcePath, fmOpenRead or fmShareDenyNone);
    try
      if (MaxBytes > 0) and (InStream.Size > MaxBytes) then
        Exit;
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
var
  ChartPath: string;
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
  FDropoutBeats := 0;
  FMaxCaptureAgeMs := 0;
  FTotalCentsErr := 0.0;
  FCentsCount := 0;
  FStartTime := GetTickCount64;
  FSessionStartDateTime := Now;

  FDebugDir := Platform.GetGameUserPath.Append('LastSongDebug');
  FSessionFolderName := FormatDateTime('yyyymmdd_hhnnss', FSessionStartDateTime) + '_' +
    SanitizeFolderSegment(string(FCurrentSongArtist) + '_' + string(FCurrentSongTitle));
  FSessionHistoryDir := FDebugDir.Append('History').Append(FSessionFolderName);

  try
    ForceDirectories(FDebugDir.ToNative);
    ForceDirectories(FSessionHistoryDir.ToNative);
  except
    on E: Exception do
      Log.LogWarn('Unable to create debug directory ' + FDebugDir.ToNative + ': ' + E.Message, 'LastSongLog');
  end;

  // Snapshot chart immediately on session start so even an interrupted session has its exact chart
  ChartPath := FCurrentSongFullPath;
  if (ChartPath = '') and (FCurrentSong <> nil) and (FCurrentSong.Path <> nil) then
    ChartPath := FCurrentSong.Path.Append('song.txt').ToNative;
  if FileExists(ChartPath) then
  begin
    CopyFileIfExists(ChartPath, FDebugDir.Append('song_chart.txt').ToNative);
    CopyFileIfExists(ChartPath, FSessionHistoryDir.Append('song_chart.txt').ToNative);
  end;

  FLogRows.Add('TimeSec,Beat,TargetMidi,TargetName,TargetType,SungHz,SungMidi,ScoreMidi,CentsOffset,Confidence,Voiced,Hit,BackfillBeats,Volume,CaptureAgeMs');
  FSessionActive := True;
  Log.LogStatus('Started debug session for song: ' + FCurrentSongArtist + ' - ' + FCurrentSongTitle +
    ' [' + FSessionFolderName + ']', 'LastSongLog');
end;

procedure TLastSongLog.LogBeat(TimeSec: Real; Beat: Integer; NoteFragment: Pointer;
  const Sound: TCaptureBuffer; Hit: Boolean; BackfillCount: Integer);
var
  Fragment: PLineFragment;
  TargetMidi, TargetTone: Integer;
  TargetName, TargetType: string;
  SungHz, SungMidi, ScoreMidi, Confidence, CentsOffset, Vol: Double;
  Voiced: Boolean;
  CaptureAgeMs: Cardinal;
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
  CaptureAgeMs := 0;

  if Sound <> nil then
  begin
    CaptureAgeMs := Sound.CaptureAge;
    if CaptureAgeMs > FMaxCaptureAgeMs then
      FMaxCaptureAgeMs := CaptureAgeMs;
    if CaptureAgeMs > 250 then
      Inc(FDropoutBeats);

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

  Row := Format('%.3f,%d,%d,%s,%s,%.1f,%.2f,%.2f,%.1f,%.2f,%s,%s,%d,%.4f,%u',
    [TimeSec, Beat, TargetMidi, TargetName, TargetType,
     SungHz, SungMidi, ScoreMidi, CentsOffset, Confidence,
     BoolToStr(Voiced, True), BoolToStr(Hit, True), BackfillCount, Vol, CaptureAgeMs]);

  FLogRows.Add(Row);
end;

procedure TLastSongLog.SaveSessionPackage(const StatusLabel: string;
  ScoreNormal, ScoreGolden, ScoreLine, ScoreTotal: Integer);
var
  Summary, IndexLines: TStringList;
  AvgCents, HitPct: Double;
  AudioExt, DestAudio, ChartPath, IndexPath, IndexRow: string;
  CapBuf: TCaptureBuffer;
  MicBytes: Int64;
begin
  if FDebugDir = nil then
    FDebugDir := Platform.GetGameUserPath.Append('LastSongDebug');
  if FSessionHistoryDir = nil then
    FSessionHistoryDir := FDebugDir.Append('History').Append(
      FormatDateTime('yyyymmdd_hhnnss', Now) + '_Song');

  try
    ForceDirectories(FDebugDir.ToNative);
    ForceDirectories(FSessionHistoryDir.ToNative);
  except
  end;

  // 1. Save pitch trace CSV to both Latest and History
  try
    FLogRows.SaveToFile(FDebugDir.Append('pitch_trace.csv').ToNative);
    FLogRows.SaveToFile(FSessionHistoryDir.Append('pitch_trace.csv').ToNative);
  except
    on E: Exception do
      Log.LogWarn('Failed to save pitch_trace.csv: ' + E.Message, 'LastSongLog');
  end;

  // 2. Check recorded microphone audio WAV and save to both Latest and History
  MicBytes := 0;
  if Length(AudioInputProcessor.Sound) > 0 then
  begin
    CapBuf := AudioInputProcessor.Sound[0];
    if (CapBuf <> nil) and (CapBuf.LogBuffer <> nil) then
    begin
      CapBuf.LockAnalysisBuffer();
      try
        MicBytes := CapBuf.LogBuffer.Size;
        if MicBytes > 0 then
        begin
          Log.SaveWavFile(CapBuf.LogBuffer, CapBuf.AudioFormat, FDebugDir.Append('recorded_mic.wav'));
          Log.SaveWavFile(CapBuf.LogBuffer, CapBuf.AudioFormat, FSessionHistoryDir.Append('recorded_mic.wav'));
        end;
      finally
        CapBuf.UnlockAnalysisBuffer();
      end;
    end;
  end;

  // 3. Save session summary to both Latest and History
  Summary := TStringList.Create;
  try
    AvgCents := 0;
    if FCentsCount > 0 then
      AvgCents := FTotalCentsErr / FCentsCount;

    HitPct := 0;
    if FTotalVoicedBeats > 0 then
      HitPct := (FTotalHitBeats * 100.0) / FTotalVoicedBeats;

    Summary.Add('=== UltraStar WorldParty - Song Debug Summary ===');
    Summary.Add('Status:          ' + StatusLabel);
    Summary.Add('Date/Time:       ' + DateTimeToStr(Now));
    Summary.Add('Session Folder:  ' + FSessionFolderName);
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
    Summary.Add('--- Microphone Capture Health ---');
    Summary.Add(Format('Recorded Mic PCM Bytes:     %d', [MicBytes]));
    Summary.Add(Format('Max Mic Capture Gap:        %u ms', [FMaxCaptureAgeMs]));
    Summary.Add(Format('Mic Dropout Beats (>250ms): %d', [FDropoutBeats]));
    Summary.Add('');
    Summary.Add('--- Final Scores ---');
    Summary.Add(Format('Score Normal:     %d', [ScoreNormal]));
    Summary.Add(Format('Score Golden:     %d', [ScoreGolden]));
    Summary.Add(Format('Score Line Bonus: %d', [ScoreLine]));
    Summary.Add(Format('Total Score:      %d / 10000', [ScoreTotal]));
    Summary.Add('');
    Summary.Add('--- Debug Files in this Directory ---');
    Summary.Add('- session_info.txt: This summary');
    Summary.Add('- pitch_trace.csv:  Per-beat millisecond pitch, confidence, target note, hit, and mic age log');
    Summary.Add('- song_chart.txt:   Original song chart with note timings and lyrics');
    Summary.Add('- recorded_mic.wav: Raw microphone audio captured during singing (Player 1)');
    Summary.Add('- song_audio.*:     Copy of the song track (if under 60MB)');

    Summary.SaveToFile(FDebugDir.Append('session_info.txt').ToNative);
    Summary.SaveToFile(FSessionHistoryDir.Append('session_info.txt').ToNative);
  finally
    Summary.Free;
  end;

  // 4. Copy original song chart
  ChartPath := FCurrentSongFullPath;
  if (ChartPath = '') and (FCurrentSong <> nil) and (FCurrentSong.Path <> nil) then
    ChartPath := FCurrentSong.Path.Append('song.txt').ToNative;

  if FileExists(ChartPath) then
  begin
    CopyFileIfExists(ChartPath, FDebugDir.Append('song_chart.txt').ToNative);
    CopyFileIfExists(ChartPath, FSessionHistoryDir.Append('song_chart.txt').ToNative);
  end;

  // 5. Copy song audio file to Latest (if under 60 MB)
  if FileExists(FCurrentSongMp3) then
  begin
    AudioExt := ExtractFileExt(FCurrentSongMp3);
    DestAudio := FDebugDir.Append('song_audio' + AudioExt).ToNative;
    CopyFileIfExists(FCurrentSongMp3, DestAudio, 60 * 1024 * 1024);
  end;

  // 6. Append row to sessions_index.csv and prune old history folders beyond 25
  try
    IndexPath := FDebugDir.Append('sessions_index.csv').ToNative;
    IndexLines := TStringList.Create;
    try
      if FileExists(IndexPath) then
        IndexLines.LoadFromFile(IndexPath)
      else
        IndexLines.Add('Timestamp,Status,Artist,Title,TotalBeats,VoicedBeats,HitBeats,AvgCentsError,MaxMicGapMs,MicDropoutBeats,MicBytes,ScoreTotal,HistoryFolder');

      IndexRow := Format('%s,%s,"%s","%s",%d,%d,%d,%.1f,%u,%d,%d,%d,%s',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
         StatusLabel,
         StringReplace(string(FCurrentSongArtist), '"', '""', [rfReplaceAll]),
         StringReplace(string(FCurrentSongTitle), '"', '""', [rfReplaceAll]),
         FTotalBeats, FTotalVoicedBeats, FTotalHitBeats, AvgCents,
         FMaxCaptureAgeMs, FDropoutBeats, MicBytes, ScoreTotal, FSessionFolderName]);
      IndexLines.Add(IndexRow);
      IndexLines.SaveToFile(IndexPath);
    finally
      IndexLines.Free;
    end;
    PruneOldHistoryFolders(FDebugDir.Append('History').ToNative, 25);
  except
    on E: Exception do
      Log.LogWarn('Failed to update sessions_index.csv: ' + E.Message, 'LastSongLog');
  end;

  Log.LogStatus('Song debug package (' + StatusLabel + ') saved to: ' +
    FSessionHistoryDir.ToNative, 'LastSongLog');
end;

procedure TLastSongLog.FinishSession(ScoreNormal, ScoreGolden, ScoreLine, ScoreTotal: Integer);
begin
  if not FSessionActive then Exit;
  FSessionActive := False;
  SaveSessionPackage('Completed', ScoreNormal, ScoreGolden, ScoreLine, ScoreTotal);
end;

procedure TLastSongLog.AbortSession;
begin
  if FSessionActive and (FTotalBeats > 0) then
  begin
    FSessionActive := False;
    SaveSessionPackage('ExitedEarly', 0, 0, 0, 0);
  end;
  FSessionActive := False;
  FLogRows.Clear;
end;

initialization
  LastSongLog := TLastSongLog.Create;

finalization
  FreeAndNil(LastSongLog);

end.
