unit ULibraryE2E;
{$mode objfpc}{$H+}
interface
procedure LibraryE2ETick;
procedure LibraryE2EFail(const MessageText: string);
procedure LibraryE2ETrace(const MessageText: string);
implementation
uses SysUtils, Classes, IniFiles, Math, sdl2, UGraphic, UDisplay, USongs,
  UScreenSong, UScreenOptions, UScreenOptionsSound, UScreenLibrarySearch, UMusic, URecord, UIni,
  UNote, USong, UUnicodeUtils, UPitchDisplay;
type
  TFakeInputDevice = class(TAudioInputDevice)
    function Start: Boolean; override;
    function Stop: Boolean; override;
    function GetVolume: Single; override;
    procedure SetVolume(Volume: Single); override;
  end;

  TFakeAudioInput = class(TAudioInputBase)
    function GetName: String; override;
    function InitializeRecord: Boolean; override;
  end;
var Phase: integer = 0; Started: QWord; Receipt: TextFile;
  LoginReleased, DownloadCaptured: boolean;
  BurstSubmissions, CachedDecodes, IdleViewBuilds: integer;
  ArtTypingChecked: boolean;
  SyntheticBackend: TFakeAudioInput;
  SyntheticDevice: TFakeInputDevice;
  SyntheticPCM: array[0..8191] of SmallInt;
  SyntheticPhase, LastPlaybackPosition: Double;
  FirstNoteStart, FirstNoteEnd, SecondNoteStart, SecondNoteEnd: Double;
  PitchControlMode: string;
  OriginalBackgroundMusicOption: Integer;
  SyntheticNoiseState: Cardinal;
  SyntheticCaptureActive, SawFirstPitch, SawSecondPitch: Boolean;
  SawFirstRawPitch, SawSecondRawPitch, SawAnyRawPitch: Boolean;
  SawFirstVoiceActive, SawSecondVoiceActive: Boolean;
  FirstTraceShot, SecondTraceShot: Boolean;
procedure Note(const S: string);
begin WriteLn(Receipt, S); Flush(Receipt); end;
procedure LibraryE2ETrace(const MessageText: string);
begin if Started <> 0 then Note(MessageText); end;
procedure LibraryE2EFail(const MessageText: string);
begin
  if Started = 0 then begin AssignFile(Receipt, 'e2e-result.txt'); Rewrite(Receipt); end;
  Note('FAIL: exception '+MessageText); CloseFile(Receipt); Halt(1);
end;
procedure Fail(const S: string);
begin Note('FAIL: '+S); FreeLibrarySearch; CloseFile(Receipt); Halt(1); end;

procedure CalculateSingingNoteWindows;
var LineIndex, NoteIndex, Found: Integer; Fragment: TLineFragment;
begin
  if (CurrentSong = nil) or (Length(CurrentSong.Lines) = 0) then
    Fail('autoplay song has no lyric lines');

  Found := 0;
  for LineIndex := 0 to High(CurrentSong.Lines[0].Line) do
    for NoteIndex := 0 to High(CurrentSong.Lines[0].Line[LineIndex].Note) do
    begin
      Fragment := CurrentSong.Lines[0].Line[LineIndex].Note[NoteIndex];
      if not (Fragment.NoteType in [ntNormal, ntGolden, ntRap, ntRapGolden]) then
        Continue;

      if Found = 0 then
      begin
        FirstNoteStart := GetTimeFromBeat(Fragment.Start, CurrentSong);
        FirstNoteEnd := GetTimeFromBeat(Fragment.Start + Fragment.Length, CurrentSong);
      end
      else if Found = 1 then
      begin
        SecondNoteStart := GetTimeFromBeat(Fragment.Start, CurrentSong);
        SecondNoteEnd := GetTimeFromBeat(Fragment.Start + Fragment.Length, CurrentSong);
      end;
      Inc(Found);
      if Found = 2 then Break;
    end;

  if (Found < 2) or (FirstNoteEnd <= FirstNoteStart) or
     (SecondNoteEnd <= SecondNoteStart) then
    Fail('autoplay chart does not contain two pitched notes');
  Note(Format('chart note windows %.3f-%.3f and %.3f-%.3f seconds',
    [FirstNoteStart, FirstNoteEnd, SecondNoteStart, SecondNoteEnd]));
