unit UAdvancedOptionsLayout;

{$IFDEF FPC}
  {$MODE OBJFPC}
{$ENDIF}

interface

const
  AdvancedOptionsViewportWidth = 800;
  AdvancedOptionsViewportHeight = 600;
  AdvancedOptionsFirstRowY = 90;
  AdvancedOptionsRowStride = 42;
  AdvancedOptionsRowHeight = 38;
  AdvancedOptionsExitGap = 8;
  AdvancedOptionsBottomMargin = 15;

function AdvancedOptionsRowTop(Row: Integer): Integer;
function AdvancedOptionsExitTop(RowCount, ButtonHeight, ThemeY: Integer): Integer;

implementation

uses
  SysUtils;

function AdvancedOptionsRowTop(Row: Integer): Integer;
begin
  if Row < 0 then
    raise ERangeError.Create('Advanced option row must be non-negative');
  Result := AdvancedOptionsFirstRowY + Row * AdvancedOptionsRowStride;
end;

function AdvancedOptionsExitTop(RowCount, ButtonHeight, ThemeY: Integer): Integer;
var
  LastRowBottom, MinTop, MaxTop: Integer;
begin
  if (RowCount < 0) or (ButtonHeight < 0) then
    raise ERangeError.Create('Advanced option row count and button height must be non-negative');

  if RowCount = 0 then
    LastRowBottom := AdvancedOptionsFirstRowY - AdvancedOptionsExitGap
  else
    LastRowBottom := AdvancedOptionsRowTop(RowCount - 1) + AdvancedOptionsRowHeight;

  MinTop := LastRowBottom + AdvancedOptionsExitGap;
  MaxTop := AdvancedOptionsViewportHeight - ButtonHeight - AdvancedOptionsBottomMargin;
  if MinTop > MaxTop then
    raise ERangeError.Create('Advanced options rows and exit button do not fit in the 600px viewport');

  Result := ThemeY;
  if Result < MinTop then
    Result := MinTop;
  if Result > MaxTop then
    Result := MaxTop;
end;

end.
