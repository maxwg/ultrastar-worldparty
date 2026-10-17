unit UScreenLibrarySearch;
{$mode objfpc}{$H+}
{$I switches.inc}
interface
uses Classes, sdl2, UMenu, UTexture, USongCatalogBridge, ULibraryGridLayout;
type
  TLibraryRow = record
    LocalIndex, RemoteIndex: integer;
    Caption, Artist, Title: UTF8String;
  end;
  TScreenLibrarySearch = class(TMenu)
  private
    FSession: TCatalogSession;
    FRows: array of TLibraryRow;
    FQuery, FLastQuery, FUser, FPassword, FDownloadTitle, FDownloadArtist: UTF8String;
    FLastInstalled: string;
    FQueryText, FAccountText, FPasswordText, FLoginText, FStatusText, FHintText, FCountText, FPageText: integer;
    FRowTexts, FArtistTexts, FBadgeTexts: array[0..LibraryGridPageSize-1] of integer;
    FCovers: array[0..LibraryGridPageSize-1] of TTexture;
    FCoverKeys: array[0..LibraryGridPageSize-1] of UTF8String;
    FDefaultCover: TTexture;
    procedure DrawGrid;
    procedure ReleaseCovers;
  private
    FFocus, FTop, FSelected, FRemoteCount, FSource: integer;
    FDetailsID: Int64;
    FSearchDue: QWord;
    FSignIn, FRescan, FLoginQueued, FLoginInFlight, FAutoLoginAttempted, FAutoDownload, FLeaving: boolean;
    procedure Changed;
    procedure BuildRows;
    procedure UpdateView;
    procedure Activate;
    procedure Leave;
    procedure StartSession;
    procedure Tick;
    procedure ClearPassword;
    procedure QueueLogin;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Open(const Query: UTF8String);
    procedure OnHide; override;
    function AcceptsTransitionInput: boolean; override;
    function Draw: boolean; override;
    function ParseInput(Key: cardinal; CharCode: UCS4Char; Down: boolean): boolean; override;
    function ParseMouse(MouseButton: integer; Down: boolean; X, Y: integer): boolean; override;
  end;
procedure OpenLibrarySearch(const Query: UTF8String);
procedure FreeLibrarySearch;
{$IFDEF LIBRARY_E2E}
function LibrarySearchTestSnapshot(out Query: UTF8String; out Selected, Rows, Remote: integer; out Busy, SignedIn: boolean): boolean;
function LibrarySearchTestLocalFirst: boolean;
function LibrarySearchTestDownloading: boolean;
function LibrarySearchTestTextFits: boolean;
{$ENDIF}
implementation
uses SysUtils, Math, IniFiles, UCommon, dglOpenGL, UDrawTexture, UThemes, UGraphic, UPlatform, UCommandLine,
  UUnicodeUtils, USongIdentity, USong, USongs, UScreenSong, UScreenMain,
  USongCatalogInput, USongCatalogLayout, UCatalogAutoSignIn, TextGL;
var LibrarySearch: TScreenLibrarySearch;

{$IFDEF LIBRARY_E2E}
function LibrarySearchTestTextFits: boolean;
var I: integer; R: TLibraryTileRect;
begin
  Result := false; if not Assigned(LibrarySearch) then Exit;
  SetFontStyle(0); SetFontSize(22);
  if glTextWidth(LibrarySearch.Text[LibrarySearch.FQueryText].Text) > 650 then Exit;
  for I := 0 to LibraryGridPageSize - 1 do begin
    R := LibraryTileRect(I); SetFontSize(15);
    if glTextWidth(LibrarySearch.Text[LibrarySearch.FRowTexts[I]].Text) > R.W - 18 then Exit;
    SetFontSize(12);
    if glTextWidth(LibrarySearch.Text[LibrarySearch.FArtistTexts[I]].Text) > R.W - 18 then Exit;
  end;
  Result := true;
end;

function LibrarySearchTestDownloading: boolean;
begin
  Result := Assigned(LibrarySearch) and LibrarySearch.FAutoDownload;
end;