end;
procedure TextEvent(const S: UTF8String);
var E: TSDL_Event;
begin
  FillChar(E, SizeOf(E), 0); E.type_ := SDL_TEXTINPUT;
  StrPLCopy(PChar(@E.text.text[0]), S, SizeOf(E.text.text)-1); SDL_PushEvent(@E);
end;
procedure Key(K: LongInt; Repeated: boolean = false);
var E: TSDL_Event;
begin
  FillChar(E, SizeOf(E), 0); E.type_ := SDL_KEYDOWN;
  E.key.keysym.sym := K; E.key._repeat := Ord(Repeated); SDL_PushEvent(@E);
end;
procedure Typed(const S: UTF8String);
var I: integer;
begin
  for I := 1 to Length(S) do begin
    Key(Ord(S[I])); TextEvent(Copy(S, I, 1));
  end;
end;
procedure ClickCard(X, Y: integer);
var E: TSDL_Event;
begin
  FillChar(E, SizeOf(E), 0); E.type_ := SDL_MOUSEBUTTONDOWN;
  E.button.button := SDL_BUTTON_LEFT; E.button.state := SDL_PRESSED;
  E.button.x := Round(X * (ScreenW / Screens) / RenderW);
  E.button.y := Round(Y * ScreenH / RenderH);
  SDL_PushEvent(@E);
  E.type_ := SDL_MOUSEBUTTONUP; E.button.state := SDL_RELEASED; SDL_PushEvent(@E);
end;
procedure Advance;
begin Inc(Phase); Note('phase '+IntToStr(Phase)); end;

function TFakeInputDevice.Start: Boolean;
begin Result := True; end;

function TFakeInputDevice.Stop: Boolean;
begin Result := True; end;

function TFakeInputDevice.GetVolume: Single;
begin Result := 0; end;

procedure TFakeInputDevice.SetVolume(Volume: Single);
begin end;

function TFakeAudioInput.GetName: String;
begin Result := 'E2E synthetic microphone'; end;

function TFakeAudioInput.InitializeRecord: Boolean;
begin Result := True; end;

procedure StartSyntheticCapture;
var Processor: TAudioInputProcessor; I, C, ConfigIndex, DeviceIndex: Integer;
begin
  CalculateSingingNoteWindows;
  if AudioInput <> nil then AudioInput.CaptureStop;
  Processor := AudioInputProcessor;
  for I := 0 to High(Ini.InputDeviceConfig) do
    for C := 0 to High(Ini.InputDeviceConfig[I].ChannelToPlayerMap) do
      Ini.InputDeviceConfig[I].ChannelToPlayerMap[C] := CHANNEL_OFF;

  ConfigIndex := Length(Ini.InputDeviceConfig);
  SetLength(Ini.InputDeviceConfig, ConfigIndex + 1);
  Ini.InputDeviceConfig[ConfigIndex].Name := 'E2E synthetic microphone';
  Ini.InputDeviceConfig[ConfigIndex].Input := 0;
  Ini.InputDeviceConfig[ConfigIndex].Latency := LATENCY_AUTODETECT;
  SetLength(Ini.InputDeviceConfig[ConfigIndex].ChannelToPlayerMap, 1);
  Ini.InputDeviceConfig[ConfigIndex].ChannelToPlayerMap[0] := 1;

  SyntheticDevice := TFakeInputDevice.Create;
  SyntheticDevice.CfgIndex := ConfigIndex;
  SyntheticDevice.Name := 'E2E synthetic microphone';
  SyntheticDevice.AudioFormat := TAudioFormatInfo.Create(1, 44100, asfS16);
  SetLength(SyntheticDevice.CaptureChannel, 1);
  DeviceIndex := Length(Processor.DeviceList);
  SetLength(Processor.DeviceList, DeviceIndex + 1);
  Processor.DeviceList[DeviceIndex] := SyntheticDevice;

  SyntheticBackend := TFakeAudioInput.Create;
  Ini.DetectedPitch := 1;
  Ini.ThresholdIndex := High(IThreshold);
  SyntheticBackend.CaptureStart;
  LastPlaybackPosition := AudioPlayback.Position;
  SyntheticPhase := 0;
  SyntheticNoiseState := 2463534242;
  SyntheticCaptureActive := True;
  Note('PASS: fake mono microphone linked through production capture start');
