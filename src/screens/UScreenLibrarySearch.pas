unit UScreenLibrarySearch;
{$mode objfpc}{$H+}
{$I switches.inc}
interface
uses Classes, sdl2, UMenu, UTexture, USongCatalogBridge;
type
  TLibraryRow = record
    LocalIndex, RemoteIndex: integer;
    Caption, Artist, Title: UTF8String;
  end;
  TScreenLibrarySearch = class(TMenu)
  private
    FSession: TCatalogSession;
    FRows: array of TLibraryRow;
    FQuery, FLastQuery, FUser, FPassword: UTF8String;
    FLastInstalled: string;
    FQueryText, FAccountText, FPasswordText, FLoginText, FStatusText, FHintText, FCountText, FPageText: integer;
    FRowTexts, FArtistTexts, FBadgeTexts: array[0..11] of integer;
    FCovers: array[0..11] of TTexture;
    FCoverKeys: array[0..11] of UTF8String;
    FDefaultCover: TTexture;
    FSectionText: integer;
    procedure DrawGrid;
    procedure ReleaseCovers;
  private
    FFocus, FTop, FSelected, FRemoteCount, FSource: integer;
    FDetailsID: Int64;
    FSearchDue: QWord;
    FSignIn, FRescan, FLoginQueued, FAutoLoginAttempted: boolean;
    procedure Changed;
    procedure BuildRows;
    procedure UpdateView;
    procedure Activate;
    procedure Leave;
    procedure StartSession;
    procedure Tick;
    procedure ClearPassword;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Open(const Query: UTF8String);
    procedure OnHide; override;
    function Draw: boolean; override;
    function ParseInput(Key: cardinal; CharCode: UCS4Char; Down: boolean): boolean; override;
    function ParseMouse(MouseButton: integer; Down: boolean; X, Y: integer): boolean; override;
  end;
procedure OpenLibrarySearch(const Query: UTF8String);
procedure FreeLibrarySearch;
implementation
uses SysUtils, Math, IniFiles, UCommon, dglOpenGL, UDrawTexture, UThemes, UGraphic, UPlatform, UCommandLine,
  UUnicodeUtils, USongIdentity, USong, USongs, UScreenSong, UScreenMain,
  USongCatalogInput, USongCatalogLayout, ULibraryGridLayout, UCatalogAutoSignIn;
var LibrarySearch: TScreenLibrarySearch;

procedure OpenLibrarySearch(const Query: UTF8String);
begin
  if not Assigned(LibrarySearch) then LibrarySearch := TScreenLibrarySearch.Create;
  LibrarySearch.Open(Query);
  ScreenSong.FadeTo(@LibrarySearch);
end;

procedure FreeLibrarySearch;
begin
  FreeAndNil(LibrarySearch);
end;

constructor TScreenLibrarySearch.Create;
var I: integer; BG: TThemeBackground;
begin
  inherited Create;
  BG := DEFAULT_BACKGROUND; BG.Color.R := 0.025; BG.Color.G := 0.035; BG.Color.B := 0.07;
  AddBackground(BG);
  AddText(42, 20, 0, 26, 1, 1, 1, 'Song search');
  AddText(680, 24, 0, 18, 0.75, 0.85, 1, '[Back]');
  AddText(680, 65, 0, 18, 0.75, 0.85, 1, '[Clear]');
  FPageText := AddText(650, 131, 0, 14, 0.7, 0.8, 0.9, '');
  FQueryText := AddText(42, 62, 0, 22, 1, 1, 1, '');
  FAccountText := AddText(42, 101, 0, 14, 0.7, 0.85, 1, '');
  FPasswordText := AddText(325, 101, 0, 14, 1, 1, 1, '');
  FLoginText := AddText(650, 101, 0, 14, 1, 0.85, 0.5, '');
  FCountText := AddText(42, 129, 0, 15, 0.7, 0.85, 1, '');
  for I := 0 to High(FRowTexts) do
    FRowTexts[I] := AddText(52, 220 + I * 27, 0, 19, 1, 1, 1, '');
  for I := 0 to High(FRowTexts) do begin
    FArtistTexts[I] := AddText(0, 0, 0, 13, 0.75, 0.8, 0.9, '');
    FBadgeTexts[I] := AddText(0, 0, 0, 11, 0.75, 0.85, 1, '');
  end;
  FDefaultCover := UTexture.Texture.LoadTexture('SongCover');
  FSectionText := AddText(42, 345, 0, 13, 0.8, 0.7, 1, 'USDB MATCHES');
  FStatusText := AddText(42, 506, 0, 16, 0.75, 0.85, 1, '');
  FHintText := AddText(42, 540, 0, 14, 0.85, 0.85, 0.9, '');
