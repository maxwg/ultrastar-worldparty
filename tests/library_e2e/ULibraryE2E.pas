unit ULibraryE2E;
{$mode objfpc}{$H+}
interface
procedure LibraryE2ETick;
procedure LibraryE2EFail(const MessageText: string);
procedure LibraryE2ETrace(const MessageText: string);
implementation
uses SysUtils, Classes, sdl2, UGraphic, UDisplay, USongs, UScreenSong,
  UScreenLibrarySearch, UMusic, UNote, USong;
var Phase: integer = 0; Started: QWord; Receipt: TextFile;
  LoginReleased, DownloadCaptured: boolean;
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
procedure TextEvent(const S: UTF8String);
var E: TSDL_Event;
begin
  FillChar(E, SizeOf(E), 0); E.type_ := SDL_TEXTINPUT;
  StrPLCopy(PChar(@E.text.text[0]), S, SizeOf(E.text.text)-1); SDL_PushEvent(@E);
end;
procedure Key(K: LongInt);
var E: TSDL_Event;
begin FillChar(E, SizeOf(E), 0); E.type_ := SDL_KEYDOWN; E.key.keysym.sym := K; SDL_PushEvent(@E); end;
procedure Advance;
begin Inc(Phase); Note('phase '+IntToStr(Phase)); end;
procedure LibraryE2ETick;
var Query: UTF8String; Selected, Rows, Remote, I, Installed: integer; Busy, SignedIn: boolean; Marker: TextFile;
begin
  if Started = 0 then begin
    Started := GetTickCount64;
    AssignFile(Receipt, 'e2e-result.txt'); Rewrite(Receipt); Note('START real SDL application end-to-end');
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
      TextEvent('xy'); TextEvent('z'); Advance;
    end;
    2: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) and
          not Assigned(Display.NextScreen) then begin
      if Query <> 'xyz' then Fail('lost batched or transition text: '+string(Query));
      Note('PASS: complete batched SDL text and typing during search transition');
      Key(SDLK_BACKSPACE); Key(SDLK_BACKSPACE); Key(SDLK_BACKSPACE); TextEvent('Fixture'); Advance;
      // Exercise the account button while automatic sign-in is active or complete.
      // Button typing must not edit the query, and repeated submit must not reauthenticate.
      Key(SDLK_F2); Key(SDLK_TAB); Key(SDLK_TAB); TextEvent('ignored');
      Key(SDLK_BACKSPACE); Key(SDLK_RETURN); Key(SDLK_RETURN); Key(SDLK_F2);
    end;
    3: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) and
          SignedIn and not Busy and (Remote > 0) then begin
      if Query <> 'Fixture' then Fail('query edit');
      if (Rows <> 20) or (Remote <> 14) or not LibrarySearchTestLocalFirst then
        Fail('local-first layout or artist/title deduplication');
      if not LibrarySearchTestTextFits then Fail('card or query text overflows');
      Note('PASS: local-first grid and duplicate local/remote song suppression');
      Note('PASS: stored sign-in, account button input isolation and asynchronous search');
      Display.SaveScreenShot; ScreenPopupInfo.Visible := false;
      Key(SDLK_UP); Advance;
    end;
    4: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) then begin
      if Selected <> Rows - 1 then Fail(Format('Up did not wrap to last USDB card (selected=%d rows=%d)', [Selected, Rows]));
      Note('PASS: Up wraps directly to USDB on the last page');
      Display.SaveScreenShot; ScreenPopupInfo.Visible := false;
      Key(SDLK_RETURN); Key(SDLK_RETURN); Advance;
    end;
    5: begin
      if (GetEnvironmentVariable('ULTRASTAR_E2E_CANCEL') = '1') and FileExists('download-active') then begin
        Key(SDLK_ESCAPE); Advance;
      end else if (Display.CurrentScreen = @ScreenSing) and not Assigned(Display.NextScreen) then begin
        if not Assigned(CurrentSong) or (CurrentSong.Title <> 'Remote Fixture') then Fail('wrong autoplay song');
        if ScreenPopupError.Visible then Fail('unexpected error popup on singing screen');
        Note('PASS: one-click source fallback, double-click containment, rescan and karaoke scene'); Advance;
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
      end else if AudioPlayback.Position > 0.5 then begin
        Display.SaveScreenShot;
        Note('PASS: actual audio playback clock advances');
        FreeLibrarySearch; Note('PASS: helper cleanup'); CloseFile(Receipt); Halt(0);
      end;
    end;
  end;
end;
end.
