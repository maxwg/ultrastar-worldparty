unit ULibrarySearchIndex;
{$mode objfpc}{$H+}
interface
uses Classes, SyncObjs;
type
  TLibraryIndexEntry = record
    LocalIndex: integer;
    Artist, Title, CoverPath, Identity, MatchText: UTF8String;
  end;
  TLibraryIndexEntries = array of TLibraryIndexEntry;
  TLibraryIdentityKeys = array of UTF8String;
  TLibraryIndexResult = record
    Revision: LongInt;
    Query: UTF8String;
    Entries: TLibraryIndexEntries;
    Keys: TLibraryIdentityKeys;
  end;
  // The worker owns an immutable metadata snapshot: no song objects or OpenGL.
  // There is one pending query and one result, so typing cannot build a backlog.
  TLibrarySearchIndex = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FEntries: TLibraryIndexEntries;
    FKeys: TLibraryIdentityKeys;
    FQuery: UTF8String;
    FRevision: LongInt;
    FPending, FReady: boolean;
    FResult: TLibraryIndexResult;
    procedure BuildIndex;
  protected
    procedure Execute; override;
  public
    constructor Create(const Snapshot: TLibraryIndexEntries);
    destructor Destroy; override;
    function Submit(const Query: UTF8String): LongInt;
    function TryTake(out Value: TLibraryIndexResult): boolean;
  end;
implementation
uses SysUtils, LazUTF8, USongIdentity;
constructor TLibrarySearchIndex.Create(const Snapshot: TLibraryIndexEntries);
begin
  inherited Create(true); FreeOnTerminate := false;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, false, false, '');
  FEntries := Copy(Snapshot); Start;
end;
destructor TLibrarySearchIndex.Destroy;
begin
  Terminate;
  if Assigned(FWake) then FWake.SetEvent;
  WaitFor;
  FWake.Free; FLock.Free; inherited;
end;
function TLibrarySearchIndex.Submit(const Query: UTF8String): LongInt;
begin
  FLock.Acquire;
  try
    Result := InterlockedIncrement(FRevision);
    FQuery := Query; FPending := true; FReady := false;
  finally FLock.Release; end;
  FWake.SetEvent;
end;
function TLibrarySearchIndex.TryTake(out Value: TLibraryIndexResult): boolean;
begin
  FLock.Acquire;
  try
    Result := FReady and (FResult.Revision = FRevision);
    if Result then begin Value := FResult; FReady := false; end;
  finally FLock.Release; end;
end;
procedure TLibrarySearchIndex.BuildIndex;
var Seen: TStringList; I, N: integer; E: TLibraryIndexEntry;
begin
  Seen := TStringList.Create;
  try
    Seen.Sorted := true; Seen.CaseSensitive := true; N := 0;
    for I := 0 to High(FEntries) do begin
      if Terminated then Exit;
      E := FEntries[I]; E.Identity := '';
      if (Trim(E.Artist) <> '') and (Trim(E.Title) <> '') then begin
        E.Identity := SongIdentity(E.Artist, E.Title);
        if Seen.IndexOf(string(E.Identity)) >= 0 then Continue;
        Seen.Add(string(E.Identity));
      end;
      E.MatchText := UTF8LowerCase(E.Artist + ' ' + E.Title);
      FEntries[N] := E; Inc(N);
    end;
    SetLength(FEntries, N); SetLength(FKeys, Seen.Count);
    for I := 0 to Seen.Count - 1 do FKeys[I] := UTF8String(Seen[I]);
  finally Seen.Free; end;
end;
procedure TLibrarySearchIndex.Execute;
var Output: TLibraryIndexResult; Q: UTF8String; I, N: integer; Pending: boolean;
begin
  BuildIndex;
  while not Terminated do begin
    FLock.Acquire;
    try
      Pending := FPending;
      if Pending then begin
        Output.Query := FQuery; Output.Revision := FRevision; FPending := false;
      end;
    finally FLock.Release; end;
    if not Pending then begin FWake.WaitFor(100); Continue; end;
    Q := UTF8LowerCase(Trim(Output.Query));
    SetLength(Output.Entries, Length(FEntries)); N := 0;
    for I := 0 to High(FEntries) do begin
      if ((I and 127) = 0) and (Terminated or
         (InterlockedCompareExchange(FRevision, 0, 0) <> Output.Revision)) then Break;
      if (Q = '') or (Pos(Q, FEntries[I].MatchText) > 0) then begin
        Output.Entries[N] := FEntries[I]; Inc(N);
      end;
    end;
    SetLength(Output.Entries, N); Output.Keys := FKeys;
    FLock.Acquire;
    try
      if not Terminated and (Output.Revision = FRevision) then begin
        FResult := Output; FReady := true;
      end;
    finally FLock.Release; end;
    // The next scan must not mutate the array handed to the UI.
    Output.Entries := nil;
  end;
end;
end.
