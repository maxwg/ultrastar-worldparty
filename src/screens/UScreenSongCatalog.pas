unit UScreenSongCatalog;

interface

{$IFDEF FPC}{$MODE Delphi}{$ENDIF}
{$I switches.inc}

uses sdl2, UMenu, USongCatalogBridge;

type
  TScreenSongCatalog = class(TMenu)
  private
    FSession: TCatalogSession;
    FFocus: integer;
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
  AddText(L.X, L.InstructionsY, ShortLine(Language.Translate('SONG_CATALOG_INSTRUCTIONS')));
  FArtistText := AddText(L.X, L.ArtistY, Language.Translate('SONG_CATALOG_ARTIST'));
  FTitleText := AddText(L.X, L.SongTitleY, Language.Translate('SONG_CATALOG_TITLE_FIELD'));
  FUserText := AddText(L.X, L.UsernameY, Language.Translate('SONG_CATALOG_USERNAME'));
  FPasswordText := AddText(L.X, L.PasswordY, Language.Translate('SONG_CATALOG_PASSWORD'));
  FActionText := AddText(L.X, L.ActionsY, '');
  FStatusText := AddText(L.X, L.StatusY, '');
  AddText(L.X, L.ResultsLabelY, ShortLine(Language.Translate('SONG_CATALOG_METADATA')));
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
  FFocus := 0;
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
  inherited;
end;

procedure TScreenSongCatalog.UpdateView;
var I: integer; Prefix, ShownPassword, Actions: string;
begin
  Prefix := ''; if FFocus = 0 then Prefix := '> ';
  Text[FArtistText].Text := ShortLine(Prefix + Language.Translate('SONG_CATALOG_ARTIST') + ' ' + FArtist);
  Prefix := ''; if FFocus = 1 then Prefix := '> ';
  Text[FTitleText].Text := ShortLine(Prefix + Language.Translate('SONG_CATALOG_TITLE_FIELD') + ' ' + FTitle);
  Prefix := ''; if FFocus = 2 then Prefix := '> ';
  Text[FUserText].Text := ShortLine(Prefix + Language.Translate('SONG_CATALOG_USERNAME') + ' ' + FUsername);
  Prefix := ''; if FFocus = 3 then Prefix := '> ';
  ShownPassword := StringOfChar('*', LengthUTF8(FPassword));
  Text[FPasswordText].Text := ShortLine(Prefix + Language.Translate('SONG_CATALOG_PASSWORD') + ' ' + ShownPassword);
  Prefix := ''; if FFocus = 4 then Prefix := '> ';
  Actions := Prefix + Language.Translate('SONG_CATALOG_SEARCH') + ' ';
  Prefix := ''; if FFocus = 5 then Prefix := '> ';
  Actions := Actions + Prefix + Language.Translate('SONG_CATALOG_SIGN_IN') + ' ';
  Prefix := ''; if FFocus = 6 then Prefix := '> ';
  Actions := Actions + Prefix + Language.Translate('C_BACK');
  Text[FActionText].Text := ShortLine(Actions);
  if Assigned(FSession) and (FReady or FSession.Closing) then
    Text[FStatusText].Text := ShortLine(FSession.Status);
  for I := 0 to High(FResultText) do
    if Assigned(FSession) and (I < FSession.Results.Count) then
      Text[FResultText[I]].Text := ShortLine(FSession.Results[I])
    else Text[FResultText[I]].Text := '';
end;

procedure TScreenSongCatalog.AppendInput(const Value: UTF8String);
begin
  case FFocus of
    0: if Length(FArtist) + Length(Value) <= 200 then FArtist := FArtist + Value;
    1: if Length(FTitle) + Length(Value) <= 200 then FTitle := FTitle + Value;
    2: if Length(FUsername) + Length(Value) <= 200 then FUsername := FUsername + Value;
    3: if Length(FPassword) + Length(Value) <= 1024 then FPassword := FPassword + Value;
  end;
  UpdateView;
end;

function TScreenSongCatalog.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
var S: UTF8String;
  procedure DeleteLastUTF8(var Value: UTF8String);
  begin
    DeleteLastCatalogCharacter(Value);
  end;
begin
  Result := true;
  if not PressedDown then Exit;
  if Assigned(FSession) then FSession.Poll;
  if PressedKey = SDLK_ESCAPE then
  begin
    if Assigned(FSession) then
    begin FSession.Close; FSession.ForceTerminate; end;
    ClearPassword;
    if Assigned(ScreenSongMenu) then ScreenSongMenu.MenuShow(SM_Main);
    FadeTo(@ScreenSong);
    Exit;
  end;
  case PressedKey of
    SDLK_TAB, SDLK_DOWN: begin FFocus := (FFocus + 1) mod 7; UpdateView; Exit; end;
    SDLK_UP: begin FFocus := (FFocus + 6) mod 7; UpdateView; Exit; end;
    SDLK_BACKSPACE:
      begin
        case FFocus of
          0: DeleteLastUTF8(FArtist);
          1: DeleteLastUTF8(FTitle);
          2: DeleteLastUTF8(FUsername);
          3: DeleteLastUTF8(FPassword);
        end;
        UpdateView; Exit;
      end;
    SDLK_RETURN:
      begin
        if FFocus <= 3 then Inc(FFocus)
        else if (FFocus = 4) and Assigned(FSession) and FReady then
          FSession.Search(FArtist, FTitle)
        else if (FFocus = 5) and Assigned(FSession) and FReady then
        begin
          FSession.Login(FUsername, FPassword);
          ClearPassword;
        end
        else if FFocus = 6 then
        begin
          if Assigned(FSession) then
          begin FSession.Close; FSession.ForceTerminate; end;
          if Assigned(ScreenSongMenu) then ScreenSongMenu.MenuShow(SM_Main);
          FadeTo(@ScreenSong);
        end;
        UpdateView; Exit;
      end;
  end;
  if (FFocus <= 3) and IsPrintableCatalogCharacter(CharCode) then
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