function LibrarySearchTestLocalFirst: boolean;
var I: integer;
begin
  Result := false;
  if not Assigned(LibrarySearch) or (Length(LibrarySearch.FRows) < 7) then Exit;
  for I := 0 to 5 do if LibrarySearch.FRows[I].LocalIndex < 0 then Exit;
  for I := 6 to High(LibrarySearch.FRows) do
    if LibrarySearch.FRows[I].RemoteIndex < 0 then Exit;
  Result := true;
end;

function LibrarySearchTestSnapshot(out Query: UTF8String; out Selected, Rows, Remote: integer; out Busy, SignedIn: boolean): boolean;
var I: integer;
begin
  Result := Assigned(LibrarySearch); if not Result then Exit;
  Query := LibrarySearch.FQuery; Selected := LibrarySearch.FSelected;
  Rows := Length(LibrarySearch.FRows); Remote := 0;
  for I := 0 to Rows - 1 do if LibrarySearch.FRows[I].RemoteIndex >= 0 then Inc(Remote);
  Busy := not Assigned(LibrarySearch.FSession) or LibrarySearch.FSession.Busy;
  SignedIn := Assigned(LibrarySearch.FSession) and LibrarySearch.FSession.Authenticated;
end;
{$ENDIF}

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
  AddText(24, 16, 0, 25, 1, 1, 1, 'Song search');
  AddText(720, 24, 0, 14, 0.75, 0.85, 1, 'Back');
  AddText(720, 64, 0, 14, 0.75, 0.85, 1, 'Clear');
  FPageText := AddText(670, 96, 0, 12, 0.7, 0.8, 0.9, '');
  FQueryText := AddText(38, 60, 0, 22, 1, 1, 1, '');
  FAccountText := AddText(24, 96, 0, 12, 0.7, 0.85, 1, '');
  FPasswordText := AddText(325, 96, 0, 12, 1, 1, 1, '');
  FLoginText := AddText(650, 96, 0, 12, 1, 0.85, 0.5, '');
  FCountText := AddText(24, 96, 0, 12, 0.7, 0.85, 1, '');
  for I := 0 to High(FRowTexts) do
    FRowTexts[I] := AddText(52, 220 + I * 27, 0, 19, 1, 1, 1, '');
  for I := 0 to High(FRowTexts) do begin
    FArtistTexts[I] := AddText(0, 0, 0, 13, 0.75, 0.8, 0.9, '');
    FBadgeTexts[I] := AddText(0, 0, 0, 11, 0.75, 0.85, 1, '');
  end;
  FDefaultCover := UTexture.Texture.LoadTexture('SongCover');
  FStatusText := AddText(24, 534, 0, 14, 0.75, 0.85, 1, '');
  FHintText := AddText(24, 566, 0, 12, 0.85, 0.85, 0.9, '');
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
  FLeaving := false;
  FQuery := Query; FLastQuery := #1; FSelected := 0; FTop := 0;
  FFocus := 0; FDetailsID := 0; FSignIn := false;
  FRemoteCount := -1; FLoginQueued := false; FAutoDownload := false;
  StartSession;
  Changed;
end;

procedure TScreenLibrarySearch.Changed;
begin
  FSearchDue := GetTickCount64 + 200;
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
      if (Trim(Song.Artist) <> '') and (Trim(Song.Title) <> '') then begin
        if Seen.IndexOf(string(Key)) >= 0 then Continue;
        Seen.Add(string(Key));
      end;
      if (Q = '') or (Pos(Q, UTF8LowerCase(Song.Artist + ' ' + Song.Title)) > 0) then begin
        AddRow(I, -1, Song.Artist + ' - ' + Song.Title);
        Inc(LocalCount);
      end;
    end;
    if Assigned(FSession) and (FLastQuery = FQuery) and (Q <> '') then
      for I := 0 to FSession.ResultCount - 1 do begin
        Remote := FSession.ResultItems[I]; Key := SongIdentity(Remote.Artist, Remote.Title);
        if (Trim(Remote.Artist) <> '') and (Trim(Remote.Title) <> '') then begin
          if Seen.IndexOf(string(Key)) >= 0 then Continue;
          Seen.Add(string(Key));
        end;
        AddRow(-1, I, Remote.Artist + ' - ' + Remote.Title);
        Inc(RemoteCount);
      end;
  finally Seen.Free; end;
  Text[FCountText].Text := Format('YOUR SONGS  %d     /     USDB  %d new', [LocalCount, RemoteCount]);
  if FSelected >= Length(FRows) then FSelected := Max(0, Length(FRows) - 1);
  FTop := Min(FTop, Max(0, ((Max(0, Length(FRows) - 1)) div LibraryGridPageSize) * LibraryGridPageSize));