end;

procedure FeedSyntheticCapture;
var
  Position, Delta, SampleTime, Frequency: Double;
  SampleCount, I: Integer;
begin
  if not SyntheticCaptureActive then Exit;
  Position := AudioPlayback.Position;
  if Position < LastPlaybackPosition then LastPlaybackPosition := Position;
  Delta := Max(0, Position - LastPlaybackPosition);
  SampleCount := Min(Length(SyntheticPCM), Round(Delta * 44100));
  for I := 0 to SampleCount - 1 do
  begin
    SampleTime := LastPlaybackPosition + I / 44100;
    if PitchControlMode = 'silence' then
      Frequency := 0
    else if (SampleTime >= FirstNoteStart) and (SampleTime < FirstNoteEnd) then Frequency := 440
    else if (SampleTime >= SecondNoteStart) and (SampleTime < SecondNoteEnd) then Frequency := 493.883
    else Frequency := 0;
    if (Frequency > 0) and (PitchControlMode = 'wrong') then
      Frequency := Frequency * 1.2599210498948732; // four semitones above chart pitch
    if Frequency > 0 then
    begin
      if PitchControlMode = 'rap' then
      begin
        SyntheticNoiseState := SyntheticNoiseState * 1664525 + 1013904223;
        SyntheticPCM[I] := SmallInt(Integer(SyntheticNoiseState mod 8001) - 4000);
      end
      else
      begin
        SyntheticPCM[I] := Round(Sin(SyntheticPhase) * 12000);
        SyntheticPhase := SyntheticPhase + 2 * Pi * Frequency / 44100;
        if SyntheticPhase >= 2 * Pi then SyntheticPhase := SyntheticPhase - 2 * Pi;
      end;
    end
    else SyntheticPCM[I] := 0;
  end;
  if SampleCount > 0 then
    AudioInputProcessor.HandleMicrophoneData(PByteArray(@SyntheticPCM[0]),
      SampleCount * SizeOf(SmallInt), SyntheticDevice);
  LastPlaybackPosition := Position;
end;

procedure ObserveSinging;
var Position: Double; Pitch: TPitchEstimate;
begin
  Position := AudioPlayback.Position;
  Pitch := AudioInputProcessor.Sound[0].RawPitch;
  if AudioInputProcessor.Sound[0].VoiceActive then
  begin
    if (Position > FirstNoteStart + 0.15) and (Position < FirstNoteEnd) then
      SawFirstVoiceActive := True;
    if (Position > SecondNoteStart + 0.15) and (Position < SecondNoteEnd) then
      SawSecondVoiceActive := True;
  end;
  if Pitch.Valid then
  begin
    SawAnyRawPitch := True;
    if (Position > FirstNoteStart + 0.15) and (Position < FirstNoteEnd) then
      SawFirstRawPitch := True;
    if (Position > SecondNoteStart + 0.15) and (Position < SecondNoteEnd) then
      SawSecondRawPitch := True;
  end;
  if Pitch.Valid and (Position > FirstNoteStart + 0.15) and (Position < FirstNoteEnd) and
     (Abs(Pitch.Hz - 440) < 15) then SawFirstPitch := True;
  if Pitch.Valid and (Position > SecondNoteStart + 0.15) and (Position < SecondNoteEnd) and
     (Abs(Pitch.Hz - 493.883) < 15) then SawSecondPitch := True;
  if not FirstTraceShot and (Position > FirstNoteStart + (FirstNoteEnd - FirstNoteStart) * 0.7) then
  begin
    Display.SaveScreenShot; ScreenPopupInfo.Visible := False;
    FirstTraceShot := True; Note('PASS: captured trace during first chart note');
  end;
  if not SecondTraceShot and (Position > SecondNoteStart + (SecondNoteEnd - SecondNoteStart) * 0.4) then
  begin
    Display.SaveScreenShot; ScreenPopupInfo.Visible := False;
    SecondTraceShot := True; Note('PASS: captured trace during second chart note');
  end;
end;

procedure LibraryE2ETick;
var Query: UTF8String; Selected, Rows, Remote, I, Installed: integer; Busy, SignedIn: boolean; Marker: TextFile;
    SavedSettings: TMemIniFile;
