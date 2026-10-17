unit USongIdentity;
{$mode objfpc}{$H+}
interface
function SongIdentity(const Artist, Title: UTF8String): UTF8String;
implementation
uses SysUtils, LazUTF8;
function Normalized(const Value: UTF8String): UTF8String;
var I: integer; S: UTF8String; Space: boolean;
begin
  S := UTF8LowerCase(Trim(Value));
  S := StringReplace(S, #$E2#$80#$99, '''', [rfReplaceAll]);
  S := StringReplace(S, #$E2#$80#$98, '''', [rfReplaceAll]);
  S := StringReplace(S, #$C2#$A0, ' ', [rfReplaceAll]);
  Result := ''; Space := false;
  for I := 1 to Length(S) do
    if S[I] in [#9, #10, #13, ' '] then Space := Result <> ''
    else begin
      if Space then Result := Result + ' ';
      Result := Result + S[I]; Space := false;
    end;
end;
function SongIdentity(const Artist, Title: UTF8String): UTF8String;
begin
  Result := Normalized(Artist) + #9 + Normalized(Title);
end;
end.