end;

procedure TScreenLibrarySearch.Tick;
begin
  if FLeaving or not Assigned(FSession) then Exit;
  FSession.Poll;
  if not FSession.Busy then FLoginInFlight := false;
  if (FSession.InstalledFolder <> '') and not FSession.Busy and
     (FSession.InstalledFolder <> FLastInstalled) then begin
    FLastInstalled := FSession.InstalledFolder;
    ScreenSong.AutoPlayFolder := FLastInstalled;
    FRescan := true; Leave; Exit;
  end;
  if FSession.Authenticated and not FSession.Busy and FSignIn then begin
    FSignIn := false; FFocus := 0; FLoginQueued := false;
  end;
  if not FLoginQueued and ClaimCatalogAutoSignIn(FAutoLoginAttempted, FSession.Busy,
    FSession.Authenticated, FSession.StoredCredentials <> '',
    FSession.ErrorCode <> '', FSignIn) then FLoginInFlight := FSession.LoginStored;
  if FLoginQueued and not FSession.Busy then begin
    FLoginQueued := false;
    if (FUser = '') and (FPassword = '') and (FSession.StoredCredentials <> '') then
      FLoginInFlight := FSession.LoginStored
    else FLoginInFlight := FSession.Login(FUser, FPassword);
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
  if not FSession.Authenticated then FAutoDownload := false;
  if FAutoDownload and not FSession.Busy and (FDetailsID > 0) then begin
    if (FSession.ErrorCode <> '') and (FSource + 1 < FSession.DetailLinks.Count) then Inc(FSource)
    else if FSession.ErrorCode <> '' then FAutoDownload := false;
    if FAutoDownload and (FSession.DetailSongID = FDetailsID) then begin
      if FSource < FSession.DetailLinks.Count then Activate
      else FAutoDownload := false;
    end;
  end;
  if FRemoteCount <> FSession.ResultCount then begin
    FRemoteCount := FSession.ResultCount;
    BuildRows;
  end;
end;

procedure TScreenLibrarySearch.QueueLogin;
begin
  if Assigned(FSession) and not FLoginInFlight and not FSession.Authenticated then
    FLoginQueued := true;
end;

function FitLibraryText(const Value: UTF8String; Size, Width: single): UTF8String;
var Tail: UTF8String;
begin
  SetFontStyle(0); SetFontSize(Size);
  Result := TruncateCatalogLine(Value, 200);
  if glTextWidth(Result) <= Width then Exit;
  Tail := UCS4ToUTF8String($2026);
  repeat
    DeleteLastCatalogCharacter(Result);
  until (Result = '') or (glTextWidth(Result + Tail) <= Width);
  Result := Result + Tail;
end;

