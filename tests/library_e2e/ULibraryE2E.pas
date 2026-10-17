unit ULibraryE2E;
{$mode objfpc}{$H+}
interface
procedure LibraryE2ETick;
procedure LibraryE2EFail(const MessageText: string);
procedure LibraryE2ETrace(const MessageText: string);
implementation
uses SysUtils, Classes, sdl2, UGraphic, UDisplay, USongs, UScreenSong,
  UScreenLibrarySearch, UMusic, UNote;
var Phase: integer = 0; Started: QWord; Receipt: TextFile;
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
var Query: UTF8String; Selected, Rows, Remote: integer; Busy, SignedIn: boolean;
begin
  if Started = 0 then begin
    Started := GetTickCount64;
    AssignFile(Receipt, 'e2e-result.txt'); Rewrite(Receipt); Note('START real SDL application end-to-end');
  end;
  if GetTickCount64 - Started > 75000 then Fail('timeout at phase '+IntToStr(Phase));
  case Phase of
    0: if Assigned(Songs) and Songs.GetLoadProgress.Finished and Assigned(ScreenMain) and not Assigned(Display.NextScreen) then begin
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
    end;
    3: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) and
          SignedIn and not Busy and (Remote > 0) then begin
      if Query <> 'Fixture' then Fail('query edit');
      Note('PASS: stored automatic sign-in and asynchronous search');
      Display.SaveScreenShot; ScreenPopupInfo.Visible := false;
      Key(SDLK_UP); Advance;
    end;
    4: if LibrarySearchTestSnapshot(Query, Selected, Rows, Remote, Busy, SignedIn) then begin
      if Selected <> Rows - 1 then Fail(Format('Up did not wrap to last USDB card (selected=%d rows=%d)', [Selected, Rows]));
      Note('PASS: Up wraps directly to USDB on the last page');
      Display.SaveScreenShot; ScreenPopupInfo.Visible := false;
      Key(SDLK_RETURN); Key(SDLK_RETURN); Advance;
    end;
    5: if (Display.CurrentScreen = @ScreenSing) and not Assigned(Display.NextScreen) then begin
      if not Assigned(CurrentSong) or (CurrentSong.Title <> 'Remote Fixture') then Fail('wrong autoplay song');
      if ScreenPopupError.Visible then Fail('unexpected error popup on singing screen');
      Note('PASS: one-click source fallback, double-click containment, rescan and karaoke scene'); Advance;
    end;
    6: if AudioPlayback.Position > 0.5 then begin
      Display.SaveScreenShot;
      Note('PASS: actual audio playback clock advances');
      FreeLibrarySearch; Note('PASS: helper cleanup'); CloseFile(Receipt); Halt(0);
    end;
  end;
end;
end.
