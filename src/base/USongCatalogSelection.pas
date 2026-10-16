unit USongCatalogSelection;

{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}

interface

const
  CatalogVisibleRows = 6;
  CatalogSearchFocus = 4;
  CatalogSignInFocus = 5;
  CatalogBackFocus = 6;
  CatalogResultsFocus = 7;

type
  TCatalogNavigationKey = (cnTab, cnBackTab, cnUp, cnDown, cnEnter, cnEscape);
  TCatalogSelectionAction = (caNone, caSearch, caSignIn, caDetails, caClose);
  TCatalogSelection = record
    Focus, ResultCount, Selected, Top: integer;
    InDetails: boolean;
    DetailTop, DetailLineCount: integer;
  end;

procedure ResetCatalogSelection(var Selection: TCatalogSelection; Focus: integer = 0);
procedure SetCatalogResultCount(var Selection: TCatalogSelection; Count: integer);
procedure SetCatalogDetailLineCount(var Selection: TCatalogSelection; Count: integer);
function BeginCatalogSourceDetails(var Selection: TCatalogSelection; LineCount: integer): boolean;
procedure ReturnToCatalogResults(var Selection: TCatalogSelection);
function HandleCatalogNavigation(var Selection: TCatalogSelection;
  Key: TCatalogNavigationKey): TCatalogSelectionAction;

implementation

function Clamp(Value, LowValue, HighValue: integer): integer;
begin
  if Value < LowValue then Result := LowValue
  else if Value > HighValue then Result := HighValue
  else Result := Value;
end;

procedure ResetCatalogSelection(var Selection: TCatalogSelection; Focus: integer);
begin
  Selection.Focus := Clamp(Focus, 0, CatalogBackFocus);
  Selection.ResultCount := 0;
  Selection.Selected := -1;
  Selection.Top := 0;
  Selection.InDetails := false;
  Selection.DetailTop := 0;
  Selection.DetailLineCount := 0;
end;

procedure SetCatalogResultCount(var Selection: TCatalogSelection; Count: integer);
var MaxTop: integer;
begin
  if Count < 0 then Count := 0;
  if Count <> Selection.ResultCount then
  begin
    Selection.InDetails := false;
    Selection.DetailTop := 0;
    Selection.DetailLineCount := 0;
  end;
  Selection.ResultCount := Count;
  if Count = 0 then
  begin
    Selection.Selected := -1;
    Selection.Top := 0;
    // An asynchronously emptied list must not turn Enter into another request.
    if Selection.Focus = CatalogResultsFocus then Selection.Focus := 0;
    Exit;
  end;
  Selection.Selected := Clamp(Selection.Selected, 0, Count - 1);
  MaxTop := Count - CatalogVisibleRows;
  if MaxTop < 0 then MaxTop := 0;
  Selection.Top := Clamp(Selection.Top, 0, MaxTop);
  if Selection.Selected < Selection.Top then Selection.Top := Selection.Selected;
  if Selection.Selected >= Selection.Top + CatalogVisibleRows then
    Selection.Top := Selection.Selected - CatalogVisibleRows + 1;
end;

procedure SetCatalogDetailLineCount(var Selection: TCatalogSelection; Count: integer);
var MaxTop: integer;
begin
  if Count < 0 then Count := 0;
  Selection.DetailLineCount := Count;
  MaxTop := Count - CatalogVisibleRows;
  if MaxTop < 0 then MaxTop := 0;
  Selection.DetailTop := Clamp(Selection.DetailTop, 0, MaxTop);
end;

function BeginCatalogSourceDetails(var Selection: TCatalogSelection; LineCount: integer): boolean;
begin
  Result := not Selection.InDetails and (Selection.Selected >= 0) and
    (Selection.Selected < Selection.ResultCount);
  if not Result then Exit;
  Selection.InDetails := true;
  Selection.Focus := CatalogResultsFocus;
  Selection.DetailTop := 0;
  SetCatalogDetailLineCount(Selection, LineCount);
end;

procedure ReturnToCatalogResults(var Selection: TCatalogSelection);
begin
  Selection.InDetails := false;
  Selection.DetailTop := 0;
  Selection.DetailLineCount := 0;
  if Selection.ResultCount > 0 then Selection.Focus := CatalogResultsFocus
  else Selection.Focus := 0;
end;

function HandleCatalogNavigation(var Selection: TCatalogSelection;
  Key: TCatalogNavigationKey): TCatalogSelectionAction;
var FocusCount, Step, MaxTop: integer;
begin
  Result := caNone;
  SetCatalogResultCount(Selection, Selection.ResultCount);
  if Key = cnEscape then
  begin
    if Selection.InDetails then ReturnToCatalogResults(Selection)
    else Result := caClose;
    Exit;
  end;
  if Key = cnEnter then
  begin
    case Selection.Focus of
      0..3: Inc(Selection.Focus);
      CatalogSearchFocus: Result := caSearch;
      CatalogSignInFocus: Result := caSignIn;
      CatalogBackFocus:
        if Selection.InDetails then ReturnToCatalogResults(Selection)
        else Result := caClose;
      CatalogResultsFocus:
        if not Selection.InDetails and (Selection.Selected >= 0) and
           (Selection.Selected < Selection.ResultCount) then Result := caDetails;
    end;
    Exit;
  end;
  Step := 1;
  if Key in [cnUp, cnBackTab] then Step := -1;
  if (Selection.Focus = CatalogResultsFocus) and (Key in [cnUp, cnDown]) then
  begin
    if Selection.InDetails then
    begin
      MaxTop := Selection.DetailLineCount - CatalogVisibleRows;
      if MaxTop < 0 then MaxTop := 0;
      Selection.DetailTop := Clamp(Selection.DetailTop + Step, 0, MaxTop);
    end
    else
    begin
      Selection.Selected := Clamp(Selection.Selected + Step, 0, Selection.ResultCount - 1);
      SetCatalogResultCount(Selection, Selection.ResultCount);
    end;
    Exit;
  end;
  FocusCount := CatalogBackFocus + 1;
  if Selection.ResultCount > 0 then Inc(FocusCount);
  Selection.Focus := (Selection.Focus + Step + FocusCount) mod FocusCount;
end;

end.
