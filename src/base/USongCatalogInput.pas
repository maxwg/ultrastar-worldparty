unit USongCatalogInput;

{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}

interface

uses UUnicodeUtils;

function IsPrintableCatalogCharacter(CodePoint: UCS4Char): boolean;
procedure DeleteLastCatalogCharacter(var Value: UTF8String);
function TruncateCatalogLine(const Value: UTF8String; MaxCharacters: integer): UTF8String;

implementation

function IsPrintableCatalogCharacter(CodePoint: UCS4Char): boolean;
var Scalar: LongInt;
begin
  Scalar := LongInt(CodePoint);
  Result := (Scalar >= 32) and (Scalar <= 1114111) and
    not ((Scalar >= 127) and (Scalar <= 159)) and
    not ((Scalar >= 55296) and (Scalar <= 57343));
end;

procedure DeleteLastCatalogCharacter(var Value: UTF8String);
begin
  if LengthUTF8(Value) > 0 then UTF8Delete(Value, LengthUTF8(Value), 1);
end;

function TruncateCatalogLine(const Value: UTF8String; MaxCharacters: integer): UTF8String;
begin
  if MaxCharacters <= 0 then Exit('');
  if LengthUTF8(Value) > MaxCharacters then
    Result := UTF8Copy(Value, 1, MaxCharacters)
  else
    Result := Value;
end;

end.
