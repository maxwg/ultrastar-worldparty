program LibraryGridTest;
{$mode objfpc}{$H+}
uses ULibraryGridLayout;
var I, J, Checks: integer; A, B: TLibraryTileRect;
procedure Check(OK: boolean);
begin
  Inc(Checks); if not OK then begin WriteLn('FAIL grid layout check ', Checks); Halt(1); end;
end;
begin
  for I := 0 to LibraryGridPageSize - 1 do begin
    A := LibraryTileRect(I);
    Check((A.X >= 20) and (A.Y > 145) and (A.X + A.W < 780) and (A.Y + A.H < 500));
    Check(LibraryTileAt(A.X + A.W div 2, A.Y + A.H div 2) = I);
    Check(LibraryTileAt(A.X + A.W, A.Y + 10) = -1);
    Check(LibraryTileAt(A.X + 10, A.Y + A.H) = -1);
    for J := I + 1 to LibraryGridPageSize - 1 do begin
      B := LibraryTileRect(J);
      Check((A.X + A.W <= B.X) or (B.X + B.W <= A.X) or (A.Y + A.H <= B.Y) or (B.Y + B.H <= A.Y));
    end;
  end;
  Check(LibraryTileAt(0, 0) = -1);
  Check(LibraryTileAt(780, 580) = -1);
  WriteLn('PASS: ', Checks, ' grid bounds, overlap and hit-target assertions');
end.
