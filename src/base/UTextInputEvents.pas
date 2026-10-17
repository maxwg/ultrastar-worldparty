unit UTextInputEvents;
{$mode objfpc}{$H+}
interface
function DecodeTextInput(const Text: UTF8String): UCS4String;
implementation
uses SysUtils;
function DecodeTextInput(const Text: UTF8String): UCS4String;
begin
  Result := UnicodeStringToUCS4String(UTF8Decode(Text));
  // FPC includes the C-style terminator; it is not a committed character.
  if (Length(Result) > 0) and (Result[High(Result)] = 0) then
    SetLength(Result, Length(Result) - 1);
end;
end.
