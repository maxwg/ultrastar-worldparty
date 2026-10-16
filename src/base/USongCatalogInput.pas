unit USongCatalogInput;

{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}

interface

uses UUnicodeUtils;

function IsPrintableCatalogCharacter(CodePoint: UCS4Char): boolean;
procedure DeleteLastCatalogCharacter(var Value: UTF8String);
function TruncateCatalogLine(const Value: UTF8String; MaxCharacters: integer): UTF8String;
function FormatCatalogInputLine(const Prefix, Value: UTF8String;
  MaxCharacters: integer): UTF8String;

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

function FormatCatalogInputLine(const Prefix, Value: UTF8String;
  MaxCharacters: integer): UTF8String;
var
  PrefixLength, ValueLength, PrefixLimit, TailLength: integer;
  DisplayPrefix, Tail, Ellipsis: UTF8String;
begin
  if MaxCharacters <= 0 then Exit('');
  Ellipsis := UCS4ToUTF8String($2026);
  PrefixLength := LengthUTF8(Prefix);
  ValueLength := LengthUTF8(Value);
  if PrefixLength + ValueLength <= MaxCharacters then
    Exit(Prefix + Value);

  // Reserve one character for the truncation mark and at least one for the
  // current end of the input. If a translated label is too long, shorten it
  // before the marker so the user's latest input remains visible.
  if MaxCharacters = 1 then Exit(Ellipsis);
  PrefixLimit := MaxCharacters - 2;
  if PrefixLength > PrefixLimit then
    DisplayPrefix := UTF8Copy(Prefix, 1, PrefixLimit)
  else
    DisplayPrefix := Prefix;

  TailLength := MaxCharacters - LengthUTF8(DisplayPrefix) - 1;
  if TailLength > ValueLength then TailLength := ValueLength;
  Tail := '';
  if TailLength > 0 then
    Tail := UTF8Copy(Value, ValueLength - TailLength + 1, TailLength);
  Result := DisplayPrefix + Ellipsis + Tail;
end;

end.
