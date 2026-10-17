unit USongCatalogBridge;

{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}

interface

uses Classes, SysUtils, Variants;

type
  TCatalogSearchResult = record
    SongID: Int64;
    Artist, Title, Language: UTF8String;
  end;
  TCatalogSearchResults = array of TCatalogSearchResult;

  TCatalogTransport = class
  public
    procedure Start(const PythonPath, AdapterPath: string; const CredentialsPath: string = ''); virtual; abstract;
    procedure SendLine(const Line: UTF8String); virtual; abstract;
    function ReadAvailable(MaxBytes: integer): UTF8String; virtual; abstract;
    function Running: boolean; virtual; abstract;
    procedure TerminateOwned; virtual; abstract;
    function FailureMessage: string; virtual; abstract;
  end;

  TCatalogProcessTransport = class(TCatalogTransport)
  private
    FProcess: TObject;
    FEnableDownloads: boolean;
    FStarted: boolean;
    FTerminated: boolean;
    FWriteQueue: UTF8String;
    FFailureMessage: string;
    FReaperState: Pointer;
    FReaperThreadID: PtrInt;
    FChildPID: integer;
    procedure PumpWrites;
    procedure SetFailure(const MessageText: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(const PythonPath, AdapterPath: string; const CredentialsPath: string = ''); override;
    procedure SendLine(const Line: UTF8String); override;
    function ReadAvailable(MaxBytes: integer): UTF8String; override;
    function Running: boolean; override;
    procedure TerminateOwned; override;
    function FailureMessage: string; override;
    function OwnedProcessID: integer;
    property EnableDownloads: boolean read FEnableDownloads write FEnableDownloads;
  end;

  TCatalogSession = class
  private
    FTransport: TCatalogTransport;
    FOwnsTransport: boolean;
    FInputBuffer: UTF8String;
    FNextID: integer;
    FPendingID: string;
    FPendingOp: string;
    FClosingID: string;
    FClosingTarget: string;
    FBusy: boolean;
    FClosing: boolean;
    FAuthenticated: boolean;
    FSessionReady: boolean;
    FDetailsCapability: boolean;
    FDownloadCapability: boolean;
    FAllowDownloads: boolean;
    FInstalledFolder, FInstallRoot: string;
    FInstallReceived: boolean;
    FCredentialsPath: string;
    FStatus: UTF8String;
    FErrorCode: string;
    FResults: TStringList;
    FResultItems: TCatalogSearchResults;
    FDetailLinks: TStringList;
    FDetailSongID, FPendingSongID: Int64;
    FDetailReceived: boolean;
    FPendingDeadline: QWord;
    FCloseDeadline: QWord;
    function NewRequestID: string;
    function SendRequest(const Op: string; Fields: TStrings; SongID: Int64 = 0): string;
    function CanStartRequest: boolean;
    function GetResultCount: integer;
    function GetResultItem(Index: integer): TCatalogSearchResult;
    procedure ClearResults;
    procedure ClearDetails;
    procedure ReceiveLine(const Line: UTF8String);
    procedure FailProtocol(const MessageText: string);
    procedure FinishPending(const MessageText: string; const Code: string);
    function GetHelperRunning: boolean;
  public
    constructor Create(Transport: TCatalogTransport; OwnsTransport: boolean = false);
    destructor Destroy; override;
    function Start(const PythonPath, AdapterPath: string; const CredentialsPath: string = ''): boolean;
    function Login(const Username, Password: UTF8String): boolean;
    function LoginStored: boolean;
    function Search(const Artist, Title: UTF8String; const Query: UTF8String = ''): boolean;
    function Details(SongID: Int64): boolean;
    function DownloadSong(SongID: Int64; const URL, Root: string): boolean;
    property AllowDownloads: boolean read FAllowDownloads write FAllowDownloads;
    property InstalledFolder: string read FInstalledFolder;
    procedure Close;
    procedure ForceTerminate;
    procedure Poll;
    procedure PollAt(NowMs: QWord);
    property Status: UTF8String read FStatus;
    property ErrorCode: string read FErrorCode;
    property Authenticated: boolean read FAuthenticated;
    property DownloadsEnabled: boolean read FDownloadCapability;
    property StoredCredentials: string read FCredentialsPath;
    property Busy: boolean read FBusy;
    property Closing: boolean read FClosing;
    property HelperRunning: boolean read GetHelperRunning;
    property Results: TStringList read FResults;
    property ResultCount: integer read GetResultCount;
    property ResultItems[Index: integer]: TCatalogSearchResult read GetResultItem;
    property DetailsSupported: boolean read FDetailsCapability;
    property DetailSongID: Int64 read FDetailSongID;
    property DetailLinks: TStringList read FDetailLinks;
  end;

function IsAbsoluteCatalogPath(const Value: string): boolean;
function CatalogConfigurationReady(const PythonPath, AdapterPath: string): boolean;

implementation

uses fpjson, jsonparser
  {$IFDEF FPC}, Process, Pipes{$ENDIF}
  {$IFDEF UNIX}, BaseUnix{$ENDIF}
  {$IFDEF MSWINDOWS}, Windows{$ENDIF};

{$IFDEF LINUX}
type
  // Linux libc sigset_t is 128 bytes. FPC 3.2.2's fpSigPending wrapper omits
  // the required kernel sigset-size argument, so use the libc thread-scoped
  // signal APIs with an ABI-sized opaque set here.
  TCatalogSignalSet = array[0..15] of QWord;

function CSignalEmptySet(var SignalSet: TCatalogSignalSet): cint; cdecl; external 'c' name 'sigemptyset';
function CSignalAddSet(var SignalSet: TCatalogSignalSet; SignalNumber: cint): cint; cdecl; external 'c' name 'sigaddset';
function CSignalIsMember(const SignalSet: TCatalogSignalSet; SignalNumber: cint): cint; cdecl; external 'c' name 'sigismember';
function CThreadSignalMask(How: cint; NewMask, OldMask: Pointer): cint; cdecl; external 'c' name 'pthread_sigmask';
function CSignalPending(var SignalSet: TCatalogSignalSet): cint; cdecl; external 'c' name 'sigpending';
function CSignalTimedWait(const SignalSet: TCatalogSignalSet; Info: Pointer; Timeout: Pointer): cint; cdecl; external 'c' name 'sigtimedwait';

type
  PCatalogReaperState = ^TCatalogReaperState;
  TCatalogReaperState = record
    PID: cint;
    StopBeforeStart: LongInt;
    Done: LongInt;
    RefCount: LongInt;
    ProcessLock: LongInt;
  end;

procedure LockCatalogProcess(State: PCatalogReaperState);
begin
  while InterlockedCompareExchange(State^.ProcessLock, 1, 0) <> 0 do Sleep(0);
end;

procedure UnlockCatalogProcess(State: PCatalogReaperState);
begin
  InterlockedExchange(State^.ProcessLock, 0);
end;

function CatalogChildReaper(Parameter: Pointer): PtrInt;
var
  State: PCatalogReaperState;
  PID, WaitResult, ExitStatus: cint;
  Reaped: boolean;
begin
  State := PCatalogReaperState(Parameter);
  repeat
    PID := InterlockedCompareExchange(State^.PID, 0, 0);
    if PID <= 0 then
    begin
      if InterlockedCompareExchange(State^.StopBeforeStart, 0, 0) <> 0 then Break;
      Sleep(5);
      Continue;
    end;
    repeat
      ExitStatus := 0;
      // Serialize waitpid's reap with the UI thread's final exact-PID kill.
      // The syscall is WNOHANG; the lock is never held across a blocking wait.
      LockCatalogProcess(State);
      WaitResult := fpWaitPid(PID, @ExitStatus, WNOHANG);
      Reaped := (WaitResult = PID) or ((WaitResult < 0) and (fpgeterrno <> ESysEINTR));
      if Reaped then InterlockedExchange(State^.Done, 1);
      UnlockCatalogProcess(State);
      if Reaped then Break;
      Sleep(10);
    until false;
    Break;
  until false;
  if InterlockedDecrement(State^.RefCount) = 0 then Dispose(State);
  Result := 0;
end;
{$ENDIF}

const
  CMaxFrame = 65536;
  CMaxOutbound = 65536;
  CMaxResults = 30;
  CMaxSourceLinks = 30;
  CStatusTimeoutMs = 10000;
  COperationTimeoutMs = 60000;
  CCloseTimeoutMs = 2000;

function IsAbsoluteCatalogPath(const Value: string): boolean;
begin
  Result := false;
  if Value = '' then Exit;
  {$IFDEF MSWINDOWS}
  Result := ((Length(Value) >= 3) and (Value[2] = ':') and
             (Value[3] in ['\', '/'])) or
            ((Length(Value) >= 2) and (Value[1] = '\') and (Value[2] = '\'));
  {$ELSE}
  Result := Value[1] = '/';
  {$ENDIF}
end;

function CatalogConfigurationReady(const PythonPath, AdapterPath: string): boolean;
begin
  Result := (PythonPath <> '') and (AdapterPath <> '') and
            IsAbsoluteCatalogPath(PythonPath) and IsAbsoluteCatalogPath(AdapterPath) and
            FileExists(PythonPath) and FileExists(AdapterPath);
end;

// Only the shape of the credentials path is validated here. Missing files,
// bad JSON payloads, or unusable fields surface through the adapter's error
// events so secret values never travel through status strings.
function CatalogStoredCredentialsReady(const CredentialsPath: string): boolean;
begin
  Result := (CredentialsPath <> '') and IsAbsoluteCatalogPath(CredentialsPath) and
            FileExists(CredentialsPath);
end;


function UTF8ScalarEncode(OutText: PUTF8String; CP: UInt32): integer;
begin
  Result := 0;
  if CP < $80 then
  begin
    OutText^ := OutText^ + UTF8String(AnsiChar(Byte(CP)));
    Result := 1;
  end
  else if CP < $800 then
  begin
    OutText^ := OutText^ + UTF8String(AnsiChar(Byte($C0 or (CP shr 6)))) +
                UTF8String(AnsiChar(Byte($80 or (CP and $3F))));
    Result := 2;
  end
  else if CP < $10000 then
  begin
    OutText^ := OutText^ + UTF8String(AnsiChar(Byte($E0 or (CP shr 12)))) +
                UTF8String(AnsiChar(Byte($80 or ((CP shr 6) and $3F)))) +
                UTF8String(AnsiChar(Byte($80 or (CP and $3F))));
    Result := 3;
  end
  else
  begin
    OutText^ := OutText^ + UTF8String(AnsiChar(Byte($F0 or (CP shr 18)))) +
                UTF8String(AnsiChar(Byte($80 or ((CP shr 12) and $3F)))) +
                UTF8String(AnsiChar(Byte($80 or ((CP shr 6) and $3F)))) +
                UTF8String(AnsiChar(Byte($80 or (CP and $3F))));
    Result := 4;
  end;
end;

function CatalogHexValue(const Chars: UTF8String; Index: integer; out Value: UInt32): boolean;
var I, N: integer; Ch: AnsiChar;
begin
  Result := false;
  Value := 0;
  N := Length(Chars);
  for I := 0 to 3 do
  begin
    if Index + I > N then Exit;
    Ch := Chars[Index + I];
    case Ch of
      '0'..'9': Value := Value shl 4 or (Byte(Ord(Ch)) - Byte(Ord('0')));
      'a'..'f': Value := Value shl 4 or (Byte(Ord(Ch)) - Byte(Ord('a')) + 10);
      'A'..'F': Value := Value shl 4 or (Byte(Ord(Ch)) - Byte(Ord('A')) + 10);
      else Exit;
    end;
  end;
  Result := true;
end;

procedure CatalogUnescapeJSONUnicode(var Line: UTF8String);
// FPC 3.2.2 Win32 jsonparser turns an escaped \u00E9 into '?' and raw UTF-8
// bytes into mojibake. Pre-decode escapes for codepoints above U+007F into
// real UTF-8 bytes so the parser only ever sees ASCII; keep ASCII-range
// escapes (quotes, backslashes, control characters) untouched. Surrogate
// pairs follow the JSON spec; lone surrogates become U+FFFD.
var
  I, N: integer;
  OutText: UTF8String;
  Low, High: UInt32;
  Temp: UTF8String;
begin
  N := Length(Line);
  I := 1;
  OutText := '';
  while I <= N do
  begin
    if (Line[I] <> '\') or (I + 5 > N) or (Line[I+1] <> 'u') then
    begin
      OutText := OutText + UTF8String(Line[I]);
      Inc(I);
      Continue;
    end;
    if not CatalogHexValue(Line, I + 2, High) then
    begin
      OutText := OutText + UTF8String(Line[I]);
      Inc(I);
      Continue;
    end;
    if High < $80 then // ASCII-range escapes stay for the parser to decode.
    begin
      OutText := OutText + UTF8String(Copy(Line, I, 6));
      Inc(I, 6);
      Continue;
    end;
    if (High >= $D800) and (High < $E000) then
    begin
      // surrogate: require the matching complementary escape
      if (I + 11 <= N) and (Line[I+6] = '\') and (Line[I+7] = 'u') and
         CatalogHexValue(Line, I + 8, Low) and
         (((High >= $D800) and (High < $DC00) and (Low >= $DC00) and (Low < $E000)) or
          ((High >= $DC00) and (High < $E000) and (Low >= $D800) and (Low < $DC00))) then
      begin
        Temp := '';
        UTF8ScalarEncode(@Temp, $10000 + ((High - $D800) shl 10) + (Low - $DC00));
        OutText := OutText + Temp;
        Inc(I, 12);
      end
      else
      begin
        Temp := '';
        UTF8ScalarEncode(@Temp, $FFFD);
        OutText := OutText + Temp;
        Inc(I, 6);
      end;
      Continue;
    end;
    Temp := '';
    UTF8ScalarEncode(@Temp, High);
    OutText := OutText + Temp;
    Inc(I, 6);
  end;
  Line := OutText;
end;

function UTF8ScalarDecode(const Chars: UTF8String; var Index: integer; out CP: UInt32): boolean;
var
  N, Extra, K: integer;
  C0: Byte;
begin
  Result := false;
  CP := 0;
  N := Length(Chars);
  if Index > N then Exit(false);
  C0 := Byte(Ord(Chars[Index]));
  if (C0 and $80) = 0 then
  begin
    CP := C0; Extra := 0; Inc(Index);
  end
  else if (C0 and $E0) = $C0 then begin CP := C0 and $1F; Extra := 1; end
  else if (C0 and $F0) = $E0 then begin CP := C0 and $0F; Extra := 2; end
  else if (C0 and $F8) = $F0 then begin CP := C0 and $07; Extra := 3; end
  else Exit(false); // invalid leading byte
  if Extra > 0 then
  begin
    for K := 1 to Extra do
    begin
      if Index + K > N then Exit(false);
      if (Byte(Ord(Chars[Index + K])) and $C0) <> $80 then Exit(false);
      CP := (CP shl 6) or (Byte(Ord(Chars[Index + K])) and $3F);
    end;
    Inc(Index, Extra + 1);
  end;
  Result := true;
end;

function CatalogOutEscape(const Value: UTF8String): UTF8String;
// Encode a UTF-8 string into an ASCII-only JSON string body on the wire.
// Requests carry only pure-ASCII text on Windows ANSI runtimes where typed
// string values would otherwise convert bytes through the system codepage.
// BMP codepoints become \uXXXX escapes; astral codepoints become surrogate
// pairs; ASCII quotes, backslashes, and control characters get JSON escapes.
var
  I: integer;
  CP, High, Low: UInt32;
  Body: UTF8String;
begin
  I := 1;
  Body := '';
  while I <= Length(Value) do
  begin
    if not UTF8ScalarDecode(Value, I, CP) then
    begin
      Body := Body + UTF8String(Copy(Value, I, 1));
      Inc(I);
      Continue;
    end;
    if CP = $22 then
      Body := Body + UTF8String('\"')
    else if CP = $5C then
      Body := Body + UTF8String('\\')
    else if (CP < $20) or (CP = $7F) then
      Body := Body + UTF8String('\u' + IntToHex(CP, 4))
    else if CP < $80 then
      Body := Body + UTF8String(AnsiChar(Byte(CP)))
    else if CP < $10000 then
      Body := Body + UTF8String('\u' + IntToHex(CP, 4))
    else
    begin
      High := $D800 + ((CP - $10000) shr 10);
      Low := $DC00 + ((CP - $10000) and $3FF);
      Body := Body + UTF8String('\u' + IntToHex(High, 4)) + UTF8String('\u' + IntToHex(Low, 4));
    end;
  end;
  Result := Body;
end;


function JSONString(Obj: TJSONObject; const Key: string; out Value: UTF8String): boolean;
var D: TJSONData; RawValue: Variant;
begin
  Value := '';
  D := Obj.Find(Key);
  Result := Assigned(D) and (D.JSONType = jtString);
  // The parser stores string values as UTF-8 bytes tagged CP_UTF8; reading
  // them through the Variant property keeps those bytes without an ANSI
  // codepage round trip.
  if Result then
  begin
    RawValue := TJSONString(D).Value;
    Value := UTF8String(RawValue);
  end;
end;

function JSONInteger(Obj: TJSONObject; const Key: string; out Value: Int64): boolean;
var D: TJSONData;
begin
  Value := 0;
  D := Obj.Find(Key);
  Result := Assigned(D) and
            ((D is TJSONIntegerNumber) or (D is TJSONInt64Number));
  if Result then Value := D.AsInt64;
end;

function JSONBoolean(Obj: TJSONObject; const Key: string; out Value: boolean): boolean;
var D: TJSONData;
begin
  Value := false;
  D := Obj.Find(Key);
  Result := Assigned(D) and (D.JSONType = jtBoolean);
  if Result then Value := D.AsBoolean;
end;

function CloseTargetMatches(Obj: TJSONObject; const Expected: string): boolean;
var D: TJSONData;
    Actual: UTF8String;
begin
  D := Obj.Find('target_request_id');
  if not Assigned(D) then Exit(false);
  if D.JSONType = jtNull then Exit(true); // operation may finish before quit is read
  Result := (D.JSONType = jtString) and (Expected <> '') and
            JSONString(Obj, 'target_request_id', Actual) and (Actual = Expected);
end;

function IsCatalogSourceLink(const Value: string): boolean;
const Prefix = 'https://www.youtube.com/watch?v=';
var I: integer;
begin
  // song_catalog.media_links normalizes watch/embed/youtu.be sources to this
  // exact URL form. Never turn arbitrary helper strings into actionable links.
  Result := false;
  if (Length(Value) <> Length(Prefix) + 11) or
     (Copy(Value, 1, Length(Prefix)) <> Prefix) then Exit;
  for I := Length(Prefix) + 1 to Length(Value) do
    if not (Value[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then Exit;
  Result := true;
end;

{ TCatalogProcessTransport }

constructor TCatalogProcessTransport.Create;
{$IFDEF LINUX}
var State: PCatalogReaperState;
{$ENDIF}
begin
  inherited Create;
  {$IFDEF LINUX}
  New(State);
  FillChar(State^, SizeOf(State^), 0);
  State^.RefCount := 1; // transport ownership
  FReaperState := State;
  InterlockedIncrement(State^.RefCount); // reaper thread ownership
  FReaperThreadID := PtrInt(BeginThread(@CatalogChildReaper, State));
  if FReaperThreadID = 0 then
  begin
    InterlockedDecrement(State^.RefCount);
    InterlockedExchange(State^.StopBeforeStart, 1);
    SetFailure('Catalog child reaper could not start.');
  end;
  {$ENDIF}
end;

destructor TCatalogProcessTransport.Destroy;
begin
  TerminateOwned;
  if Assigned(FProcess) then
    FProcess.Free;
  {$IFDEF LINUX}
  if Assigned(FReaperState) then
  begin
    InterlockedExchange(PCatalogReaperState(FReaperState)^.StopBeforeStart, 1);
    if InterlockedDecrement(PCatalogReaperState(FReaperState)^.RefCount) = 0 then
      Dispose(PCatalogReaperState(FReaperState));
    FReaperState := nil;
  end;
  {$ENDIF}
  inherited Destroy;
end;

procedure TCatalogProcessTransport.SetFailure(const MessageText: string);
begin
  if FFailureMessage = '' then FFailureMessage := MessageText;
end;

function TCatalogProcessTransport.FailureMessage: string;
begin
  Result := FFailureMessage;
end;

function TCatalogProcessTransport.OwnedProcessID: integer;
begin
  {$IFDEF FPC}
  if FStarted and Assigned(FProcess) then Result := TProcess(FProcess).Handle
  else Result := 0;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

procedure TCatalogProcessTransport.Start(const PythonPath, AdapterPath: string; const CredentialsPath: string);
{$IFDEF FPC}
var
  P: TProcess;
  {$IFDEF LINUX}Flags: cint;{$ENDIF}
  {$IFDEF MSWINDOWS}PipeMode: DWORD;{$ENDIF}
{$ENDIF}
begin
  if FStarted then
    raise Exception.Create('Catalog helper has already been started.');
  if not CatalogConfigurationReady(PythonPath, AdapterPath) then
    raise Exception.Create('Catalog helper setup is unavailable.');
  {$IFDEF LINUX}
  if (FReaperThreadID = 0) or (FFailureMessage <> '') then
    raise Exception.Create('Catalog child reaper is unavailable.');
  {$ENDIF}
  {$IFDEF FPC}
  P := TProcess.Create(nil);
  try
    P.Executable := PythonPath;
    P.Parameters.Add('-I');
    P.Parameters.Add('-S');
    P.Parameters.Add('-B');
    P.Parameters.Add(AdapterPath);
    if FEnableDownloads then P.Parameters.Add('--enable-downloads');
    if CredentialsPath <> '' then
    begin
      // Optional sign-in file. The adapter rejects relative or unreadable
      // paths over its own protocol, so no secret ever lands in a status.
      P.Parameters.Add('--credentials');
      P.Parameters.Add(CredentialsPath);
    end;
    P.Options := [poUsePipes, poNoConsole, poNewProcessGroup];
    P.Execute;
    {$IFDEF LINUX}
    // Publish the PID to the already-running reaper before any later setup
    // step can fail. The monitor is the sole waitpid owner for this process.
    FProcess := P;
    FStarted := true;
    FChildPID := P.Handle;
    InterlockedExchange(PCatalogReaperState(FReaperState)^.PID, FChildPID);
    {$ENDIF}
    // Every write is nonblocking. Fail closed if the platform cannot provide
    // that property; UI code never falls back to WriteBuffer.
    {$IFDEF LINUX}
    Flags := fpfcntl(P.Input.Handle, F_GETFL);
    if (Flags < 0) or (fpfcntl(P.Input.Handle, F_SETFL, Flags or O_NONBLOCK) < 0) then
      raise Exception.Create('Catalog input pipe cannot be made nonblocking.');
    {$ELSE}
    {$IFDEF MSWINDOWS}
    PipeMode := PIPE_NOWAIT;
    if not SetNamedPipeHandleState(P.Input.Handle, @PipeMode, nil, nil) then
      raise Exception.Create('Catalog input pipe does not support PIPE_NOWAIT.');
    {$ELSE}
    raise Exception.Create('Catalog helper transport is unavailable on this platform.');
    {$ENDIF}
    {$ENDIF}
    {$IFNDEF LINUX}
    FProcess := P;
    FStarted := true;
    {$ENDIF}
  except
    {$IFDEF LINUX}
    if FStarted then TerminateOwned else P.Free;
    {$ELSE}
    {$IFDEF UNIX}if P.Running then fpKill(P.Handle, SIGKILL);{$ENDIF}
    {$IFDEF MSWINDOWS}if P.Running then Windows.TerminateProcess(P.Handle, 1);{$ENDIF}
    P.Free;
    {$ENDIF}
    raise;
  end;
  {$ELSE}
  raise Exception.Create('Catalog helper is unavailable in this build.');
  {$ENDIF}
end;

procedure TCatalogProcessTransport.SendLine(const Line: UTF8String);
var Payload: UTF8String;
begin
  if not FStarted or not Running then
    raise Exception.Create('Catalog helper is not running.');
  Payload := Line + #10;
  if Length(Payload) > CMaxFrame then
    raise Exception.Create('Catalog request exceeded the size limit.');
  if Length(FWriteQueue) + Length(Payload) > CMaxOutbound then
    raise Exception.Create('Catalog helper output queue is full.');
  FWriteQueue := FWriteQueue + Payload;
end;

procedure TCatalogProcessTransport.PumpWrites;
{$IFDEF FPC}
var
  P: TProcess;
  N, W: integer;
  B: array[0..4095] of byte;
  {$IFDEF LINUX}
  SigSet, OldMask, PendingSet: TCatalogSignalSet;
  Timeout: TTimeSpec;
  WasPending: boolean;
  KeepBlocked: boolean;
  WaitResult, WriteError, MaskResult: cint;
  {$ENDIF}
  {$IFDEF MSWINDOWS}Written: DWORD; Ok: BOOL; Err: DWORD;{$ENDIF}
{$ENDIF}
begin
  {$IFDEF FPC}
  if (not FStarted) or (FWriteQueue = '') then Exit;
  if not Running then
  begin SetFailure('Catalog helper exited before requests were written.'); Exit; end;
  P := TProcess(FProcess);
  N := Length(FWriteQueue);
  if N > SizeOf(B) then N := SizeOf(B);
  {$IFDEF LINUX}
  Move(FWriteQueue[1], B[0], N);
  if (CSignalEmptySet(SigSet) <> 0) or (CSignalAddSet(SigSet, SIGPIPE) <> 0) then
  begin SetFailure('Catalog helper pipe signal handling is unavailable.'); Exit; end;
  if CThreadSignalMask(SIG_BLOCK, @SigSet, @OldMask) <> 0 then
  begin SetFailure('Catalog helper pipe signal handling is unavailable.'); Exit; end;
  KeepBlocked := false;
  try
    if CSignalPending(PendingSet) <> 0 then
    begin
      W := -1;
      WriteError := fpgeterrno;
    end
    else
    begin
      WasPending := CSignalIsMember(PendingSet, SIGPIPE) = 1;
      W := fpWrite(P.Input.Handle, B[0], N);
      WriteError := fpgeterrno;
      if (W < 0) and (WriteError = ESysEPIPE) and not WasPending then
      begin
        Timeout.tv_sec := 0;
        Timeout.tv_nsec := 0;
        repeat
          WaitResult := CSignalTimedWait(SigSet, nil, @Timeout);
        until (WaitResult >= 0) or (fpgeterrno <> ESysEINTR);
        if (WaitResult < 0) and (CSignalPending(PendingSet) = 0) and
           (CSignalIsMember(PendingSet, SIGPIPE) = 1) then
          KeepBlocked := true;
      end;
    end;
  finally
    if KeepBlocked then MaskResult := -1
    else MaskResult := CThreadSignalMask(SIG_SETMASK, @OldMask, nil);
  end;
  if MaskResult <> 0 then
  begin SetFailure('Catalog helper pipe signal could not be safely restored.'); Exit; end;
  if W < 0 then
  begin
    if (WriteError = ESysEAGAIN) or (WriteError = ESysEINTR) then Exit;
    SetFailure('Catalog helper input pipe failed.');
    Exit;
  end;
  {$ELSE}
  {$IFDEF UNIX}
  SetFailure('Safe catalog pipe writes are unavailable on this POSIX platform.');
  Exit;
  {$ELSE}
  {$IFDEF MSWINDOWS}
  Ok := Windows.WriteFile(P.Input.Handle, FWriteQueue[1], N, Written, nil);
  if not Ok then
  begin
    Err := Windows.GetLastError;
    if (Err = ERROR_NO_DATA) or (Err = ERROR_IO_PENDING) or
       (Err = ERROR_PIPE_LISTENING) then Exit;
    SetFailure('Catalog helper input pipe failed.');
    Exit;
  end;
  W := Written;
  {$ELSE}
  W := 0;
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
  if W > 0 then Delete(FWriteQueue, 1, W);
  {$ENDIF}
end;

function TCatalogProcessTransport.ReadAvailable(MaxBytes: integer): UTF8String;
{$IFDEF FPC}
var
  P: TProcess;
  N, R, Drained: integer;
  B: array[0..8191] of byte;
{$ENDIF}
begin
  Result := '';
  {$IFDEF FPC}
  if not FStarted or (MaxBytes <= 0) then Exit;
  PumpWrites;
  P := TProcess(FProcess);
  while (Length(Result) < MaxBytes) and (P.Output.NumBytesAvailable > 0) do
  begin
    N := P.Output.NumBytesAvailable;
    if N > SizeOf(B) then N := SizeOf(B);
    if N > MaxBytes - Length(Result) then N := MaxBytes - Length(Result);
    if N <= 0 then Break;
    R := P.Output.Read(B, N);
    if R <= 0 then Break;
    SetLength(Result, Length(Result) + R);
    Move(B[0], Result[Length(Result) - R + 1], R);
  end;
  // stderr is separate from the JSON protocol; drain without retaining/logging.
  Drained := 0;
  while (Drained < MaxBytes) and (P.Stderr.NumBytesAvailable > 0) do
  begin
    N := P.Stderr.NumBytesAvailable;
    if N > MaxBytes - Drained then N := MaxBytes - Drained;
    if N > SizeOf(B) then N := SizeOf(B);
    if N <= 0 then Break;
    R := P.Stderr.Read(B, N);
    if R <= 0 then Break;
    Inc(Drained, R);
  end;
  {$ENDIF}
end;

function TCatalogProcessTransport.Running: boolean;
begin
  {$IFDEF FPC}
  {$IFDEF LINUX}
  Result := FStarted and Assigned(FReaperState) and
    (InterlockedCompareExchange(PCatalogReaperState(FReaperState)^.Done, 0, 0) = 0);
  {$ELSE}
  Result := FStarted and Assigned(FProcess) and TProcess(FProcess).Running;
  {$ENDIF}
  {$ELSE}
  Result := false;
  {$ENDIF}
end;

procedure TCatalogProcessTransport.TerminateOwned;
begin
  if FTerminated then Exit;
  FTerminated := true;
  FWriteQueue := ''; // discard any credentials/requests that were not written
  {$IFDEF FPC}
  {$IFDEF LINUX}
  if FStarted and Assigned(FReaperState) and
     (InterlockedCompareExchange(PCatalogReaperState(FReaperState)^.Done, 0, 0) = 0) then
  begin
    LockCatalogProcess(PCatalogReaperState(FReaperState));
    if InterlockedCompareExchange(PCatalogReaperState(FReaperState)^.Done, 0, 0) = 0 then
      fpKill(FChildPID, SIGKILL);
    UnlockCatalogProcess(PCatalogReaperState(FReaperState));
  end;
  {$ELSE}
  if Running then
  begin
    {$IFDEF UNIX}
    // SIGKILL targets only the owned helper PID. The current adapter starts no
    // subprocesses; no broad process-name or parent-process cleanup is used.
    fpKill(TProcess(FProcess).Handle, SIGKILL);
    {$ELSE}
    {$IFDEF MSWINDOWS}
    Windows.TerminateProcess(TProcess(FProcess).Handle, 1);
    {$ELSE}
    TProcess(FProcess).Terminate(1);
    {$ENDIF}
    {$ENDIF}
  end;
  {$ENDIF}
  {$ENDIF}
end;

{ TCatalogSession }

constructor TCatalogSession.Create(Transport: TCatalogTransport; OwnsTransport: boolean);
begin
  inherited Create;
  if not Assigned(Transport) then
    raise Exception.Create('Catalog transport is required.');
  FTransport := Transport;
  FOwnsTransport := OwnsTransport;
  FResults := TStringList.Create;
  FDetailLinks := TStringList.Create;
  FStatus := 'Catalog setup unavailable.';
end;

function TCatalogSession.GetHelperRunning: boolean;
begin
  Result := Assigned(FTransport) and FTransport.Running;
end;

destructor TCatalogSession.Destroy;
begin
  if FTransport.Running then FTransport.TerminateOwned;
  if FOwnsTransport then FTransport.Free;
  FDetailLinks.Free;
  FResults.Free;
  inherited Destroy;
end;

function TCatalogSession.GetResultCount: integer;
begin
  Result := Length(FResultItems);
end;

function TCatalogSession.GetResultItem(Index: integer): TCatalogSearchResult;
begin
  if (Index < 0) or (Index >= Length(FResultItems)) then
    raise EListError.Create('Catalog result index is out of range.');
  Result := FResultItems[Index];
end;

procedure TCatalogSession.ClearResults;
begin
  FResults.Clear;
  SetLength(FResultItems, 0);
end;

procedure TCatalogSession.ClearDetails;
begin
  FDetailSongID := 0;
  FDetailLinks.Clear;
end;

function TCatalogSession.CanStartRequest: boolean;
begin
  Result := false;
  if FBusy or FClosing then Exit;
  if not FSessionReady or not FTransport.Running or
     (FTransport.FailureMessage <> '') then
  begin
    FAuthenticated := false;
    FSessionReady := false;
    FDetailsCapability := false;
    ClearDetails;
    FStatus := 'Catalog session is unavailable. Reopen catalog search.';
    Exit;
  end;
  Result := true;
end;

function TCatalogSession.NewRequestID: string;
begin
  Inc(FNextID);
  Result := 'worldparty-' + IntToStr(FNextID);
end;

function TCatalogSession.SendRequest(const Op: string; Fields: TStrings; SongID: Int64): string;
var
  Text: UTF8String;
  I: integer;
begin
  // Request bodies are built by hand and stay ASCII-only on the wire, so no
  // Windows ANSI codepage conversion can alter a typed value. Field VALUES
  // are pre-escaped by their own callers (Login, LoginStored, Search) into
  // pure-ASCII \uXXXX text before the TStrings store can convert them;
  // SendRequest escapes only keys, never the pre-escaped values.
  Result := NewRequestID;
  Text := '{"protocol_version":1,"request_id":"' +
          CatalogOutEscape(UTF8String(Result)) + '","op":"' +
          CatalogOutEscape(UTF8String(Op)) + '"';
  if SongID > 0 then
    Text := Text + ',"id":' + IntToStr(SongID);
  if Assigned(Fields) then
    for I := 0 to Fields.Count - 1 do
      Text := Text + ',"' +
              CatalogOutEscape(UTF8String(Fields.Names[I])) + '":"' +
              UTF8String(Fields.ValueFromIndex[I]) + '"';
  Text := Text + '}';
  FTransport.SendLine(Text);
end;

function TCatalogSession.Start(const PythonPath, AdapterPath: string; const CredentialsPath: string): boolean;
begin
  Result := false;
  if FBusy or FClosing or FTransport.Running then Exit;
  FSessionReady := false;
  FDetailsCapability := false;
  FAuthenticated := false;
  FErrorCode := '';
  FCredentialsPath := CredentialsPath;
  ClearResults;
  ClearDetails;
  if not CatalogConfigurationReady(PythonPath, AdapterPath) then
  begin FStatus := 'Catalog search is not configured.'; Exit; end;
  if (CredentialsPath <> '') and not CatalogStoredCredentialsReady(CredentialsPath) then
  begin FStatus := 'Credentials file is not available. Use an absolute path to an existing file.'; Exit; end;
  try
    FTransport.Start(PythonPath, AdapterPath, CredentialsPath);
    FStatus := 'Starting catalog helper...';
    FPendingOp := 'status';
    FBusy := true;
    FPendingID := SendRequest('status', nil);
    FPendingDeadline := GetTickCount64 + CStatusTimeoutMs;
    Result := true;
  except
    FBusy := false;
    FPendingOp := '';
    FPendingID := '';
    FStatus := 'Catalog helper could not start.';
    FErrorCode := 'helper_start_failed';
    FTransport.TerminateOwned;
  end;
end;

function TCatalogSession.Login(const Username, Password: UTF8String): boolean;
var Fields: TStringList;
begin
  Result := false;
  if not CanStartRequest then Exit;
  if (Username = '') or (Password = '') then
  begin FStatus := 'Enter your existing catalog username and password.'; Exit; end;
  Fields := TStringList.Create;
  try
    Fields.Values['user'] := string(CatalogOutEscape(Username));
    Fields.Values['password'] := string(CatalogOutEscape(Password));
    ClearDetails;
    FPendingOp := 'login'; FBusy := true;
    FAuthenticated := false;
    FStatus := 'Signing in for this process only...';
    FErrorCode := '';
    try
      FPendingID := SendRequest('login', Fields);
      FPendingDeadline := GetTickCount64 + COperationTimeoutMs;
      Result := true;
    except
      FinishPending('Could not send sign-in request.', 'request_write_failed');
      FTransport.TerminateOwned;
    end;
  finally
    Fields.Clear;
    Fields.Free;
  end;
end;

function TCatalogSession.LoginStored: boolean;
var Fields: TStringList;
begin
  Result := false;
  if not CanStartRequest then Exit;
  if FCredentialsPath = '' then
  begin FStatus := 'No catalog credentials file is configured.'; Exit; end;
  Fields := TStringList.Create;
  try
    Fields.Values['credentials_file'] := string(CatalogOutEscape(UTF8String(FCredentialsPath)));
    ClearDetails;
    FPendingOp := 'login'; FBusy := true;
    FAuthenticated := false;
    FStatus := 'Signing in for this process only...';
    FErrorCode := '';
    try
      FPendingID := SendRequest('login', Fields);
      FPendingDeadline := GetTickCount64 + COperationTimeoutMs;
      Result := true;
    except
      FinishPending('Could not send sign-in request.', 'request_write_failed');
      FTransport.TerminateOwned;
    end;
  finally
    Fields.Clear;
    Fields.Free;
  end;
end;

function TCatalogSession.Search(const Artist, Title: UTF8String; const Query: UTF8String): boolean;
var Fields: TStringList;
begin
  Result := false;
  if not CanStartRequest then Exit;
  if not FAuthenticated then
  begin FStatus := 'Sign in to the catalog in this session before searching.'; Exit; end;
  Fields := TStringList.Create;
  try
    if Query <> '' then Fields.Values['query'] := string(CatalogOutEscape(Query));
    Fields.Values['artist'] := string(CatalogOutEscape(Artist));
    Fields.Values['title'] := string(CatalogOutEscape(Title));
    ClearResults;
    ClearDetails;
    FPendingOp := 'search'; FBusy := true;
    FStatus := 'Searching catalog...';
    FErrorCode := '';
    try
      FPendingID := SendRequest('search', Fields);
      FPendingDeadline := GetTickCount64 + COperationTimeoutMs;
      Result := true;
    except
      FinishPending('Could not send catalog search.', 'request_write_failed');
      FTransport.TerminateOwned;
    end;
  finally
    Fields.Free;
  end;
end;

function TCatalogSession.Details(SongID: Int64): boolean;
var I: integer; Found: boolean;
begin
  Result := false;
  if not CanStartRequest then Exit;
  if not FAuthenticated then
  begin FStatus := 'Sign in to the catalog before viewing source details.'; Exit; end;
  if not FDetailsCapability then
  begin FStatus := 'Catalog source details are unavailable.'; Exit; end;
  Found := false;
  if SongID > 0 then
    for I := 0 to High(FResultItems) do
      if FResultItems[I].SongID = SongID then
      begin Found := true; Break; end;
  if not Found then
  begin FStatus := 'Select a current catalog result before viewing source details.'; Exit; end;
  ClearDetails;
  FPendingSongID := SongID;
  FDetailReceived := false;
  FPendingOp := 'details';
  FBusy := true;
  FStatus := 'Loading catalog source details...';
  FErrorCode := '';
  try
    // v1 requires an integer ID, not the text fields used by login/search.
    FPendingID := SendRequest('details', nil, SongID);
    FPendingDeadline := GetTickCount64 + COperationTimeoutMs;
    Result := true;
  except
    FinishPending('Could not send catalog source details request.', 'request_write_failed');
    FTransport.TerminateOwned;
  end;
end;

function TCatalogSession.DownloadSong(SongID: Int64; const URL, Root: string): boolean;
var Fields: TStringList;
begin
  Result := false;
  if not CanStartRequest then Exit;
  if not FAuthenticated or not FDownloadCapability or
     (SongID <> FDetailSongID) or (FDetailLinks.IndexOf(URL) < 0) or
     not IsAbsoluteCatalogPath(Root) then Exit;
  Fields := TStringList.Create;
  try
    Fields.Values['url'] := string(CatalogOutEscape(UTF8String(URL)));
    Fields.Values['root'] := string(CatalogOutEscape(UTF8String(Root)));
    FPendingSongID := SongID;
    FInstallRoot := Root;
    FInstallReceived := false;
    FInstalledFolder := '';
    FPendingOp := 'download'; FBusy := true;
    FStatus := 'Downloading and verifying media...'; FErrorCode := '';
    try
      FPendingID := SendRequest('download', Fields, SongID);
      FPendingDeadline := GetTickCount64 + 660000;
      Result := true;
    except
      FinishPending('Could not send download request.', 'request_write_failed');
      FTransport.TerminateOwned;
    end;
  finally Fields.Free; end;
end;

procedure TCatalogSession.Close;
var O: TJSONObject;
begin
  if FClosing then Exit;
  FClosing := true;
  FSessionReady := false;
  FDetailsCapability := false;
  ClearDetails;
  ClearResults;
  FPendingSongID := 0;
  FDetailReceived := false;
  if (FPendingOp = 'login') or (FPendingOp = 'search') or
     (FPendingOp = 'details') or (FPendingOp = 'download') then
    FClosingTarget := FPendingID
  else
    FClosingTarget := '';
  FAuthenticated := false;
  FBusy := false;
  FPendingID := '';
  FPendingOp := '';
  FPendingDeadline := 0;
  if not FTransport.Running then
  begin FStatus := 'Catalog session closed.'; Exit; end;
  FClosingID := NewRequestID;
  O := TJSONObject.Create;
  try
    O.Add('protocol_version', 1);
    O.Add('request_id', FClosingID);
    O.Add('op', 'quit');
    try
      FTransport.SendLine(UTF8String(O.AsJSON));
      FCloseDeadline := GetTickCount64 + CCloseTimeoutMs;
      FStatus := 'Closing catalog session...';
    except
      FStatus := 'Catalog helper termination requested.';
      FTransport.TerminateOwned;
    end;
  finally
    O.Free;
  end;
end;

procedure TCatalogSession.ForceTerminate;
begin
  FSessionReady := false;
  FDetailsCapability := false;
  ClearDetails;
  ClearResults;
  FPendingSongID := 0;
  FDetailReceived := false;
  if FTransport.Running then FTransport.TerminateOwned;
  FAuthenticated := false;
  FBusy := false;
  FPendingID := '';
  FPendingOp := '';
  FPendingDeadline := 0;
  if FClosing then FStatus := 'Catalog helper termination requested.';
end;

procedure TCatalogSession.FinishPending(const MessageText: string; const Code: string);
var WasDownload: boolean;
begin
  WasDownload := FPendingOp = 'download';
  FBusy := false;
  FPendingID := '';
  FPendingOp := '';
  FPendingDeadline := 0;
  FPendingSongID := 0;
  FDetailReceived := false;
  if (Code <> '') and not WasDownload then ClearDetails;
  FStatus := UTF8String(MessageText);
  FErrorCode := Code;
  if (Code = 'request_timeout') or (Code = 'transport_failed') or
     (Code = 'helper_exited') or (Code = 'request_write_failed') then
  begin
    FAuthenticated := false;
    FSessionReady := false;
    FDetailsCapability := false;
  end;
end;

procedure TCatalogSession.FailProtocol(const MessageText: string);
begin
  FSessionReady := false;
  FDetailsCapability := false;
  ClearDetails;
  ClearResults;
  FPendingSongID := 0;
  FDetailReceived := false;
  FAuthenticated := false;
  FDownloadCapability := false;
  FBusy := false;
  FPendingID := '';
  FPendingOp := '';
  FPendingDeadline := 0;
  FClosing := false;
  FCloseDeadline := 0;
  FStatus := UTF8String(MessageText);
  FErrorCode := 'protocol_error';
  FTransport.TerminateOwned;
end;

procedure TCatalogSession.ReceiveLine(const Line: UTF8String);
var
  Decoded: UTF8String;
  Tagged: RawByteString;
  OldCodePage: Word;
  Data: TJSONData;
  Obj, Caps, Song: TJSONObject;
  Songs, Links: TJSONArray;
  ParsedResults: TCatalogSearchResults;
  ParsedRows, ParsedLinks: TStringList;
  EventType, RequestID, Code, State, Scope, Artist, Title, Lang, Row, Command, Link: UTF8String;
  Version: Int64;
  Download, Accepted, LoginOK: boolean;
  I: Integer; // TJSONArray.Count/Items use LongInt indices in FPC 3.2.2.
  ResultLimit: integer;
  SongID: Int64;
begin
  Decoded := Line;
  CatalogUnescapeJSONUnicode(Decoded);
  // The Win32 ANSI runtime makes UTF-8 content unusable for the FPC 3.2.2
  // JSON scanner: text routed through String defaults to the system codepage
  // and single \uXXXX escapes above U+007F collapse to '?'. Parse with the
  // runtime codepage temporarily set to UTF-8 so both the String assignment
  // and the scanner see exact UTF-8 bytes; ASCII-only payloads are unaffected.
  Tagged := Decoded;
  SetCodePage(Tagged, CP_UTF8, false);
  OldCodePage := DefaultSystemCodePage;
  DefaultSystemCodePage := CP_UTF8;
  try
    try
      Data := GetJSON(string(Tagged), true);
    except
      FailProtocol('Catalog helper sent an invalid response.');
      Exit;
    end;
  finally
    DefaultSystemCodePage := OldCodePage;
  end;
  try
    try
    if not (Data is TJSONObject) then
    begin FailProtocol('Catalog helper sent an invalid response.'); Exit; end;
    Obj := TJSONObject(Data);
    if not JSONInteger(Obj, 'protocol_version', Version) or (Version <> 1) or
       not JSONString(Obj, 'request_id', RequestID) or (RequestID = '') or
       not JSONString(Obj, 'type', EventType) then
    begin FailProtocol('Catalog helper could not correlate its response.'); Exit; end;

    if EventType = 'control_ack' then
    begin
      if not FClosing or (RequestID <> FClosingID) or
         not JSONString(Obj, 'command', Command) or (Command <> 'quit') or
         not JSONBoolean(Obj, 'accepted', Accepted) or not Accepted or
         not CloseTargetMatches(Obj, FClosingTarget) then
        FailProtocol('Catalog helper returned an invalid close acknowledgement.')
      else
      begin
        // Ack means quit was accepted; it does not prove that the helper exited.
        FStatus := 'Quit acknowledged; waiting for helper exit.';
      end;
      Exit;
    end;
    if RequestID <> FPendingID then Exit; // stale/out-of-order events are ignored
    if ((EventType = 'status') and (FPendingOp <> 'status')) or
       ((EventType = 'login') and (FPendingOp <> 'login')) or
       ((EventType = 'results') and (FPendingOp <> 'search')) or
       ((EventType = 'details') and (FPendingOp <> 'details')) or
       ((EventType = 'idle') and not ((FPendingOp = 'login') or
         (FPendingOp = 'search') or (FPendingOp = 'details') or
         (FPendingOp = 'download'))) then
    begin FailProtocol('Catalog helper returned an event for the wrong operation.'); Exit; end;

    if EventType = 'status' then
    begin
      if not JSONString(Obj, 'auth_state', State) or
         not ((State = 'signed_in') or (State = 'signed_out')) or
         not JSONString(Obj, 'session_scope', Scope) or
         (Scope <> 'process_memory_only') or
         not JSONBoolean(Obj, 'busy', Accepted) or Accepted then
      begin FailProtocol('Catalog helper returned an invalid status.'); Exit; end;
      if not (Obj.Find('capabilities') is TJSONObject) then
      begin FailProtocol('Catalog helper omitted its capabilities.'); Exit; end;
      Caps := TJSONObject(Obj.Find('capabilities'));
      if not JSONBoolean(Caps, 'download', Download) or (Download and not FAllowDownloads) then
      begin FailProtocol('Catalog helper unexpectedly enabled downloads.'); Exit; end;
      FDetailsCapability := false;
      if Assigned(Caps.Find('details')) and
         not JSONBoolean(Caps, 'details', FDetailsCapability) then
      begin FailProtocol('Catalog helper returned an invalid details capability.'); Exit; end;
      FAuthenticated := State = 'signed_in';
      FSessionReady := true;
      FDownloadCapability := Download and FAllowDownloads;
      if FAuthenticated then FStatus := 'Catalog session ready. Session exists only in memory.'
      else FStatus := 'Sign-in required. Session exists only in memory.';
      FinishPending(string(FStatus), '');
    end
    else if EventType = 'login' then
    begin
      if not JSONBoolean(Obj, 'ok', LoginOK) or
         not JSONString(Obj, 'auth_state', State) or
         not ((State = 'signed_in') or (State = 'signed_out')) or
         (LoginOK <> (State = 'signed_in')) then
      begin FailProtocol('Catalog helper returned an invalid sign-in state.'); Exit; end;
      FAuthenticated := LoginOK;
      if FAuthenticated then FinishPending('Signed in for this session only.', '')
      else FinishPending('Sign-in was not verified.', 'login_unverified');
    end
    else if EventType = 'results' then
    begin
      if not (Obj.Find('songs') is TJSONArray) then
      begin FailProtocol('Catalog helper returned invalid metadata results.'); Exit; end;
      Songs := TJSONArray(Obj.Find('songs'));
      // Preserve the existing first-30 display contract. The service's limit=6
      // request is advisory; its HTML parser does not enforce a response count.
      ResultLimit := Songs.Count;
      if ResultLimit > CMaxResults then ResultLimit := CMaxResults;
      ParsedRows := TStringList.Create;
      try
        SetLength(ParsedResults, ResultLimit);
        for I := 0 to ResultLimit - 1 do
        begin
          if not (Songs.Items[I] is TJSONObject) then
          begin FailProtocol('Catalog helper returned an invalid metadata row.'); Exit; end;
          Song := TJSONObject(Songs.Items[I]);
          if not JSONInteger(Song, 'id', SongID) or (SongID <= 0) or
             not JSONString(Song, 'artist', Artist) or
             not JSONString(Song, 'title', Title) then
          begin FailProtocol('Catalog helper returned an invalid metadata row.'); Exit; end;
          Lang := '';
          if Assigned(Song.Find('language')) and not JSONString(Song, 'language', Lang) then
          begin FailProtocol('Catalog helper returned an invalid metadata row.'); Exit; end;
          ParsedResults[I].SongID := SongID;
          ParsedResults[I].Artist := UTF8String(Artist);
          ParsedResults[I].Title := UTF8String(Title);
          ParsedResults[I].Language := UTF8String(Lang);
          Row := IntToStr(SongID) + '  ' + Artist + ' - ' + Title;
          if Lang <> '' then Row := Row + '  [' + Lang + ']';
          ParsedRows.Add(Row);
        end;
        // Publish only after the entire bounded response has passed validation.
        FResults.Assign(ParsedRows);
        FResultItems := ParsedResults;
      finally ParsedRows.Free; end;
      FStatus := 'USDB results ready. Select a song to view download sources.';
    end
    else if EventType = 'details' then
    begin
      if FDetailReceived or not JSONInteger(Obj, 'id', SongID) or
         (SongID <= 0) or (SongID <> FPendingSongID) or
         not (Obj.Find('links') is TJSONArray) then
      begin FailProtocol('Catalog helper returned invalid source details.'); Exit; end;
      Links := TJSONArray(Obj.Find('links'));
      if Links.Count > CMaxSourceLinks then
      begin FailProtocol('Catalog helper returned too many source links.'); Exit; end;
      ParsedLinks := TStringList.Create;
      try
        for I := 0 to Links.Count - 1 do
        begin
          if Links.Items[I].JSONType <> jtString then
          begin FailProtocol('Catalog helper returned an invalid source link.'); Exit; end;
          Link := UTF8String(TJSONString(Links.Items[I]).Value);
          if not IsCatalogSourceLink(Link) then
          begin FailProtocol('Catalog helper returned an invalid source link.'); Exit; end;
          ParsedLinks.Add(Link);
        end;
        FDetailLinks.Assign(ParsedLinks);
        FDetailSongID := SongID;
        FDetailReceived := true;
      finally ParsedLinks.Free; end;
      if FDetailLinks.Count = 0 then
        FStatus := 'Source details loaded. No media links listed. Downloads are unavailable.'
      else
        FStatus := 'Source loaded. Choose Download to install this song.';
    end
    else if EventType = 'progress' then
    begin
      if FPendingOp <> 'download' then
      begin FailProtocol('Unexpected download progress.'); Exit; end;
      FStatus := 'Downloading and verifying media...';
    end
    else if EventType = 'installed' then
    begin
      if (FPendingOp <> 'download') or FInstallReceived or
         not JSONInteger(Obj, 'id', SongID) or (SongID <> FPendingSongID) or
         not JSONString(Obj, 'folder', Row) or
         (ExpandFileName(string(Row)) <> ExpandFileName(IncludeTrailingPathDelimiter(FInstallRoot) + 'USDB-' + IntToStr(SongID))) then
      begin FailProtocol('Invalid installed-song result.'); Exit; end;
      FInstallReceived := true;
      FInstalledFolder := string(Row);
      FStatus := 'Installed. Return to your library to sing.';
    end
    else if EventType = 'error' then
    begin
      if not JSONString(Obj, 'code', Code) or (Code = '') then
      begin FailProtocol('Catalog helper returned an invalid error.'); Exit; end;
      if Code = 'authentication_required' then FAuthenticated := false;
      if Code = 'busy' then FStatus := 'Catalog is busy. Try again shortly.'
      else if Code = 'authentication_required' then FStatus := 'Sign-in is required again.'
      else if Code = 'download_disabled' then FStatus := 'Downloads are disabled.'
      else if (Code = 'download_failed') and JSONString(Obj, 'message', Row) then
        FStatus := Copy(Row, 1, 512)
      else FStatus := 'Catalog request failed (' + Code + ').';
      // v1 errors are terminal, including busy; adapter does not follow them with idle.
      FinishPending(string(FStatus), Code);
    end
    else if EventType = 'idle' then
    begin
      if (FPendingOp = 'download') and not FInstallReceived then
      begin FailProtocol('Download ended without an installed song.'); Exit; end;
      if (FPendingOp = 'details') and not FDetailReceived then
      begin FailProtocol('Catalog helper omitted its source details result.'); Exit; end;
      if FStatus = 'Searching catalog...' then FStatus := 'Search complete.';
      FinishPending(string(FStatus), '');
    end
    else
      FailProtocol('Catalog helper returned an unknown response type.');
  except
    on E: Exception do
      FailProtocol('Catalog helper returned an invalid response.');
  end;
  finally
    Data.Free;
  end;
end;

procedure TCatalogSession.Poll;
begin
  PollAt(GetTickCount64);
end;

procedure TCatalogSession.PollAt(NowMs: QWord);
var Chunk: UTF8String; P, N: integer; Line: UTF8String;
begin
  if not Assigned(FTransport) then Exit;
  Chunk := FTransport.ReadAvailable(16384);
  for P := 1 to Length(Chunk) do
  begin
    if Chunk[P] = #10 then
    begin
      Line := FInputBuffer;
      if (Length(Line) > 0) and (Line[Length(Line)] = #13) then Delete(Line, Length(Line), 1);
      FInputBuffer := '';
      if Length(Line) > 0 then ReceiveLine(Line);
    end
    else
    begin
      N := Length(FInputBuffer);
      if N >= CMaxFrame then
      begin FailProtocol('Catalog response exceeded the size limit.'); FInputBuffer := ''; Exit; end;
      SetLength(FInputBuffer, N + 1);
      FInputBuffer[N + 1] := Chunk[P];
    end;
  end;
  if FTransport.FailureMessage <> '' then
  begin
    FinishPending('Catalog helper communication failed.', 'transport_failed');
    FTransport.TerminateOwned;
  end;
  if FBusy and (FPendingDeadline <> 0) and (NowMs >= FPendingDeadline) then
  begin
    FinishPending('Catalog request timed out.', 'request_timeout');
    FTransport.TerminateOwned;
  end;
  if FBusy and not FTransport.Running then
    FinishPending('Catalog helper exited before replying.', 'helper_exited');
  if not FTransport.Running and FAuthenticated and not FClosing then
  begin
    FAuthenticated := false;
    FSessionReady := false;
    FDetailsCapability := false;
    ClearDetails;
    FStatus := 'Catalog helper exited. Sign in again.';
    FErrorCode := 'helper_exited';
  end;
  if FClosing and not FTransport.Running then
  begin
    FCloseDeadline := 0;
    FStatus := 'Catalog session closed.';
  end
  else if FClosing and (FCloseDeadline <> 0) and (NowMs >= FCloseDeadline) then
  begin
    FTransport.TerminateOwned;
    FCloseDeadline := 0;
    FStatus := 'Catalog helper termination requested.';
  end;
end;

end.