end;

destructor TScreenLibrarySearch.Destroy;
begin
  ClearPassword;
  ReleaseCovers;
  if FDefaultCover.TexNum <> 0 then UTexture.Texture.UnLoadTexture(FDefaultCover);
  FreeAndNil(FSession);
  inherited Destroy;
end;

procedure TScreenLibrarySearch.ClearPassword;
begin
  if Length(FPassword) > 0 then FillChar(FPassword[1], Length(FPassword), 0);
  FPassword := '';
end;

procedure TScreenLibrarySearch.StartSession;
var Transport: TCatalogProcessTransport; PythonPath, AdapterPath, Credentials: string; Settings: TIniFile;
begin
  if Assigned(FSession) then begin
    if FSession.HelperRunning and not FSession.Closing then Exit;
    FreeAndNil(FSession);
  end;
  PythonPath := ''; AdapterPath := ''; Credentials := '';
  if Assigned(Params) then begin
    PythonPath := Params.CatalogPython; AdapterPath := Params.CatalogAdapter;
    Credentials := Params.CatalogCredentials;
  end;
  Settings := TIniFile.Create(Platform.GetGameUserPath.Append('config.ini').ToNative);
  try
    if PythonPath = '' then PythonPath := Settings.ReadString('Catalog', 'Python', '');
    if AdapterPath = '' then AdapterPath := Settings.ReadString('Catalog', 'Adapter', '');
    if Credentials = '' then Credentials := Settings.ReadString('Catalog', 'Credentials', '');
  finally Settings.Free; end;
  // Explicit configured paths only; never discover or install an interpreter.
  if not CatalogConfigurationReady(PythonPath, AdapterPath) then begin
    Text[FStatusText].Text := 'USDB setup missing: configure Python and the song catalog adapter.';
    Exit;
  end;
  FAutoLoginAttempted := false;
  Transport := TCatalogProcessTransport.Create;
  Transport.EnableDownloads := true;
  FSession := TCatalogSession.Create(Transport, true);
  FSession.AllowDownloads := true;
  FSession.Start(PythonPath, AdapterPath, Credentials);
end;

procedure TScreenLibrarySearch.Open(const Query: UTF8String);
begin
  FQuery := Query; FLastQuery := #1; FSelected := 0; FTop := 0;
  FFocus := 0; FDetailsID := 0; FSignIn := false;
  FRemoteCount := -1; FLoginQueued := false;
  StartSession;
  Changed;
end;

procedure TScreenLibrarySearch.Changed;
begin
  FSearchDue := GetTickCount64 + 500;
  FDetailsID := 0; FSelected := 0; FTop := 0;
  BuildRows;
end;

procedure TScreenLibrarySearch.BuildRows;
var I, N, LocalCount, RemoteCount: integer; Song: TSong;
  Remote: TCatalogSearchResult; Q, Key: UTF8String; Seen: TStringList;
  procedure AddRow(L, R: integer; const Caption: UTF8String);
  begin
    N := Length(FRows); SetLength(FRows, N + 1);
    FRows[N].LocalIndex := L; FRows[N].RemoteIndex := R; FRows[N].Caption := Caption;
    if L >= 0 then begin FRows[N].Artist := CatSongs.Song[L].Artist; FRows[N].Title := CatSongs.Song[L].Title; end
    else if R >= 0 then begin FRows[N].Artist := FSession.ResultItems[R].Artist; FRows[N].Title := FSession.ResultItems[R].Title; end;
  end;