procedure TScreenLibrarySearch.UpdateView;
var I, Index, InputLength: integer; Prefix, Caption: UTF8String; R: TLibraryTileRect;
begin
  Text[FPasswordText].Visible := FSignIn; Text[FLoginText].Visible := FSignIn;
  SetFontStyle(0); SetFontSize(22); InputLength := 49;
  repeat
    Caption := FormatCatalogInputLine('Search  ', FQuery, InputLength);
    Dec(InputLength);
  until (glTextWidth(Caption) <= 650) or (InputLength <= 2);
  Text[FQueryText].Text := Caption;
  if FFocus = 0 then Text[FQueryText].ColB := 0.5 else Text[FQueryText].ColB := 1;
  Text[FCountText].Visible := not FSignIn;
  Text[FPageText].Visible := not FSignIn;
  if FSignIn then begin
    Text[FAccountText].X := 24; Text[FAccountText].Y := 96;
    if FFocus = 2 then Prefix := '> ' else Prefix := '';
    Text[FAccountText].Text := TruncateCatalogLine(Prefix + 'User: ' + FUser, 26);
    Prefix := ''; if FFocus = 3 then Prefix := '> ';
    Text[FPasswordText].Text := Prefix + 'Password: ' + StringOfChar('*', Min(16, LengthUTF8(FPassword)));
    Prefix := ''; if FFocus = 4 then Prefix := '> ';
    Text[FLoginText].Text := Prefix + '[Sign in]';
  end else if Assigned(FSession) and FSession.Authenticated then
    Text[FAccountText].Text := 'USDB connected'
  else if Assigned(FSession) and FSession.Busy and (FSession.StoredCredentials <> '') then
    Text[FAccountText].Text := 'Connecting to USDB...'
  else Text[FAccountText].Text := 'USDB offline / F2: sign in';
  Text[FPageText].Text := Format('Page %d / %d', [FTop div LibraryGridPageSize + 1, Max(1, (Length(FRows) + LibraryGridPageSize - 1) div LibraryGridPageSize)]);
  if not FSignIn then begin Text[FAccountText].X := 410; Text[FAccountText].Y := 24; end;
  for I := 0 to High(FRowTexts) do begin
    Text[FArtistTexts[I]].Visible := FDetailsID = 0;
    Text[FBadgeTexts[I]].Visible := FDetailsID = 0;
  end;
  if (FDetailsID > 0) and Assigned(FSession) then begin
    Text[FPageText].Text := '';
    if FAutoDownload then Text[FCountText].Text := 'DOWNLOAD & SING'
    else Text[FCountText].Text := 'Try another source - Enter to download';
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
    if FAutoDownload then begin
      for I := 0 to High(FRowTexts) do Text[FRowTexts[I]].Visible := I < 4;
      Text[FRowTexts[0]].Text := FitLibraryText(FDownloadTitle, 28, 650);
      Text[FRowTexts[0]].X := 56; Text[FRowTexts[0]].Y := 206; Text[FRowTexts[0]].Size := 28;
      Text[FRowTexts[1]].Text := FitLibraryText(FDownloadArtist, 20, 650);
      Text[FRowTexts[1]].X := 56; Text[FRowTexts[1]].Y := 248; Text[FRowTexts[1]].Size := 20;
      if FSession.DetailLinks.Count = 0 then Caption := 'Finding available media...'
      else Caption := 'Downloading and checking audio...';
      Text[FRowTexts[2]].Text := Caption;
      Text[FRowTexts[2]].X := 56; Text[FRowTexts[2]].Y := 328; Text[FRowTexts[2]].Size := 18;
      if FSession.DetailLinks.Count > 0 then
        Text[FRowTexts[3]].Text := Format('Source %d / %d - playback starts when ready', [FSource + 1, FSession.DetailLinks.Count])
      else Text[FRowTexts[3]].Text := 'Playback starts automatically. The song stays in your collection.';
      Text[FRowTexts[3]].X := 56; Text[FRowTexts[3]].Y := 362; Text[FRowTexts[3]].Size := 14;
    end;
  end else begin
    for I := 0 to High(FRowTexts) do begin
      Index := FTop + I;
      Text[FRowTexts[I]].Visible := true;
      R := LibraryTileRect(I);
      Text[FRowTexts[I]].X := R.X + 9;
      Text[FRowTexts[I]].Y := R.Y + R.H - 40;
      Text[FRowTexts[I]].Align := 0; Text[FRowTexts[I]].Size := 15;
      Text[FArtistTexts[I]].X := R.X + 9;
      Text[FArtistTexts[I]].Y := R.Y + R.H - 21;
      Text[FArtistTexts[I]].Align := 0; Text[FArtistTexts[I]].Size := 12;
      Text[FBadgeTexts[I]].X := R.X + 8;
      Text[FBadgeTexts[I]].Y := R.Y + 7;
      Text[FRowTexts[I]].Text := ''; Text[FArtistTexts[I]].Text := ''; Text[FBadgeTexts[I]].Text := '';
      if Index < Length(FRows) then begin
        Text[FRowTexts[I]].Text := FitLibraryText(FRows[Index].Title, 15, R.W - 18);
        Text[FArtistTexts[I]].Text := FitLibraryText(FRows[Index].Artist, 12, R.W - 18);
        if FRows[Index].LocalIndex >= 0 then Text[FBadgeTexts[I]].Text := 'LOCAL'
        else if FRows[Index].RemoteIndex >= 0 then begin
          Text[FBadgeTexts[I]].Text := 'USDB  +';
        end;
      end;
    end;
    if Length(FRows) = 0 then begin
      Text[FRowTexts[0]].X := 42; Text[FRowTexts[0]].Y := 240;
      Text[FRowTexts[0]].Align := 0;
      if Assigned(FSession) and FSession.Busy then Caption := 'Searching USDB...'
      else if Assigned(FSession) and not FSession.Authenticated then Caption := 'No local matches. F2: sign in to search USDB.'
      else Caption := 'No songs found. Try another search.';
      Text[FRowTexts[0]].Text := Caption;
    end;
  end;
  if Assigned(FSession) then
    begin
      if (FDetailsID = 0) and (FSession.ErrorCode = '') and not FSession.Busy then
        Text[FStatusText].Text := 'Local songs first. USDB songs download, then start automatically.'
      else Text[FStatusText].Text := TruncateCatalogLine(FSession.Status, 83);
    end;
  if FSignIn then
    Text[FHintText].Text := 'Tab: user / password / sign in   Enter: sign in   F2: close account form'
  else if FAutoDownload then
    Text[FHintText].Text := 'Downloading in the background   Esc: cancel and return to results'
  else if FDetailsID > 0 then
    Text[FHintText].Text := 'Up/Down: source   Enter: retry download   Esc: results'
  else Text[FHintText].Text := 'Type to search   Arrows: browse   Enter: select / download & sing   F2: account   Esc: back';
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
    if FSession.Details(Song.SongID) then begin
      FDetailsID := Song.SongID; FSource := 0; FAutoDownload := true;
      FDownloadTitle := Song.Title; FDownloadArtist := Song.Artist;
    end;
  end;
