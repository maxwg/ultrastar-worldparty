unit USongCatalogLayout;

{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}

interface

type
  TSongCatalogLayout = record
    X: integer;
    TitleY, InstructionsY, ArtistY, SongTitleY, UsernameY, PasswordY: integer;
    ActionsY, StatusY, ResultsLabelY, ResultsFirstY, ResultsStep: integer;
    FontSize, TextWidth: integer;
  end;

function MakeSongCatalogLayout(RenderWidth, RenderHeight: integer): TSongCatalogLayout;

implementation

uses Math;

function Clamp(Value, LowValue, HighValue: integer): integer;
begin
  if Value < LowValue then Result := LowValue
  else if Value > HighValue then Result := HighValue
  else Result := Value;
end;

function MakeSongCatalogLayout(RenderWidth, RenderHeight: integer): TSongCatalogLayout;
var H, W, MinStep, Y: integer;
begin
  W := RenderWidth;
  H := RenderHeight;
  if W < 320 then W := 800;
  if H < 240 then H := 600;
  Result.X := Clamp(Round(W * 0.08), 20, W - 24);
  Result.FontSize := Clamp(Round(H * 0.05), 12, 30);
  MinStep := Result.FontSize + 2;
  Result.TitleY := Round(H * 0.06);
  Result.InstructionsY := Round(H * 0.12);
  Result.ArtistY := Round(H * 0.19);
  Result.SongTitleY := Round(H * 0.24);
  Result.UsernameY := Round(H * 0.29);
  Result.PasswordY := Round(H * 0.34);
  Result.ActionsY := Round(H * 0.40);
  Result.StatusY := Round(H * 0.46);
  Result.ResultsLabelY := Round(H * 0.52);
  Result.ResultsFirstY := Round(H * 0.58);
  // The text renderer uses Size pixels per line. Push each item down when
  // the preferred percentage spacing would make adjacent labels overlap.
  if Result.InstructionsY < Result.TitleY + MinStep then
    Result.InstructionsY := Result.TitleY + MinStep;
  if Result.ArtistY < Result.InstructionsY + MinStep then
    Result.ArtistY := Result.InstructionsY + MinStep;
  if Result.SongTitleY < Result.ArtistY + MinStep then
    Result.SongTitleY := Result.ArtistY + MinStep;
  if Result.UsernameY < Result.SongTitleY + MinStep then
    Result.UsernameY := Result.SongTitleY + MinStep;
  if Result.PasswordY < Result.UsernameY + MinStep then
    Result.PasswordY := Result.UsernameY + MinStep;
  if Result.ActionsY < Result.PasswordY + MinStep then
    Result.ActionsY := Result.PasswordY + MinStep;
  if Result.StatusY < Result.ActionsY + MinStep then
    Result.StatusY := Result.ActionsY + MinStep;
  if Result.ResultsLabelY < Result.StatusY + MinStep then
    Result.ResultsLabelY := Result.StatusY + MinStep;
  if Result.ResultsFirstY < Result.ResultsLabelY + MinStep then
    Result.ResultsFirstY := Result.ResultsLabelY + MinStep;
  Result.ResultsStep := Max(MinStep, Round(H * 0.045));
  Result.TextWidth := Max(180, W - Result.X - 24);
  // All 15 single-line items, including six results, fit even at 320x240.
  // If a future renderer size is smaller than the supported minimum, reduce
  // row spacing rather than letting the last result run off-screen.
  Y := Result.ResultsFirstY + 5 * Result.ResultsStep + Result.FontSize;
  if Y > H - 4 then
    Result.ResultsStep := Max(MinStep, (H - 4 - Result.FontSize - Result.ResultsFirstY) div 5);
end;

end.
