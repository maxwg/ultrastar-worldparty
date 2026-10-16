unit UScreenSongCatalog;

interface

{$IFDEF FPC}{$MODE Delphi}{$ENDIF}
{$I switches.inc}

uses sdl2, UMenu, USongCatalogBridge, USongCatalogSelection;

type
  TScreenSongCatalog = class(TMenu)
  private
    FSession: TCatalogSession;
    FSelection: TCatalogSelection;
    FInstructionsText, FResultsLabelText: integer;
    FArtist, FTitle, FUsername, FPassword: UTF8String;
    FStatusText, FArtistText, FTitleText, FUserText, FPasswordText, FActionText: integer;
    FResultText: array[0..5] of integer;
    FDisplayCharLimit: integer;
    FReady: boolean;
    procedure StartOrReopen;
    procedure UpdateView;
    procedure ClearPassword;
    procedure AppendInput(const Value: UTF8String);
    function ShortLine(const Value: UTF8String): UTF8String;
    function SelectedResult(out Song: TCatalogSearchResult): boolean;
    function SourceDetailLineCount: integer;
    function SourceDetailLine(Index: integer): UTF8String;
    procedure LeaveCatalog;
  public
    constructor Create; override;
    destructor Destroy; override;
    function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
    function Draw: boolean; override;
    procedure OnShow; override;
    procedure OnHide; override;
  end;

implementation

uses SysUtils, UCommandLine, UGraphic, UUnicodeUtils, UCommon, UScreenSongMenu,
  ULanguage, USongCatalogLayout, USongCatalogInput;

constructor TScreenSongCatalog.Create;
var I: integer; L: TSongCatalogLayout;
begin
  inherited Create;
  L := MakeSongCatalogLayout(RenderW, RenderH);
  FDisplayCharLimit := L.TextWidth div L.FontSize;
  if FDisplayCharLimit < 1 then FDisplayCharLimit := 1;
  AddText(L.X, L.TitleY, ShortLine(Language.Translate('SONG_CATALOG_TITLE')));
  FInstructionsText := AddText(L.X, L.InstructionsY, ShortLine(Language.Translate('SONG_CATALOG_INSTRUCTIONS')));
  FArtistText := AddText(L.X, L.ArtistY, Language.Translate('SONG_CATALOG_ARTIST'));
  FTitleText := AddText(L.X, L.SongTitleY, Language.Translate('SONG_CATALOG_TITLE_FIELD'));
  FUserText := AddText(L.X, L.UsernameY, Language.Translate('SONG_CATALOG_USERNAME'));
  FPasswordText := AddText(L.X, L.PasswordY, Language.Translate('SONG_CATALOG_PASSWORD'));
  FActionText := AddText(L.X, L.ActionsY, '');
  FStatusText := AddText(L.X, L.StatusY, '');
  FResultsLabelText := AddText(L.X, L.ResultsLabelY, ShortLine(Language.Translate('SONG_CATALOG_METADATA')));
  for I := 0 to High(FResultText) do
    FResultText[I] := AddText(L.X, L.ResultsFirstY + I * L.ResultsStep, '');
  for I := 0 to High(Text) do
  begin
    Text[I].Size := L.FontSize;
    // Keep every item to one visual line. Dynamic fields and results are
    // shortened below, so long catalog metadata cannot wrap into neighbours.
    Text[I].W := 0;
    Text[I].Text := Text[I].Text;
  end;
  ResetCatalogSelection(FSelection);
  FReady := false;
  UpdateView;
end;

function TScreenSongCatalog.ShortLine(const Value: UTF8String): UTF8String;
begin
  Result := TruncateCatalogLine(Value, FDisplayCharLimit);
end;

destructor TScreenSongCatalog.Destroy;
begin
  ClearPassword;
  if Assigned(FSession) then
  begin
    FSession.Close;
    FSession.ForceTerminate;
    FreeAndNil(FSession);
  end;
  inherited Destroy;
end;

procedure TScreenSongCatalog.ClearPassword;
begin
  if Length(FPassword) > 0 then FillChar(FPassword[1], Length(FPassword), 0);
  FPassword := '';
end;

