program AdvancedOptionsLayoutTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  UAdvancedOptionsLayout;

const
  OptionRowCount = 10;
  { Values from Argon.ini's OptionsButtonExit2 theme dimensions/position. }
  ThemeButtonX = 70;
  ThemeButtonY = 440;
  ThemeButtonWidth = 250;
  ThemeButtonHeight = 40;

var
  Row, OtherRow, ExitY, Assertions: Integer;
  RaisedForUnfitLayout: Boolean;

procedure Check(Value: Boolean; const MessageText: string);
begin
  Inc(Assertions);
  if not Value then
  begin
    WriteLn('FAIL: ', MessageText);
    Halt(1);
  end;
end;

function RectanglesDoNotOverlap(TopA, HeightA, TopB, HeightB: Integer): Boolean;
begin
  Result := (TopA + HeightA <= TopB) or (TopB + HeightB <= TopA);
end;

begin
  Assertions := 0;
  Check((ThemeButtonX >= 0) and
    (ThemeButtonX + ThemeButtonWidth <= AdvancedOptionsViewportWidth),
    'theme exit button stays within 800px viewport width');

  for Row := 0 to OptionRowCount - 1 do
  begin
    Check((AdvancedOptionsRowTop(Row) >= 0) and
      (AdvancedOptionsRowTop(Row) + AdvancedOptionsRowHeight <= AdvancedOptionsViewportHeight),
      'row ' + IntToStr(Row) + ' stays within 600px viewport height');
    for OtherRow := 0 to Row - 1 do
      Check(RectanglesDoNotOverlap(AdvancedOptionsRowTop(OtherRow), AdvancedOptionsRowHeight,
        AdvancedOptionsRowTop(Row), AdvancedOptionsRowHeight),
        'rows ' + IntToStr(OtherRow) + ' and ' + IntToStr(Row) + ' do not overlap');
  end;

  ExitY := AdvancedOptionsExitTop(OptionRowCount, ThemeButtonHeight, ThemeButtonY);
  Check(ExitY >= 0, 'exit button position is feasible');
  Check(ExitY + ThemeButtonHeight <= AdvancedOptionsViewportHeight,
    'exit button stays within 600px viewport height');
  for Row := 0 to OptionRowCount - 1 do
    Check(RectanglesDoNotOverlap(AdvancedOptionsRowTop(Row), AdvancedOptionsRowHeight,
      ExitY, ThemeButtonHeight),
      'exit button does not overlap row ' + IntToStr(Row));

  RaisedForUnfitLayout := False;
  try
    AdvancedOptionsExitTop(20, ThemeButtonHeight, ThemeButtonY);
  except
    on E: ERangeError do
      RaisedForUnfitLayout := True;
  end;
  Check(RaisedForUnfitLayout, 'an infeasible layout fails loudly instead of placing Exit at -1');

  WriteLn('PASS: ', Assertions, ' Advanced options layout assertions');
end.