begin
  SetLength(FRows, 0); LocalCount := 0; RemoteCount := 0;
  Q := UTF8LowerCase(Trim(FQuery));
  Seen := TStringList.Create;
  try
    Seen.Sorted := true; Seen.CaseSensitive := true;
    for I := 0 to High(CatSongs.Song) do begin
      Song := CatSongs.Song[I];
      if Song.Main then Continue;
      Key := SongIdentity(Song.Artist, Song.Title);
      if Seen.IndexOf(string(Key)) >= 0 then Continue;
      Seen.Add(string(Key));
      if (Q = '') or (Pos(Q, UTF8LowerCase(Song.Artist + ' ' + Song.Title)) > 0) then begin
        AddRow(I, -1, Song.Artist + ' - ' + Song.Title);
        Inc(LocalCount);
      end;
    end;
    if Assigned(FSession) and (FLastQuery = FQuery) and (Q <> '') then
      for I := 0 to FSession.ResultCount - 1 do begin
        Remote := FSession.ResultItems[I]; Key := SongIdentity(Remote.Artist, Remote.Title);
        if Seen.IndexOf(string(Key)) >= 0 then Continue;
        Seen.Add(string(Key));
        if RemoteCount = 0 then
          while (Length(FRows) mod 4) <> 0 do AddRow(-1, -1, '');
        AddRow(-1, I, Remote.Artist + ' - ' + Remote.Title);
        Inc(RemoteCount);
      end;
  finally Seen.Free; end;
  Text[FCountText].Text := Format('YOUR COLLECTION: %d songs     /     USDB: %d new', [LocalCount, RemoteCount]);
  if FSelected >= Length(FRows) then FSelected := Max(0, Length(FRows) - 1);
  FTop := Min(FTop, Max(0, ((Max(0, Length(FRows) - 1)) div LibraryGridPageSize) * LibraryGridPageSize));
end;

procedure TScreenLibrarySearch.Tick;
begin
  if not Assigned(FSession) then Exit;
  FSession.Poll;
  if (FSession.InstalledFolder <> '') and not FSession.Busy and
     (FSession.InstalledFolder <> FLastInstalled) then begin
    FLastInstalled := FSession.InstalledFolder;
    FRescan := true; Leave; Exit;
  end;
  if FSession.Authenticated and not FSession.Busy and FSignIn then begin
    FSignIn := false; FFocus := 0;
  end;
  if ClaimCatalogAutoSignIn(FAutoLoginAttempted, FSession.Busy,
    FSession.Authenticated, FSession.StoredCredentials <> '',
    FSession.ErrorCode <> '', FSignIn) then FSession.LoginStored;
  if FLoginQueued and not FSession.Busy then begin
    FLoginQueued := false;
    if (FUser = '') and (FPassword = '') and (FSession.StoredCredentials <> '') then
      FSession.LoginStored
    else FSession.Login(FUser, FPassword);
    ClearPassword;
  end;
  if not FSession.Busy and FSession.Authenticated and
     (Trim(FQuery) <> '') and (GetTickCount64 >= FSearchDue) and
     (FLastQuery <> FQuery) then begin
    if FSession.Search('', '', FQuery) then begin
      FLastQuery := FQuery; FRemoteCount := -1; FDetailsID := 0;
      BuildRows;
    end;
  end;
  if FRemoteCount <> FSession.ResultCount then begin
    FRemoteCount := FSession.ResultCount;
    BuildRows;
  end;
end;

