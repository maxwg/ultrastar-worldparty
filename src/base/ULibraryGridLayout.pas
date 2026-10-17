unit ULibraryGridLayout;
{$mode objfpc}{$H+}
interface
const LibraryGridColumns = 4; LibraryGridPageSize = 8;
type TLibraryTileRect = record X, Y, W, H: integer; end;
function LibraryTileRect(Index: integer): TLibraryTileRect;
function LibraryTileAt(X, Y: integer): integer;
implementation
function LibraryTileRect(Index: integer): TLibraryTileRect;
begin
  Result.X := 42 + (Index mod LibraryGridColumns) * 184;
  Result.Y := 216 + (Index div LibraryGridColumns) * 146;
  Result.W := 174; Result.H := 126;
end;
function LibraryTileAt(X, Y: integer): integer;
var I: integer; R: TLibraryTileRect;
begin
  Result := -1;
  for I := 0 to LibraryGridPageSize - 1 do begin
    R := LibraryTileRect(I);
    if (X >= R.X) and (X < R.X + R.W) and (Y >= R.Y) and (Y < R.Y + R.H) then Exit(I);
  end;
end;
end.
