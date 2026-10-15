unit USongCatalogBridge;

{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}

interface

uses Classes, SysUtils;

type
  TCatalogTransport = class
  public
    procedure Start(const PythonPath, AdapterPath: string); virtual; abstract;
    procedure SendLine(const Line: UTF8String); virtual; abstract;
    function ReadAvailable(MaxBytes: integer): UTF8String; virtual; abstract;
    function Running: boolean; virtual; abstract;
    procedure TerminateOwned; virtual; abstract;
    function FailureMessage: string; virtual; abstract;
  end;

  TCatalogProcessTransport = class(TCatalogTransport)
  private
    FProcess: TObject;
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
    procedure Start(const PythonPath, AdapterPath: string); override;
    procedure SendLine(const Line: UTF8String); override;
    function ReadAvailable(MaxBytes: integer): UTF8String; override;
    function Running: boolean; override;
    procedure TerminateOwned; override;
    function FailureMessage: string; override;
    function OwnedProcessID: integer;
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
    FDownloadCapability: boolean;
    FStatus: UTF8String;
    FErrorCode: string;
    FResults: TStringList;
    FPendingDeadline: QWord;
    FCloseDeadline: QWord;
    function NewRequestID: string;
    function SendRequest(const Op: string; Fields: TStrings): string;
    procedure ReceiveLine(const Line: UTF8String);
    procedure FailProtocol(const MessageText: string);
    procedure FinishPending(const MessageText: string; const Code: string);
    function GetHelperRunning: boolean;
  public
    constructor Create(Transport: TCatalogTransport; OwnsTransport: boolean = false);
    destructor Destroy; override;
    function Start(const PythonPath, AdapterPath: string): boolean;
    function Login(const Username, Password: UTF8String): boolean;
    function Search(const Artist, Title: UTF8String): boolean;
    procedure Close;
    procedure ForceTerminate;
    procedure Poll;
    procedure PollAt(NowMs: QWord);
    property Status: UTF8String read FStatus;
    property ErrorCode: string read FErrorCode;
    property Authenticated: boolean read FAuthenticated;
    property DownloadsEnabled: boolean read FDownloadCapability;
    property Busy: boolean read FBusy;
    property Closing: boolean read FClosing;
    property HelperRunning: boolean read GetHelperRunning;
    property Results: TStringList read FResults;
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

function JSONString(Obj: TJSONObject; const Key: string; out Value: string): boolean;
var D: TJSONData;
begin
  Value := '';
  D := Obj.Find(Key);
  Result := Assigned(D) and (D.JSONType = jtString);
  if Result then Value := D.AsString;
end;

function JSONInteger(Obj: TJSONObject; const Key: string; out Value: Int64): boolean;
var D: TJSONData;
begin
  Value := 0;
  D := Obj.Find(Key);
  Result := Assigned(D) and (D is TJSONIntegerNumber);
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
    Actual: string;
begin
  D := Obj.Find('target_request_id');
  if not Assigned(D) then Exit(false);
  if D.JSONType = jtNull then Exit(true); // operation may finish before quit is read
  Result := (D.JSONType = jtString) and (Expected <> '') and
            JSONString(Obj, 'target_request_id', Actual) and (Actual = Expected);
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

procedure TCatalogProcessTransport.Start(const PythonPath, AdapterPath: string);
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
  FResults.Free;
  inherited Destroy;
end;

function TCatalogSession.NewRequestID: string;
begin
  Inc(FNextID);
  Result := 'worldparty-' + IntToStr(FNextID);
end;

function TCatalogSession.SendRequest(const Op: string; Fields: TStrings): string;
var
  O: TJSONObject;
  I: integer;
  Value: string;
begin
  Result := '';
  O := TJSONObject.Create;
  try
    O.Add('protocol_version', 1);
    Result := NewRequestID;
    O.Add('request_id', Result);
    O.Add('op', Op);
    if Assigned(Fields) then
      for I := 0 to Fields.Count - 1 do
      begin
        Value := Fields.ValueFromIndex[I];
        O.Add(Fields.Names[I], Value);
      end;
    FTransport.SendLine(UTF8String(O.AsJSON));
  finally
    O.Free;
  end;
end;

function TCatalogSession.Start(const PythonPath, AdapterPath: string): boolean;
begin
  Result := false;
  if not CatalogConfigurationReady(PythonPath, AdapterPath) then
  begin FStatus := 'Catalog search is not configured.'; Exit; end;
  try
    FTransport.Start(PythonPath, AdapterPath);
    FStatus := 'Starting catalog helper…';
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
  if FBusy or FClosing then Exit;
  if (Username = '') or (Password = '') then
  begin FStatus := 'Enter your existing catalog username and password.'; Exit; end;
  Fields := TStringList.Create;
  try
    Fields.Values['user'] := string(Username);
    Fields.Values['password'] := string(Password);
    FPendingOp := 'login'; FBusy := true;
    FAuthenticated := false;
    FStatus := 'Signing in for this process only…';
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