begin
  if Started = 0 then begin
    Started := GetTickCount64;
    AssignFile(Receipt, 'e2e-result.txt'); Rewrite(Receipt); Note('START real SDL application end-to-end');
    PitchControlMode := GetEnvironmentVariable('ULTRASTAR_E2E_PITCH_CONTROL');
    if PitchControlMode = '' then PitchControlMode := 'normal';
    if (PitchControlMode <> 'normal') and (PitchControlMode <> 'wrong') and
       (PitchControlMode <> 'silence') and (PitchControlMode <> 'rap') then
      Fail('unsupported pitch-control mode: '+PitchControlMode);
    Note('pitch-control mode: '+PitchControlMode);
  end;
  if GetTickCount64 - Started > 75000 then Fail('timeout at phase '+IntToStr(Phase));
  if (Phase = 5) and not DownloadCaptured and LibrarySearchTestDownloading then begin
    Display.SaveScreenShot; ScreenPopupInfo.Visible := false; DownloadCaptured := true;
  end;
  if (Phase = 3) and not LoginReleased then begin
    if not LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) or
       not Busy or SignedIn then Fail('expected login in flight during repeated submit');
    AssignFile(Marker, 'release-login'); Rewrite(Marker); CloseFile(Marker);
    LoginReleased := true;
  end;
  case Phase of
    0: if Assigned(Songs) and Songs.GetLoadProgress.Finished and Assigned(ScreenMain) and not Assigned(Display.NextScreen) then begin
      if GetEnvironmentVariable('ULTRASTAR_E2E_RESTART') = '1' then begin
        Installed := 0;
        for I := 0 to Songs.SongList.Count - 1 do
          if (TSong(Songs.SongList[I]).Title = 'Remote Fixture') and
             (Pos('USDB-', TSong(Songs.SongList[I]).Path.ToNative) > 0) then Inc(Installed);
        if Installed <> 1 then Fail('download not retained in library after restart');
        Note('PASS: installed download remains in the library after a fresh application launch');
        CloseFile(Receipt); Halt(0);
      end;
      ScreenPopupError.Visible := false;
      Note('creating song screen');
      if not Assigned(ScreenSong) then ScreenSong := TScreenSong.Create;
      Note('song screen created');
      Display.CurrentScreen^.FadeTo(@ScreenSong); Advance;
    end;
    1: if (Display.CurrentScreen = @ScreenSong) and not Assigned(Display.NextScreen) then begin
      Key(SDLK_x); TextEvent('xy'); Key(SDLK_z); TextEvent('z'); Advance;
    end;
    2: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) and
          not Assigned(Display.NextScreen) then begin
      if Query <> 'xyz' then Fail('lost batched or transition text: '+string(Query));
      Note('PASS: complete batched SDL text and typing during search transition');
      BurstSubmissions := LibrarySearchTestSubmissions;
      Key(SDLK_BACKSPACE); Key(SDLK_BACKSPACE); Key(SDLK_BACKSPACE);
      SDL_SetModState(KMOD_RALT or KMOD_LCTRL);
      Typed('mississippibookkeeper'); TextEvent(UCS4ToUTF8String($E9));
      Phase := 10;
    end;
    10: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) then begin
      if Query <> 'mississippibookkeeper' + UCS4ToUTF8String($E9) then Fail('dropped/duplicate committed text or AltGr rejection');
      if LibrarySearchTestSubmissions - BurstSubmissions <> 1 then Fail('typing burst did not coalesce into one filter');
      Note('PASS: mixed key/text burst preserves repeated letters and AltGr; one background filter submission');
      SDL_SetModState(KMOD_NONE);
      for I := 1 to LengthUTF8(Query) do Key(SDLK_BACKSPACE);
      TextEvent('Fixture'); Phase := 3;
      // Exercise the account button while automatic sign-in is active or complete.
      // Button typing must not edit the query, and repeated submit must not reauthenticate.
      Key(SDLK_F2); Key(SDLK_F2, true); Key(SDLK_TAB); Key(SDLK_TAB, true); Key(SDLK_TAB); TextEvent('ignored');
      Key(SDLK_BACKSPACE); Key(SDLK_RETURN); Key(SDLK_RETURN); Key(SDLK_F2);
    end;
    3: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) and
          SignedIn and not Busy and (Remote > 0) then begin
      if not ArtTypingChecked and (LibrarySearchTestCoverDecodes > 0) then begin
        Key(SDLK_BACKSPACE); Key(SDLK_BACKSPACE); Typed('re');
        Phase := 13; Exit;
      end;
      if not LibrarySearchTestArtReady then Exit;
      if Query <> 'Fixture' then Fail('query edit: '+string(Query));
      if (Rows <> 20) or (Remote <> 14) or not LibrarySearchTestLocalFirst then
        Fail('local-first layout or artist/title deduplication');
      if not LibrarySearchTestTextFits then Fail('card or query text overflows');
      Note('PASS: local-first grid and duplicate local/remote song suppression');
      Note('PASS: stored sign-in, account button input isolation and asynchronous search');
      Display.SaveScreenShot; ScreenPopupInfo.Visible := false;
      CachedDecodes := LibrarySearchTestCoverDecodes;
      IdleViewBuilds := LibrarySearchTestViewBuilds; Phase := 14;
    end;
    14: begin
      if LibrarySearchTestViewBuilds <> IdleViewBuilds then Fail('idle frame reformatted the grid');
      Note('PASS: idle frames do not rebuild or remeasure grid labels');
      Key(SDLK_UP); Phase := 4;
    end;
    13: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) then begin
      if Query <> 'Fixture' then Fail('typing during slow cover decode lost/duplicated text');
      ArtTypingChecked := true; Phase := 3;
      Note('PASS: typing remains exact while the cover worker simulates slow IO');
    end;
    4: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) then begin
      if Selected <> Rows - 1 then Fail(Format('Up did not wrap to last USDB card (selected=%d rows=%d)', [Selected, Rows]));
      Note('PASS: Up wraps directly to USDB on the last page');
      Display.SaveScreenShot; ScreenPopupInfo.Visible := false;
      Key(SDLK_PAGEUP); Phase := 11;
    end;
    11: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) then begin
      if (Selected <> 4) or not LibrarySearchTestArtReady then Fail('cached page did not restore immediately');
      if LibrarySearchTestCoverDecodes <> CachedDecodes then Fail('cached page decoded art again');
      Note('PASS: returning to a page reuses cached covers with zero new decodes');
      Key(SDLK_UP); Phase := 12;
    end;
    12: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) then begin
      if Selected <> Rows - 1 then Fail('wrap after returning to cached page');
      ClickCard(703, 181); Key(SDLK_RETURN); Key(SDLK_RETURN); Phase := 5;
    end;
    5: begin
      if (GetEnvironmentVariable('ULTRASTAR_E2E_CANCEL') = '1') and FileExists('download-active') then begin
        Key(SDLK_ESCAPE); Advance;
      end else if (Display.CurrentScreen = @ScreenSing) and not Assigned(Display.NextScreen) then begin
        if not Assigned(CurrentSong) or (CurrentSong.Title <> 'Remote Fixture') then Fail('wrong autoplay song');
        if ScreenPopupError.Visible then Fail('unexpected error popup on singing screen');
        Note('PASS: one-click source fallback, double-click containment, rescan and karaoke scene'); Advance;
      StartSyntheticCapture;
      end;
    end;
    6: begin
      if GetEnvironmentVariable('ULTRASTAR_E2E_CANCEL') = '1' then begin
        if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) and
           SignedIn and not Busy and (Remote = 14) then begin
          if LibrarySearchTestDownloading then Fail('download still active after cancellation');
          Note('PASS: Escape cancels the live download and restores searchable results');
          FreeLibrarySearch; CloseFile(Receipt); Halt(0);
        end;
      end else begin
        FeedSyntheticCapture;
        ObserveSinging;
        if AudioPlayback.Position > SecondNoteEnd + 0.15 then begin
          if PitchControlMode = 'normal' then begin
            if not SawFirstPitch then Fail('synthetic A4 was not detected during the first chart note');
            if not SawSecondPitch then Fail('synthetic B4 was not detected during the second chart note');
            if (Player[0].Score + Player[0].ScoreGolden) < 7500 then
              Fail(Format('synthetic singing score too low: %.0f', [Player[0].Score + Player[0].ScoreGolden]));
          end
          else if PitchControlMode = 'wrong' then begin
            if not SawFirstRawPitch or not SawSecondRawPitch then
              Fail('wrong-pitch control signal was not captured during both chart notes');
            if (Player[0].Score + Player[0].ScoreGolden) > 100 then
              Fail(Format('wrong-pitch control scored too much: %.0f', [Player[0].Score + Player[0].ScoreGolden]));
          end
          else if PitchControlMode = 'rap' then begin
            if not SawFirstVoiceActive or not SawSecondVoiceActive then
              Fail('rap control voice activity was not detected during both chart notes');
            if SawAnyRawPitch then Fail('rap control unexpectedly produced valid raw pitch');
            if (Player[0].Score + Player[0].ScoreGolden) < 7500 then
              Fail(Format('rap voice activity scored too little: %.0f', [Player[0].Score + Player[0].ScoreGolden]));
          end
          else begin
            if SawAnyRawPitch then Fail('silent control produced a valid raw pitch');
            if (Player[0].Score + Player[0].ScoreGolden) <> 0 then
              Fail(Format('silent control expected zero score, got %.0f', [Player[0].Score + Player[0].ScoreGolden]));
          end;
          if not FirstTraceShot or not SecondTraceShot then Fail('missing in-song trace screenshots');
          Note(Format('PASS: %s pitch-control capture scored %.0f points across both notes',
            [PitchControlMode, Player[0].Score + Player[0].ScoreGolden]));
          if Assigned(SyntheticBackend) then SyntheticBackend.CaptureStop;
          SyntheticCaptureActive := False;
          if not Assigned(ScreenOptions) then
            ScreenOptions := TScreenOptions.Create;
          if not Assigned(ScreenOptionsSound) then
            ScreenOptionsSound := TScreenOptionsSound.Create;
          Display.CurrentScreen^.FadeTo(@ScreenOptionsSound);
          Phase := 20;
          Note('PASS: opened sound options after singing capture');
        end;
      end;
    end;
    20: if (Display.CurrentScreen = @ScreenOptionsSound) and not Assigned(Display.NextScreen) then begin
      if Ini.VoicePassthrough <> 1 then Fail('fixture did not enable microphone monitoring');
      if Ini.VoiceMonitorVolume <> 2 then Fail('fixture monitor volume did not load as 20%');
      OriginalBackgroundMusicOption := Ini.BackgroundMusicOption;
      Key(SDLK_DOWN); Key(SDLK_RIGHT); Phase := 21;
    end;
    21: if (Display.CurrentScreen = @ScreenOptionsSound) and not Assigned(Display.NextScreen) then begin
      if (Ini.VoiceMonitorVolume <> 3) or (ScreenOptionsSound.Interaction <> 1) then
        Fail('monitor volume selector did not advance from 20% to 30%');
      Note('PASS: sound options monitor-volume selector advances and saves its selected value');
      Key(SDLK_DOWN);
      if OriginalBackgroundMusicOption = Ord(bmoOn) then Key(SDLK_LEFT)
      else Key(SDLK_RIGHT);
      Phase := 22;
    end;
    22: if (Display.CurrentScreen = @ScreenOptionsSound) and not Assigned(Display.NextScreen) then begin
      if (Ini.BackgroundMusicOption = OriginalBackgroundMusicOption) or
         (ScreenOptionsSound.Interaction <> 2) then
        Fail('background music selector did not toggle at its shifted row');
      Note('PASS: background music selector remains bound to its own row');
      Display.SaveScreenShot; ScreenPopupInfo.Visible := False;
      for I := 1 to 6 do Key(SDLK_DOWN);
      Key(SDLK_RETURN); Phase := 23;
    end;
    23: if (Display.CurrentScreen = @ScreenOptions) and not Assigned(Display.NextScreen) then begin
      SavedSettings := TMemIniFile.Create(Ini.Filename.ToNative);
      try
        if SavedSettings.ReadString('Sound', 'VoiceMonitorVolume', '') <> '30%' then
          Fail('sound options exit did not persist VoiceMonitorVolume=30%');
      finally
        SavedSettings.Free;
      end;
      Note('PASS: sound options screenshot and 30% monitor setting persisted on exit');
      FreeLibrarySearch; Note('PASS: helper cleanup'); CloseFile(Receipt); Halt(0);
    end;
  end;
end;
end.