procedure TScreenSongCatalog.StartOrReopen;
begin
  FReady := false;
  ResetCatalogSelection(FSelection);
  if Assigned(FSession) then
  begin
    FSession.Poll;
    if FSession.HelperRunning then
    begin
      if FSession.Closing then
        Text[FStatusText].Text := 'Previous catalog session is still closing.'
      else
        Text[FStatusText].Text := 'Catalog helper is already active.';
      Exit;
    end;
    FreeAndNil(FSession);
  end;
  if not Assigned(Params) or
     not CatalogConfigurationReady(Params.CatalogPython, Params.CatalogAdapter) then
  begin
    Text[FStatusText].Text := 'Catalog setup is unavailable. Configure absolute Python and adapter paths.';
    Exit;
  end;
  FSession := TCatalogSession.Create(TCatalogProcessTransport.Create, true);
  FReady := FSession.Start(Params.CatalogPython, Params.CatalogAdapter);
  UpdateView;
end;

procedure TScreenSongCatalog.OnShow;
begin
  inherited;
  StartOrReopen;
end;

procedure TScreenSongCatalog.OnHide;
begin
  if Assigned(FSession) then
  begin
    FSession.Close;
    // Hide must not leave a child or pending credentials alive while this
    // screen is not being polled. Termination targets only the owned helper.
    FSession.ForceTerminate;
  end;
  ClearPassword;
  ResetCatalogSelection(FSelection);
  inherited;
end;

function TScreenSongCatalog.SelectedResult(out Song: TCatalogSearchResult): boolean;
begin
  Result := Assigned(FSession) and (FSelection.Selected >= 0) and
    (FSelection.Selected < FSession.ResultCount);
  if Result then Song := FSession.ResultItems[FSelection.Selected];
end;

function TScreenSongCatalog.SourceDetailLineCount: integer;
var Song: TCatalogSearchResult;
begin
  Result := 6;
  if not SelectedResult(Song) then Exit;
  if FSession.Authenticated and
     (FSession.DetailSongID = Song.SongID) and (FSession.DetailLinks.Count > 0) then
    Result := 5 + FSession.DetailLinks.Count;
end;

function TScreenSongCatalog.SourceDetailLine(Index: integer): UTF8String;
var Song: TCatalogSearchResult; HaveDetails: boolean; Link: UTF8String;
begin
  Result := '';
  if not SelectedResult(Song) then Exit;
  HaveDetails := FSession.Authenticated and (FSession.DetailSongID = Song.SongID);
  case Index of
    0: Result := 'ID ' + IntToStr(Song.SongID);
    1: Result := Language.Translate('SONG_CATALOG_ARTIST') + ' ' + Song.Artist;
    2: Result := Language.Translate('SONG_CATALOG_TITLE_FIELD') + ' ' + Song.Title;
    3: Result := Language.Translate('SONG_CATALOG_LANGUAGE') + ' ' + Song.Language;
    4:
      if HaveDetails then
        Result := Language.Translate('SONG_CATALOG_SOURCES') + ' ' + IntToStr(FSession.DetailLinks.Count)
      else if FSession.Busy then Result := Language.Translate('SONG_CATALOG_DETAILS_LOADING')
      else Result := Language.Translate('SONG_CATALOG_DETAILS_UNAVAILABLE');
  else
    if HaveDetails and (Index - 5 < FSession.DetailLinks.Count) then
    begin
      // The bridge validates canonical YouTube source URLs. Show the full
      // video ID within the existing short row; this text never opens a link.
      Link := UTF8String(FSession.DetailLinks[Index - 5]);
      Result := Language.Translate('SONG_CATALOG_SOURCE') + ' ' + Copy(Link, Length(Link) - 10, 11);
    end
    else if HaveDetails and (Index = 5) and (FSession.DetailLinks.Count = 0) then
      Result := Language.Translate('SONG_CATALOG_NO_SOURCES');
  end;
end;

procedure TScreenSongCatalog.LeaveCatalog;
begin
  if Assigned(FSession) then
  begin FSession.Close; FSession.ForceTerminate; end;
  ClearPassword;
  ResetCatalogSelection(FSelection);
  if Assigned(ScreenSongMenu) then ScreenSongMenu.MenuShow(SM_Main);
  FadeTo(@ScreenSong);
end;

procedure TScreenSongCatalog.UpdateView;
var I, Index, LastVisible: integer;
  Prefix, FieldPrefix, ShownPassword, Actions, BackCaption, LabelText: UTF8String;
  Song: TCatalogSearchResult;