procedure TScreenLibrarySearch.UpdateView;
var I, Index: integer; Prefix, Caption: UTF8String;
begin
  Text[FPasswordText].Visible := FSignIn; Text[FLoginText].Visible := FSignIn;
  Text[FQueryText].Text := FormatCatalogInputLine('Search: ', FQuery, 49);
  if FFocus = 0 then Text[FQueryText].ColB := 0.5 else Text[FQueryText].ColB := 1;
  if FSignIn then begin
    if FFocus = 2 then Prefix := '> ' else Prefix := '';
    Text[FAccountText].Text := TruncateCatalogLine(Prefix + 'User: ' + FUser, 26);
    Prefix := ''; if FFocus = 3 then Prefix := '> ';
    Text[FPasswordText].Text := Prefix + 'Password: ' + StringOfChar('*', Min(16, LengthUTF8(FPassword)));
    Prefix := ''; if FFocus = 4 then Prefix := '> ';
    Text[FLoginText].Text := Prefix + '[Sign in]';
  end else if Assigned(FSession) and FSession.Authenticated then
    Text[FAccountText].Text := 'USDB connected  /  Local songs first'
  else if Assigned(FSession) and FSession.Busy and (FSession.StoredCredentials <> '') then
    Text[FAccountText].Text := 'Connecting to USDB...'
  else Text[FAccountText].Text := 'USDB offline  /  F2: account';
  Text[FPageText].Text := Format('Page %d / %d', [FTop div LibraryGridPageSize + 1, Max(1, (Length(FRows) + LibraryGridPageSize - 1) div LibraryGridPageSize)]);
  Text[FSectionText].Visible := false;
  for I := 0 to High(FRowTexts) do begin
    Text[FArtistTexts[I]].Visible := FDetailsID = 0;
    Text[FBadgeTexts[I]].Visible := FDetailsID = 0;
  end;
  if (FDetailsID > 0) and Assigned(FSession) then begin
    Text[FPageText].Text := '';
    Text[FCountText].Text := 'USDB SOURCES - select a source, then Download (D)';
    for I := 0 to High(FRowTexts) do begin
      Text[FRowTexts[I]].Visible := I < 8;
      Caption := '';
      Index := (FSource div 8) * 8 + I;
      if Index < FSession.DetailLinks.Count then begin
        Prefix := '  '; if Index = FSource then Prefix := '> ';
        Caption := Prefix + 'YouTube ' + Copy(UTF8String(FSession.DetailLinks[Index]), Length(FSession.DetailLinks[Index]) - 10, 11) + '   [Download]';
      end else if (I = 0) then Caption := 'Loading source details...';
      if (I = 0) and not FSession.Busy and (FSession.DetailLinks.Count = 0) then
        Caption := 'No downloadable source is available for this chart.';
      Text[FRowTexts[I]].X := 52; Text[FRowTexts[I]].Y := 220 + I * 30;
      Text[FRowTexts[I]].Align := 0; Text[FRowTexts[I]].Size := 19;
      Text[FRowTexts[I]].Text := Caption;
    end;
  end else begin
    for I := 0 to High(FRowTexts) do begin
      Index := FTop + I;
      Text[FRowTexts[I]].Visible := true;
      Text[FRowTexts[I]].X := 129 + (I mod 4) * 184;
      Text[FRowTexts[I]].Y := 218 + (I div 4) * 112;
      Text[FRowTexts[I]].Align := 1; Text[FRowTexts[I]].Size := 15;
      Text[FArtistTexts[I]].X := Text[FRowTexts[I]].X;
      Text[FArtistTexts[I]].Y := Text[FRowTexts[I]].Y + 18;
      Text[FArtistTexts[I]].Align := 1;
      Text[FBadgeTexts[I]].X := 50 + (I mod 4) * 184;
      Text[FBadgeTexts[I]].Y := 160 + (I div 4) * 112;
      Text[FRowTexts[I]].Text := ''; Text[FArtistTexts[I]].Text := ''; Text[FBadgeTexts[I]].Text := '';
      if Index < Length(FRows) then begin
        Text[FRowTexts[I]].Text := TruncateCatalogLine(FRows[Index].Title, 22);
        Text[FArtistTexts[I]].Text := TruncateCatalogLine(FRows[Index].Artist, 25);
        if FRows[Index].LocalIndex >= 0 then Text[FBadgeTexts[I]].Text := 'LOCAL'
        else if FRows[Index].RemoteIndex >= 0 then begin
          Text[FBadgeTexts[I]].Text := 'USDB';
        end;
      end;
    end;
    if Length(FRows) = 0 then begin
      Text[FRowTexts[0]].X := 42; Text[FRowTexts[0]].Y := 240;
      Text[FRowTexts[0]].Align := 0;
      Text[FRowTexts[0]].Text := 'No local matches. Sign in to search USDB.';
    end;
  end;
  if Assigned(FSession) then
    Text[FStatusText].Text := TruncateCatalogLine(FSession.Status, 83);
  if FSignIn then
    Text[FHintText].Text := 'Tab: user / password / sign in   Enter: sign in   F2: close account form'
  else if FDetailsID > 0 then
    Text[FHintText].Text := 'Up/Down: source   D / Enter: download   Esc: results   F2: account'
  else Text[FHintText].Text := 'Type to search   Arrows: select   Enter: open   Tab: search/list   Esc: back';
end;

procedure TScreenLibrarySearch.Activate;
var Row: TLibraryRow; Song: TCatalogSearchResult;
begin
  if FDetailsID > 0 then begin
    if Assigned(FSession) and not FSession.Busy and
       (FSource < FSession.DetailLinks.Count) then
      FSession.DownloadSong(FDetailsID, FSession.DetailLinks[FSource],
        Platform.GetGameUserPath.Append('songs').ToNative);
    Exit;
  end;
  if (FSelected < 0) or (FSelected >= Length(FRows)) then Exit;
  Row := FRows[FSelected];
  if Row.LocalIndex >= 0 then begin
    ScreenSong.SetSubselection();
    ScreenSong.SkipTo(Row.LocalIndex, true);
    FadeTo(@ScreenSong);
  end else if (Row.RemoteIndex >= 0) and Assigned(FSession) and
              not FSession.Busy then begin
    Song := FSession.ResultItems[Row.RemoteIndex];
    if FSession.Details(Song.SongID) then begin FDetailsID := Song.SongID; FSource := 0; end;
  end;