function TCatalogSession.Search(const Artist, Title: UTF8String): boolean;
var Fields: TStringList;
begin
  Result := false;
  if FBusy or FClosing then Exit;
  if not FAuthenticated then
  begin FStatus := 'Sign in to the catalog in this session before searching.'; Exit; end;
  Fields := TStringList.Create;
  try
    Fields.Values['artist'] := string(Artist);
    Fields.Values['title'] := string(Title);
    FResults.Clear;
    FPendingOp := 'search'; FBusy := true;
    FStatus := 'Searching catalog…';
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

procedure TCatalogSession.Close;
var O: TJSONObject;
begin
  if FClosing then Exit;
  FClosing := true;
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
      FStatus := 'Closing catalog session…';
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
  if FTransport.Running then FTransport.TerminateOwned;
  FAuthenticated := false;
  FBusy := false;
  FPendingID := '';
  FPendingOp := '';
  FPendingDeadline := 0;
  if FClosing then FStatus := 'Catalog helper termination requested.';
end;

procedure TCatalogSession.FinishPending(const MessageText: string; const Code: string);
begin
  FBusy := false;
  FPendingID := '';
  FPendingOp := '';
  FPendingDeadline := 0;
  FStatus := UTF8String(MessageText);
  FErrorCode := Code;
  if (Code = 'request_timeout') or (Code = 'transport_failed') or
     (Code = 'helper_exited') or (Code = 'request_write_failed') then
    FAuthenticated := false;
end;

procedure TCatalogSession.FailProtocol(const MessageText: string);
begin
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
  Data: TJSONData;
  Obj, Caps, Song: TJSONObject;
  Songs: TJSONArray;
  EventType, RequestID, Code, State, Scope, Artist, Title, Lang, Row, Command: string;
  Version: Int64;
  Download, Accepted, LoginOK: boolean;
  I, SongID: Int64;
begin
  try
    Data := GetJSON(string(Line), true);
  except
    FailProtocol('Catalog helper sent an invalid response.');
    Exit;
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
      if not JSONBoolean(Caps, 'download', Download) or Download then
      begin FailProtocol('Catalog helper unexpectedly enabled downloads.'); Exit; end;
      FAuthenticated := State = 'signed_in';
      FDownloadCapability := false;
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
      FResults.Clear;
      for I := 0 to Songs.Count - 1 do
      begin
        if I >= CMaxResults then Break;
        if not (Songs.Items[I] is TJSONObject) then
        begin FailProtocol('Catalog helper returned an invalid metadata row.'); Exit; end;
        Song := TJSONObject(Songs.Items[I]);
        if not JSONInteger(Song, 'id', SongID) or (SongID <= 0) or
           not JSONString(Song, 'artist', Artist) or
           not JSONString(Song, 'title', Title) then
        begin FailProtocol('Catalog helper returned an invalid metadata row.'); Exit; end;
        Lang := '';
        if Assigned(Song.Find('language')) then
        begin
          if not JSONString(Song, 'language', Lang) then
          begin FailProtocol('Catalog helper returned an invalid metadata row.'); Exit; end;
        end;
        Row := IntToStr(SongID) + '  ' + Artist + ' — ' + Title;
        if Lang <> '' then Row := Row + '  [' + Lang + ']';
        FResults.Add(Row);
      end;
      FStatus := 'Metadata results only. Downloads are unavailable.';
    end
    else if EventType = 'error' then
    begin
      if not JSONString(Obj, 'code', Code) or (Code = '') then
      begin FailProtocol('Catalog helper returned an invalid error.'); Exit; end;
      if Code = 'authentication_required' then FAuthenticated := false;
      if Code = 'busy' then FStatus := 'Catalog is busy. Try again shortly.'
      else if Code = 'authentication_required' then FStatus := 'Sign-in is required again.'
      else if Code = 'download_disabled' then FStatus := 'Downloads are disabled.'
      else FStatus := 'Catalog request failed (' + Code + ').';
      // v1 errors are terminal, including busy; adapter does not follow them with idle.
      FBusy := false; FPendingID := ''; FPendingOp := ''; FPendingDeadline := 0;
      FErrorCode := Code;
    end
    else if EventType = 'idle' then
    begin
      FBusy := false;
      FPendingID := '';
      FPendingOp := '';
      FPendingDeadline := 0;
      if FStatus = 'Searching catalog…' then FStatus := 'Search complete.';
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