begin
  if Assigned(FSession) then SetCatalogResultCount(FSelection, FSession.ResultCount)
  else SetCatalogResultCount(FSelection, 0);
  if FSelection.InDetails then
    SetCatalogDetailLineCount(FSelection, SourceDetailLineCount);

  if FSelection.Focus = CatalogResultsFocus then
  begin
    if FSelection.InDetails then
      Text[FInstructionsText].Text := ShortLine(Language.Translate('SONG_CATALOG_DETAIL_INSTRUCTIONS'))
    else Text[FInstructionsText].Text := ShortLine(Language.Translate('SONG_CATALOG_RESULT_INSTRUCTIONS'));
  end
  else Text[FInstructionsText].Text := ShortLine(Language.Translate('SONG_CATALOG_INSTRUCTIONS'));

  FieldPrefix := ''; if FSelection.Focus = 0 then FieldPrefix := '> ';
  FieldPrefix := FieldPrefix + Language.Translate('SONG_CATALOG_ARTIST') + ' ';
  if FSelection.Focus = 0 then
    Text[FArtistText].Text := FormatCatalogInputLine(FieldPrefix, FArtist, FDisplayCharLimit)
  else
    Text[FArtistText].Text := ShortLine(FieldPrefix + FArtist);

  FieldPrefix := ''; if FSelection.Focus = 1 then FieldPrefix := '> ';
  FieldPrefix := FieldPrefix + Language.Translate('SONG_CATALOG_TITLE_FIELD') + ' ';
  if FSelection.Focus = 1 then
    Text[FTitleText].Text := FormatCatalogInputLine(FieldPrefix, FTitle, FDisplayCharLimit)
  else
    Text[FTitleText].Text := ShortLine(FieldPrefix + FTitle);

  FieldPrefix := ''; if FSelection.Focus = 2 then FieldPrefix := '> ';
  FieldPrefix := FieldPrefix + Language.Translate('SONG_CATALOG_USERNAME') + ' ';
  if FSelection.Focus = 2 then
    Text[FUserText].Text := FormatCatalogInputLine(FieldPrefix, FUsername, FDisplayCharLimit)
  else
    Text[FUserText].Text := ShortLine(FieldPrefix + FUsername);

  FieldPrefix := ''; if FSelection.Focus = 3 then FieldPrefix := '> ';
  ShownPassword := StringOfChar('*', LengthUTF8(FPassword));
  FieldPrefix := FieldPrefix + Language.Translate('SONG_CATALOG_PASSWORD') + ' ';
  if FSelection.Focus = 3 then
    Text[FPasswordText].Text := FormatCatalogInputLine(FieldPrefix, ShownPassword, FDisplayCharLimit)
  else
    Text[FPasswordText].Text := ShortLine(FieldPrefix + ShownPassword);

  if FSelection.InDetails then BackCaption := Language.Translate('SONG_CATALOG_BACK_RESULTS')
  else BackCaption := Language.Translate('C_BACK');
  // Always show the focused action first, including at the smallest layout.
  case FSelection.Focus of
    CatalogSearchFocus: Actions := '> ' + Language.Translate('SONG_CATALOG_SEARCH');
    CatalogSignInFocus: Actions := '> ' + Language.Translate('SONG_CATALOG_SIGN_IN');
    CatalogBackFocus: Actions := '> ' + BackCaption;
  else
    if FSelection.InDetails then Actions := BackCaption
    else Actions := Language.Translate('SONG_CATALOG_SEARCH') + ' ' +
      Language.Translate('SONG_CATALOG_SIGN_IN') + ' ' + BackCaption;
  end;
  Text[FActionText].Text := ShortLine(Actions);
  if Assigned(FSession) and (FReady or FSession.Closing) then
    Text[FStatusText].Text := ShortLine(FSession.Status);

  if FSelection.InDetails then
  begin
    LabelText := Language.Translate('SONG_CATALOG_SOURCE_DETAILS');
    LastVisible := FSelection.DetailTop + CatalogVisibleRows;
    if LastVisible > FSelection.DetailLineCount then LastVisible := FSelection.DetailLineCount;
    LabelText := LabelText + Format(' %d-%d/%d',
      [FSelection.DetailTop + 1, LastVisible, FSelection.DetailLineCount]);
    for I := 0 to High(FResultText) do
      Text[FResultText[I]].Text := ShortLine(SourceDetailLine(FSelection.DetailTop + I));
  end
  else
  begin
    LabelText := Language.Translate('SONG_CATALOG_METADATA');
    if FSelection.ResultCount > 0 then
    begin
      LastVisible := FSelection.Top + CatalogVisibleRows;
      if LastVisible > FSelection.ResultCount then LastVisible := FSelection.ResultCount;
      LabelText := LabelText + Format(' %d-%d/%d',
        [FSelection.Top + 1, LastVisible, FSelection.ResultCount]);
    end;
    for I := 0 to High(FResultText) do
    begin
      Index := FSelection.Top + I;
      if Assigned(FSession) and (Index < FSelection.ResultCount) then
      begin
        Song := FSession.ResultItems[Index];
        Prefix := '  ';
        if (FSelection.Focus = CatalogResultsFocus) and (Index = FSelection.Selected) then Prefix := '> ';
        Text[FResultText[I]].Text := ShortLine(Prefix + Song.Artist + ' - ' + Song.Title);
      end
      else if (I = 0) and (FSelection.ResultCount = 0) then
        Text[FResultText[I]].Text := ShortLine(Language.Translate('SONG_CATALOG_NO_RESULTS'))
      else Text[FResultText[I]].Text := '';
    end;
  end;
  Text[FResultsLabelText].Text := ShortLine(LabelText);