end;

procedure TScreenLibrarySearch.Leave;
begin
  if FRescan then begin
    FRescan := false;
    ScreenMain.ReloadSongs(true);
    FadeTo(@ScreenMain);
  end else FadeTo(@ScreenSong);
end;

procedure TScreenLibrarySearch.OnHide;
begin
  ClearPassword;
  ReleaseCovers;
  FLoginQueued := false;
  // Keep an idle, signed-in helper for this application session. Any active
  // request is cancelled on leave; downloader descendants belong to kill-on-close Jobs.
  if Assigned(FSession) and FSession.Busy then begin
    FSession.Close; FSession.ForceTerminate; FreeAndNil(FSession);
  end;
  inherited;
end;

procedure TScreenLibrarySearch.ReleaseCovers;
var I: integer;
begin
  for I := 0 to High(FCovers) do begin
    if FCovers[I].TexNum <> 0 then UTexture.Texture.UnLoadTexture(FCovers[I]);
    FCoverKeys[I] := '';
  end;
end;

procedure TScreenLibrarySearch.DrawGrid;
var I, Index: integer; X, Y: single; Cover: TTexture; Key: UTF8String; R: TLibraryTileRect;
  procedure Box(L, T, W, H, R, G, B: single);
  begin
    glDisable(GL_TEXTURE_2D); glDisable(GL_DEPTH_TEST);
    glColor4f(R, G, B, 1); glBegin(GL_QUADS);
    glVertex2f(L, T); glVertex2f(L + W, T); glVertex2f(L + W, T + H); glVertex2f(L, T + H);
    glEnd; glEnable(GL_TEXTURE_2D); glColor4f(1, 1, 1, 1);
  end;
begin
  for I := 0 to High(FCovers) do begin
    Index := FTop + I;
    if (Index >= Length(FRows)) or (FRows[Index].Caption = '') then Continue;
    R := LibraryTileRect(I); X := R.X; Y := R.Y;
    if (FFocus = 1) and (Index = FSelected) then Box(X - 2, Y - 2, 178, 108, 0.95, 0.77, 0.35);
    if FRows[Index].LocalIndex >= 0 then Box(X, Y, 174, 104, 0.07, 0.12, 0.2)
    else Box(X, Y, 174, 104, 0.17, 0.08, 0.23);
    Key := '';
    if FRows[Index].LocalIndex >= 0 then
      Key := CatSongs.Song[FRows[Index].LocalIndex].Path.Append(CatSongs.Song[FRows[Index].LocalIndex].Cover).ToUTF8;
    if Key <> FCoverKeys[I] then begin
      if FCovers[I].TexNum <> 0 then UTexture.Texture.UnLoadTexture(FCovers[I]);
      FCoverKeys[I] := Key;
      if Key <> '' then FCovers[I] := UTexture.Texture.LoadTexture(CatSongs.Song[FRows[Index].LocalIndex].Path.Append(CatSongs.Song[FRows[Index].LocalIndex].Cover));
    end;
    if FCovers[I].TexNum <> 0 then Cover := FCovers[I] else Cover := FDefaultCover;
    Cover.X := X + 59; Cover.Y := Y + 5; Cover.W := 56; Cover.H := 56;
    DrawTexture(Cover);
  end;
end;

function TScreenLibrarySearch.Draw: boolean;
begin
  Tick; UpdateView;
  DrawBG;
  if FDetailsID = 0 then DrawGrid;
  DrawFG; Result := true;
end;