end;

procedure TScreenLibrarySearch.Leave;
begin
  FLeaving := true; FAutoDownload := false;
  if FRescan then begin
    FRescan := false;
    ScreenMain.ReloadSongs(true);
    FadeTo(@ScreenMain);
  end else FadeTo(@ScreenSong);
end;

function TScreenLibrarySearch.AcceptsTransitionInput: boolean;
begin Result := true; end;

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

procedure LibraryBox(X, Y, W, H, R, G, B, A: single);
begin
  glDisable(GL_TEXTURE_2D); glDisable(GL_DEPTH_TEST); glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glColor4f(R, G, B, A); glBegin(GL_QUADS);
  glVertex2f(X, Y); glVertex2f(X + W, Y); glVertex2f(X + W, Y + H); glVertex2f(X, Y + H);
  glEnd; glColor4f(1, 1, 1, 1);
end;

procedure LibraryShade(const R: TLibraryTileRect);
begin
  glDisable(GL_TEXTURE_2D); glDisable(GL_DEPTH_TEST); glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA); glShadeModel(GL_SMOOTH);
  glBegin(GL_QUADS);
  glColor4f(0.015, 0.02, 0.04, 0.04);
  glVertex2f(R.X, R.Y + R.H * 0.25); glVertex2f(R.X + R.W, R.Y + R.H * 0.25);
  glColor4f(0.015, 0.02, 0.04, 0.98);
  glVertex2f(R.X + R.W, R.Y + R.H); glVertex2f(R.X, R.Y + R.H);
  glEnd; glColor4f(1, 1, 1, 1);
end;

procedure TScreenLibrarySearch.DrawGrid;
var I, J, Index, Tint: integer; Cover: TTexture; Key: UTF8String;
  R: TLibraryTileRect; Crop, Aspect: single;
