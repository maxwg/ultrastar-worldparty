unit ULibraryGridLayout;
{$mode objfpc}{$H+}
interface
const LibraryGridColumns = 4; LibraryGridPageSize = 12;
type TLibraryTileRect = record X, Y, W, H: integer; end;
function LibraryTileRect(Index: integer): TLibraryTileRect;
function LibraryTileAt(X, Y: integer): integer;
function LibraryGridMove(Current, Step, Count: integer): integer;
implementation
function LibraryGridMove(Current, Step, Count: integer): integer;
begin
  if Count <= 0 then Exit(0);
  if Current + Step < 0 then Exit(Count - 1);
  if Current + Step >= Count then Exit(0);
  Result := Current + Step;
end;
function LibraryTileRect(Index: integer): TLibraryTileRect;
begin
  Result.X := 42 + (Index mod LibraryGridColumns) * 184;
  Result.Y := 154 + (Index div LibraryGridColumns) * 112;
  Result.W := 174; Result.H := 104;
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