function TScreenLibrarySearch.ParseInput(Key: cardinal; CharCode: UCS4Char; Down: boolean): boolean;
var S: UTF8String; Step, Next: integer;
begin
  Result := true; if not Down then Exit;
  if Key = SDLK_F2 then begin
    FSignIn := not FSignIn;
    if FSignIn then FFocus := 2 else begin FFocus := 0; ClearPassword; end;
  end else if Key = SDLK_ESCAPE then begin
    if FDetailsID > 0 then begin FDetailsID := 0; BuildRows; end
    else if FSignIn then begin FSignIn := false; FFocus := 0; ClearPassword; end
    else Leave;
  end else if Key = SDLK_TAB then begin
    if FSignIn then begin Inc(FFocus); if FFocus > 4 then FFocus := 2; end
    else FFocus := 1 - Min(1, FFocus);
  end else if ((Key = SDLK_DOWN) or (Key = SDLK_UP) or (Key = SDLK_LEFT) or (Key = SDLK_RIGHT) or (Key = SDLK_PAGEDOWN) or (Key = SDLK_PAGEUP)) then begin
    if FDetailsID > 0 then begin
      if (Key = SDLK_UP) or (Key = SDLK_LEFT) or (Key = SDLK_PAGEUP) then Step := -1 else Step := 1;
      if (Key = SDLK_PAGEUP) or (Key = SDLK_PAGEDOWN) then Step := Step * 8;
      if Assigned(FSession) then
        FSource := EnsureRange(FSource + Step, 0, Max(0, FSession.DetailLinks.Count - 1));
    end else begin
      case Key of
        SDLK_LEFT: Step := -1; SDLK_RIGHT: Step := 1;
        SDLK_UP: Step := -4; SDLK_DOWN: Step := 4;
        SDLK_PAGEUP: Step := -LibraryGridPageSize; else Step := LibraryGridPageSize;
      end;
      if FFocus <> 1 then Next := 0 else Next := FSelected + Step;
      FFocus := 1;
      FSelected := EnsureRange(Next, 0, Max(0, Length(FRows) - 1));
      while (FSelected < Length(FRows)) and (FRows[FSelected].Caption = '') do begin
        Next := FSelected + IfThen(Step < 0, -1, 1);
        if (Next < 0) or (Next >= Length(FRows)) then Break;
        FSelected := Next;
      end;
      FTop := (FSelected div LibraryGridPageSize) * LibraryGridPageSize;
    end;
  end else if Key = SDLK_RETURN then begin
    if FSignIn then FLoginQueued := true else Activate;
  end else if (Key = SDLK_d) and (FDetailsID > 0) then Activate
  else if Key = SDLK_BACKSPACE then begin
    case FFocus of
      2: DeleteLastCatalogCharacter(FUser);
      3: DeleteLastCatalogCharacter(FPassword);
    else DeleteLastCatalogCharacter(FQuery); FFocus := 0; Changed;
    end;
  end else if (FDetailsID = 0) and IsPrintableCatalogCharacter(CharCode) and
              ((SDL_GetModState and (KMOD_CTRL or KMOD_ALT or KMOD_GUI)) = 0) then begin
    S := UCS4ToUTF8String(CharCode);
    case FFocus of
      2: if Length(FUser) + Length(S) <= 200 then FUser := FUser + S;
      3: if Length(FPassword) + Length(S) <= 1024 then FPassword := FPassword + S;
    else
      if Length(FQuery) + Length(S) <= 200 then begin FQuery := FQuery + S; FFocus := 0; Changed; end;
    end;
  end;
  UpdateView;
end;

function TScreenLibrarySearch.ParseMouse(MouseButton: integer; Down: boolean; X, Y: integer): boolean;
var Index: integer;
begin
  Result := true; if not Down then Exit;
  if MouseButton = SDL_BUTTON_RIGHT then begin ParseInput(SDLK_ESCAPE, 0, true); Exit; end;
  if (X < 35) or (X > 765) then Exit;
  if MouseButton = SDL_BUTTON_WHEELDOWN then begin ParseInput(SDLK_PAGEDOWN, 0, true); Exit; end;
  if MouseButton = SDL_BUTTON_WHEELUP then begin ParseInput(SDLK_PAGEUP, 0, true); Exit; end;
  if MouseButton <> SDL_BUTTON_LEFT then Exit;
  if (X >= 660) and (Y >= 18) and (Y < 48) then Leave
  else if (X >= 660) and (Y >= 58) and (Y < 90) then begin FQuery := ''; FFocus := 0; Changed; end
  else if (Y >= 58) and (Y < 90) then FFocus := 0
  else if (Y >= 96) and (Y < 122) then begin
    if not FSignIn then begin FSignIn := true; FFocus := 2; end
    else if X >= 640 then FLoginQueued := true
    else if X < 315 then FFocus := 2 else FFocus := 3;
  end else if (FDetailsID > 0) and (Y >= 220) and (Y < 460) then begin
    Index := (Y - 220) div 30; FFocus := 1;
    FSource := (FSource div 8) * 8 + Index; Activate;
  end else if FDetailsID = 0 then begin
    Index := LibraryTileAt(X, Y);
    if Index >= 0 then begin
      FFocus := 1; FSelected := FTop + Index; Activate;
    end;
  end;
  UpdateView;
end;
end.
