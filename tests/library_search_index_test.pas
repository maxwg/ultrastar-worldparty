program LibrarySearchIndexTest;
{$mode objfpc}{$H+}{$codepage utf8}
uses {$IFDEF UNIX}cthreads,{$ENDIF} {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, ULibrarySearchIndex, USongIdentity, LazUTF8;
var Snapshot: TLibraryIndexEntries; Worker: TLibrarySearchIndex;
  Value: TLibraryIndexResult; I, Revision, Matches: integer; Start: QWord;
  Seen: TStringList; Key: UTF8String;
  MeasureStart, Elapsed: double;
function ClockMs: double;
{$IFDEF MSWINDOWS}var Counter, Frequency: Int64;{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  QueryPerformanceCounter(Counter); QueryPerformanceFrequency(Frequency);
  Result := Counter / Frequency * 1000;
  {$ELSE}Result := GetTickCount64;{$ENDIF}
end;
procedure ExpectQuery(const Q: UTF8String; Count: integer);
begin
  Start := GetTickCount64;
  repeat
    if Worker.TryTake(Value) then begin
      if (Value.Revision <> Revision) or (Value.Query <> Q) or
         (Length(Value.Entries) <> Count) then begin WriteLn('FAIL: stale or incorrect result'); Halt(1); end;
      Exit;
    end;
    Sleep(1);
  until GetTickCount64 - Start > 5000;
  WriteLn('FAIL: index timeout'); Halt(1);
end;
begin
  SetLength(Snapshot, 20003);
  for I := 0 to 19999 do begin
    Snapshot[I].LocalIndex := I;
    Snapshot[I].Artist := 'Artist '+IntToStr(I);
    Snapshot[I].Title := 'Title '+IntToStr(I);
  end;
  Snapshot[20000] := Snapshot[0]; // duplicate metadata
  Snapshot[20001].Title := 'Incomplete'; Snapshot[20002].Title := 'Incomplete';
  Snapshot[19998].Artist := 'Beyoncé'; Snapshot[19998].Title := 'Café';
  Seen := TStringList.Create;
  try
    Seen.Sorted := true; Seen.CaseSensitive := true; MeasureStart := ClockMs; Matches := 0;
    // Reproduce the old foreground rebuild for a comparable snapshot.
    for I := 0 to High(Snapshot) do begin
      Key := SongIdentity(Snapshot[I].Artist, Snapshot[I].Title);
      if (Trim(Snapshot[I].Artist) <> '') and (Trim(Snapshot[I].Title) <> '') then begin
        if Seen.IndexOf(string(Key)) >= 0 then Continue;
        Seen.Add(string(Key));
      end;
      if Pos('artist 19999', UTF8LowerCase(Snapshot[I].Artist + ' ' + Snapshot[I].Title)) > 0 then Inc(Matches);
    end;
    if Matches <> 1 then Halt(1);
    WriteLn('Former foreground rebuild, 20,003 charts: ', FormatFloat('0.000', ClockMs - MeasureStart), ' ms');
  finally Seen.Free; end;
  Worker := TLibrarySearchIndex.Create(Snapshot);
  try
    MeasureStart := ClockMs;
    for I := 1 to 1000 do Revision := Worker.Submit('obsolete '+IntToStr(I));
    Elapsed := ClockMs - MeasureStart;
    WriteLn('1000 latest-query submissions on UI thread: ', FormatFloat('0.000', Elapsed), ' ms');
    if Elapsed > 250 then begin WriteLn('FAIL: submission blocks'); Halt(1); end;
    Revision := Worker.Submit('Artist 19999'); ExpectQuery('Artist 19999', 1);
    if Value.Entries[0].LocalIndex <> 19999 then Halt(1);
    Revision := Worker.Submit('BEYONCÉ CAFÉ'); ExpectQuery('BEYONCÉ CAFÉ', 1);
    if Value.Entries[0].LocalIndex <> 19998 then Halt(1);
    Revision := Worker.Submit('Incomplete'); ExpectQuery('Incomplete', 2);
    Revision := Worker.Submit(''); ExpectQuery('', 20002);
    if Length(Value.Keys) <> 20000 then Halt(1);
    Revision := Worker.Submit('NO MATCH'); ExpectQuery('NO MATCH', 0);
    WriteLn('PASS: 20,003-chart snapshot, duplicate/blank policy, stale-query coalescing and exact filtering');
  finally Worker.Free; end;
end.