end;

procedure TScreenSongCatalog.AppendInput(const Value: UTF8String);
begin
  case FSelection.Focus of
    0: if Length(FArtist) + Length(Value) <= 200 then FArtist := FArtist + Value;
    1: if Length(FTitle) + Length(Value) <= 200 then FTitle := FTitle + Value;
    2: if Length(FUsername) + Length(Value) <= 200 then FUsername := FUsername + Value;
    3: if Length(FPassword) + Length(Value) <= 1024 then FPassword := FPassword + Value;
  end;
  UpdateView;
end;

function TScreenSongCatalog.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
var S: UTF8String; Key: TCatalogNavigationKey; Action: TCatalogSelectionAction;
  IsNavigation: boolean; Song: TCatalogSearchResult;
  procedure DeleteLastUTF8(var Value: UTF8String);
  begin
    DeleteLastCatalogCharacter(Value);
  end;
begin
  Result := true;
  if not PressedDown then Exit;
  if Assigned(FSession) then FSession.Poll;
  UpdateView;
  IsNavigation := true;
  Key := cnTab;
  case PressedKey of
    SDLK_TAB:
      if (SDL_GetModState and KMOD_SHIFT) <> 0 then Key := cnBackTab
      else Key := cnTab;
    SDLK_DOWN: Key := cnDown;
    SDLK_UP: Key := cnUp;
    SDLK_RETURN: Key := cnEnter;
    SDLK_ESCAPE: Key := cnEscape;
  else IsNavigation := false;
  end;
  if IsNavigation then
  begin
    Action := HandleCatalogNavigation(FSelection, Key);
    case Action of
      caSearch:
        if Assigned(FSession) and FReady and FSession.Search(FArtist, FTitle) then
          ResetCatalogSelection(FSelection, CatalogSearchFocus);
      caSignIn:
        begin
          if Assigned(FSession) and FReady and FSession.Login(FUsername, FPassword) and
             FSelection.InDetails then ReturnToCatalogResults(FSelection);
          ClearPassword;
        end;
      caDetails:
        if FReady and SelectedResult(Song) then
          if FSession.Details(Song.SongID) then
            BeginCatalogSourceDetails(FSelection, SourceDetailLineCount);
      caClose: begin LeaveCatalog; Exit; end;
    end;
    UpdateView;
    Exit;
  end;
  if PressedKey = SDLK_BACKSPACE then
  begin
    case FSelection.Focus of
      0: DeleteLastUTF8(FArtist);
      1: DeleteLastUTF8(FTitle);
      2: DeleteLastUTF8(FUsername);
      3: DeleteLastUTF8(FPassword);
    end;
    UpdateView;
    Exit;
  end;
  if (FSelection.Focus <= 3) and IsPrintableCatalogCharacter(CharCode) then
  begin
    S := UCS4ToUTF8String(CharCode);
    AppendInput(S);
  end;
end;

function TScreenSongCatalog.Draw: boolean;
begin
  if Assigned(FSession) and FSession.Closing and not FSession.HelperRunning then
    StartOrReopen;
  if Assigned(FSession) then FSession.Poll;
  UpdateView;
  Result := inherited Draw;
end;

end.
