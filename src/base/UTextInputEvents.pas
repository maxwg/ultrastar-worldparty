unit UTextInputEvents;
{$mode objfpc}{$H+}
interface
function DecodeTextInput(const Text: UTF8String): UCS4String;
implementation
uses SysUtils;
function DecodeTextInput(const Text: UTF8String): UCS4String;
begin Result := UnicodeStringToUCS4String(UTF8Decode(Text)); end;
end.
