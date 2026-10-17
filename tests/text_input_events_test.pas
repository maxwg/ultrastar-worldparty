program TextInputEventsTest;
{$mode objfpc}{$H+}{$codepage utf8}
uses UTextInputEvents;
var Chars: UCS4String;
begin
  Chars := DecodeTextInput('adele');
  if (Length(Chars) <> 5) or (Chars[0] <> Ord('a')) or (Chars[4] <> Ord('e')) then Halt(1);
  Chars := DecodeTextInput('Beyoncé');
  if (Length(Chars) <> 7) or (Chars[6] <> $E9) then Halt(1);
  Chars := DecodeTextInput('A🎤Z');
  if (Length(Chars) <> 3) or (Chars[1] <> $1F3A4) or (Chars[2] <> Ord('Z')) then Halt(1);
  Chars := DecodeTextInput('mississippi');
  if Length(Chars) <> 11 then Halt(1);
  Chars := DecodeTextInput('');
  if Length(Chars) <> 0 then Halt(1);
  WriteLn('PASS: complete ASCII, accented and astral SDL text input');
end.