begin
  for I := 0 to High(FCovers) do begin
    Index := FTop + I;
    if Index >= Length(FRows) then Continue;
    R := LibraryTileRect(I);
    if (FFocus = 1) and (Index = FSelected) then
      LibraryBox(R.X - 2, R.Y - 2, R.W + 4, R.H + 4, 1, 0.79, 0.36, 1);
    Key := '';
    if (FRows[Index].LocalIndex >= 0) and CatSongs.Song[FRows[Index].LocalIndex].Cover.IsSet then
      Key := CatSongs.Song[FRows[Index].LocalIndex].Path.Append(CatSongs.Song[FRows[Index].LocalIndex].Cover).ToUTF8;
    if Key <> FCoverKeys[I] then begin
      if FCovers[I].TexNum <> 0 then UTexture.Texture.UnLoadTexture(FCovers[I]);
      FCoverKeys[I] := Key;
      if (Key <> '') and CatSongs.Song[FRows[Index].LocalIndex].Path.Append(CatSongs.Song[FRows[Index].LocalIndex].Cover).IsFile then
        FCovers[I] := UTexture.Texture.LoadTexture(CatSongs.Song[FRows[Index].LocalIndex].Path.Append(CatSongs.Song[FRows[Index].LocalIndex].Cover));
    end;
    if FCovers[I].TexNum <> 0 then begin
      Cover := FCovers[I];
      // Crop the center to fill each card without stretching portrait or landscape art.
      Aspect := Cover.W / Max(1, Cover.H);
      if Aspect > R.W / R.H then begin
        Crop := (1 - (R.W / R.H) / Aspect) / 2;
        Cover.TexX1 := Crop; Cover.TexX2 := 1 - Crop;
      end else begin
        Crop := (1 - Aspect / (R.W / R.H)) / 2;
        Cover.TexY1 := Crop; Cover.TexY2 := 1 - Crop;
      end;
      Cover.X := R.X; Cover.Y := R.Y; Cover.W := R.W; Cover.H := R.H;
      DrawTexture(Cover);
    end else begin
      Tint := 0;
      for J := 1 to Length(FRows[Index].Artist) do Tint := (Tint + Ord(FRows[Index].Artist[J])) mod 128;
      LibraryBox(R.X, R.Y, R.W, R.H, 0.13 + Tint / 700, 0.12, 0.26 + Tint / 900, 1);
      Cover := FDefaultCover; Cover.Alpha := 0.24;
      Cover.X := R.X + (R.W - 62) / 2; Cover.Y := R.Y + 17; Cover.W := 62; Cover.H := 62;
      DrawTexture(Cover);
    end;
    LibraryShade(R);
    LibraryBox(R.X + 5, R.Y + 4, 57, 18, 0.015, 0.02, 0.04, 0.75);
  end;
end;

function TScreenLibrarySearch.Draw: boolean;
begin
  Tick;
  if FLeaving then begin DrawBG; DrawFG; Exit(true); end;
  UpdateView;
  DrawBG;
  LibraryBox(24, 51, 752, 37, 0.09, 0.12, 0.19, 1);
  if FFocus = 0 then LibraryBox(24, 86, 752, 2, 0.65, 0.71, 1, 1);
  LibraryBox(24, 555, 752, 1, 0.18, 0.23, 0.32, 1);
  if FDetailsID = 0 then DrawGrid
  else if FAutoDownload then begin
    LibraryBox(24, 118, 752, 398, 0.07, 0.09, 0.15, 1);
    LibraryBox(56, 444, 688, 3, 0.18, 0.23, 0.32, 1);
    LibraryBox(56 + (GetTickCount64 mod 2000) / 2000 * 520, 444, 168, 3, 0.65, 0.71, 1, 1);
  end;
  DrawFG; Result := true;
end;

