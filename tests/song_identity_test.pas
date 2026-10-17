program SongIdentityTest;
{$mode objfpc}{$H+}{$codepage utf8}
uses SysUtils, USongIdentity;
procedure Check(Condition: boolean; const Why: string);
begin
  if not Condition then begin WriteLn('FAIL: ', Why); Halt(1); end;
end;
begin
  Check(SongIdentity(' ADELE ', 'Easy  on me') = SongIdentity('adele', 'Easy on me'), 'case and whitespace');
  Check(SongIdentity('4 Non Blondes', 'What’s Up') = SongIdentity('4 Non Blondes', 'What''s Up'), 'curly apostrophe');
  Check(SongIdentity('Beyoncé', 'Halo') = SongIdentity('BEYONCÉ', 'Halo'), 'Unicode case');
  Check(SongIdentity('Artist', 'Song (Live)') <> SongIdentity('Artist', 'Song'), 'keep named versions');
  Check(SongIdentity('AB', 'C') <> SongIdentity('A', 'BC'), 'unambiguous pair');
  WriteLn('PASS: 5 song identity assertions');
end.