function TScreenLibrarySearch.ParseInput(Key: cardinal; CharCode: UCS4Char; Down: boolean): boolean;
var S: UTF8String; Step, Next: integer;
begin
  Result := true; if not Down then Exit;
  if Key = SDLK_F2 then begin
    FSignIn := not FSignIn;
    if FSignIn then FFocus := 2 else begin FFocus := 0; FLoginQueued := false; ClearPassword; end;
  end else if Key = SDLK_ESCAPE then begin
    if FDetailsID > 0 then begin
      FAutoDownload := false; FDetailsID := 0;
      if Assigned(FSession) and FSession.Busy then begin
        FSession.Close; FSession.ForceTerminate; FreeAndNil(FSession);
        StartSession; FLastQuery := #1; FRemoteCount := -1;
      end;
      BuildRows;
    end
    else if FSignIn then begin FSignIn := false; FFocus := 0; FLoginQueued := false; ClearPassword; end
    else Leave;
  end else if Key = SDLK_TAB then begin
    if FSignIn then begin Inc(FFocus); if FFocus > 4 then FFocus := 2; end
    else FFocus := 1 - Min(1, FFocus);
  end else if ((Key = SDLK_DOWN) or (Key = SDLK_UP) or (Key = SDLK_LEFT) or (Key = SDLK_RIGHT) or (Key = SDLK_PAGEDOWN) or (Key = SDLK_PAGEUP)) then begin
    if FDetailsID > 0 then begin
      if Assigned(FSession) and FSession.Busy then Exit;
      if (Key = SDLK_UP) or (Key = SDLK_LEFT) or (Key = SDLK_PAGEUP) then Step := -1 else Step := 1;
      if (Key = SDLK_PAGEUP) or (Key = SDLK_PAGEDOWN) then Step := Step * 8;
      if Assigned(FSession) then
        FSource := EnsureRange(FSource + Step, 0, Max(0, FSession.DetailLinks.Count - 1));
    end else begin
      case Key of
        SDLK_LEFT: Step := -1; SDLK_RIGHT: Step := 1;
        SDLK_UP: Step := -LibraryGridColumns; SDLK_DOWN: Step := LibraryGridColumns;
        SDLK_PAGEUP: Step := -LibraryGridPageSize; else Step := LibraryGridPageSize;
      end;
      if (FFocus <> 1) and (Step > 0) then Next := 0
      else Next := LibraryGridMove(FSelected, Step, Length(FRows));
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
    if FSignIn then QueueLogin else Activate;
  end else if (Key = SDLK_d) and (FDetailsID > 0) then Activate
  else if (Key = SDLK_BACKSPACE) and ((FDetailsID = 0) or FSignIn) then begin
    case FFocus of
      2: DeleteLastCatalogCharacter(FUser);
      3: DeleteLastCatalogCharacter(FPassword);
      4: ; // The sign-in button is not an editable field.
    else DeleteLastCatalogCharacter(FQuery); FFocus := 0; Changed;
    end;
  end else if (FDetailsID = 0) and IsPrintableCatalogCharacter(CharCode) and
              ((SDL_GetModState and (KMOD_CTRL or KMOD_ALT or KMOD_GUI)) = 0) then begin
    S := UCS4ToUTF8String(CharCode);
    case FFocus of
      2: if Length(FUser) + Length(S) <= 200 then FUser := FUser + S;
      3: if Length(FPassword) + Length(S) <= 1024 then FPassword := FPassword + S;
      4: ;
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
  if (X < 24) or (X > 776) then Exit;
  if MouseButton = SDL_BUTTON_WHEELDOWN then begin ParseInput(SDLK_PAGEDOWN, 0, true); Exit; end;
  if MouseButton = SDL_BUTTON_WHEELUP then begin ParseInput(SDLK_PAGEUP, 0, true); Exit; end;
  if MouseButton <> SDL_BUTTON_LEFT then Exit;
  if (X >= 705) and (Y >= 16) and (Y < 48) then Leave
  else if (X >= 705) and (Y >= 52) and (Y < 90) then begin FQuery := ''; FFocus := 0; Changed; end
  else if (Y >= 52) and (Y < 88) then FFocus := 0
  else if ((FSignIn and (Y >= 92) and (Y < 114)) or (not FSignIn and (X >= 400) and (Y >= 16) and (Y < 44))) then begin
    if not FSignIn then begin FSignIn := true; FFocus := 2; end
    else if X >= 640 then QueueLogin
    else if X < 315 then FFocus := 2 else FFocus := 3;
  end else if (FDetailsID > 0) and not FAutoDownload and (Y >= 220) and (Y < 460) then begin
    if Assigned(FSession) and FSession.Busy then Exit;
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
