program CatalogBridgeTest;
{$mode delphi}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes, fpjson, jsonparser, USongCatalogBridge
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  TFakeTransport = class(TCatalogTransport)
  public
    Active: boolean;
    Terminated: boolean;
    StartedPython, StartedAdapter: string;
    Requests: TStringList;
    Incoming: UTF8String;
    Failure: string;
    constructor Create;
    destructor Destroy; override;
    procedure Start(const PythonPath, AdapterPath: string); override;
    procedure SendLine(const Line: UTF8String); override;
    function ReadAvailable(MaxBytes: integer): UTF8String; override;
    function Running: boolean; override;
    procedure TerminateOwned; override;
    function FailureMessage: string; override;
    procedure Push(const Data: UTF8String);
  end;

var
  Assertions: integer = 0;

procedure Check(Condition: boolean; const Why: string);
begin
  Inc(Assertions);
  if not Condition then
  begin
    WriteLn('FAIL: ', Why);
    Halt(1);
  end;
end;

constructor TFakeTransport.Create;
begin
  inherited Create;
  Requests := TStringList.Create;
end;

destructor TFakeTransport.Destroy;
begin
  Requests.Free;
  inherited Destroy;
end;

procedure TFakeTransport.Start(const PythonPath, AdapterPath: string);
begin
  StartedPython := PythonPath;
  StartedAdapter := AdapterPath;
  Active := true;
end;

procedure TFakeTransport.SendLine(const Line: UTF8String);
begin
  Requests.Add(string(Line));
end;

function TFakeTransport.ReadAvailable(MaxBytes: integer): UTF8String;
var N: integer;
begin
  N := Length(Incoming);
  if N > MaxBytes then N := MaxBytes;
  Result := Copy(Incoming, 1, N);
  Delete(Incoming, 1, N);
end;

function TFakeTransport.Running: boolean;
begin
  Result := Active;
end;

procedure TFakeTransport.TerminateOwned;
begin
  Terminated := true;
  Active := false;
end;

function TFakeTransport.FailureMessage: string;
begin
  Result := Failure;
end;

procedure TFakeTransport.Push(const Data: UTF8String);
begin
  Incoming := Incoming + Data;
end;

function ObjFromLine(const Line: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(Line, true));
end;

function RequestAt(T: TFakeTransport; Index: integer): TJSONObject;
begin
  Result := ObjFromLine(T.Requests[Index]);
end;

procedure PollUntil(Session: TCatalogSession; const ContainsText: string; Limit: integer);
var I: integer;
begin
  for I := 1 to Limit do
  begin
    Session.Poll;
    if Pos(ContainsText, string(Session.Status)) > 0 then Exit;
    Sleep(5);
  end;
  Check(false, 'timed out waiting for ' + ContainsText + '; status=' + string(Session.Status));
end;

procedure TestFakeTransport(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; StatusID, LoginID, SearchID, QuitID: string;
begin
  Check(not CatalogConfigurationReady('python3', AdapterPath), 'relative interpreter rejected');
  Check(not CatalogConfigurationReady(PythonPath, ''), 'missing adapter rejected');
  Check(CatalogConfigurationReady(PythonPath, AdapterPath), 'absolute existing paths accepted');
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'fake session starts');
    Check(S.Busy, 'status request remains busy until its response is correlated');
    Check(not S.Login('sample-user', 'temporary-password'), 'login cannot race ahead of initial status');
    Check(Pos('ready', string(S.Status)) = 0, 'status never claims ready before correlated response');
    Check((T.StartedPython = PythonPath) and (T.StartedAdapter = AdapterPath), 'exact configured paths are passed');
    O := RequestAt(T, 0);
    try
      StatusID := O.Get('request_id', '');
      Check((O.Get('protocol_version', 0) = 1) and (O.Get('op', '') = 'status'), 'versioned status request');
    finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_out","setup_state":"login_required","session_scope":"process_memory_only","busy":false,"capabilities":{"login":true,"search":true,"details":true,"download":false}}'#10, [StatusID]));
    S.Poll;
    Check(not S.Authenticated and not S.Busy, 'initial state is signed out and idle');
    Check(not S.DownloadsEnabled, 'download capability remains disabled');
    Check(Pos('signed_out', string(S.Status)) < 1, 'status is human-readable, not raw JSON');

    Check(S.Login('sample-user', 'secret-value'), 'explicit sign-in request accepted');
    O := RequestAt(T, 1);
    try
      LoginID := O.Get('request_id', '');
      Check((O.Get('op', '') = 'login') and (O.Get('user', '') = 'sample-user'), 'login fields are request-scoped');
      Check(O.Get('password', '') = 'secret-value', 'password is sent only in the local request body');
    finally O.Free; end;
    T.Push(Format('{"type":"login","protocol_version":1,"request_id":"%s","ok":true,"auth_state":"signed_in"}'#10, [LoginID]));
    T.Push(Format('{"type":"idle","protocol_version":1,"request_id":"%s"}'#10, [LoginID]));
    Check(Pos('ready', string(S.Status)) = 0, 'login remains signing-in until its correlated result');
    S.Poll;
    Check(S.Authenticated and not S.Busy, 'process-local login state is correlated');

    Check(S.Search('artist', 'title'), 'metadata search accepted');
    O := RequestAt(T, 2);
    try
      SearchID := O.Get('request_id', '');
      Check((O.Get('op', '') = 'search') and (O.Find('url') = nil) and (O.Find('root') = nil), 'search carries only metadata query fields');
      Check(O.Get('request_id', '') <> LoginID, 'search receives a new request ID');
    finally O.Free; end;
    T.Push(Format('{"type":"results","protocol_version":1,"request_id":"stale-id","songs":[{"id":9,"artist":"stale","title":"stale"}]}'#10, []));
    // Above the 32-bit ordinal range: SongID remains 64-bit while I indexes the array.
    T.Push(Format('{"type":"results","protocol_version":1,"request_id":"%s","songs":[{"id":2147483648,"artist":"A","title":"T","language":"EN"}]}'#10, [SearchID]));
    S.Poll;
    Check(S.Results.Count = 1, 'stale correlation ignored and valid results accepted');
    Check(Pos('2147483648', S.Results[0]) = 1, '64-bit catalog IDs remain intact on 32-bit builds');

    T.Push(Format('{"type":"error","protocol_version":1,"request_id":"%s","code":"authentication_required","message":"fixture"}'#10, [SearchID]));
    S.Poll;
    Check(not S.Authenticated, 'expired-session response invalidates process-local auth state');
    Check(not S.Busy, 'terminal auth error also clears busy state');

    S.Close;
    O := RequestAt(T, 3);
    try
      QuitID := O.Get('request_id', '');
      Check((O.Get('op', '') = 'quit') and (QuitID <> SearchID), 'quit has its own correlated request ID');
      Check(O.Get('protocol_version', 0) = 1, 'quit is versioned');
    finally O.Free; end;
    T.Push(Format('{"type":"control_ack","protocol_version":1,"request_id":"%s","command":"quit","accepted":true,"target_request_id":null,"code":"process_exit_requested"}'#10, [QuitID]));
    S.Poll;
    Check(Pos('acknowledged', string(S.Status)) > 0, 'quit acknowledgement correlates separately to its target');
    T.Active := false;
  finally
    S.Free;
    T.Free;
  end;
end;

procedure TestCloseActiveSearch(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; StatusID, SearchID, QuitID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'active-close fake session starts');
    O := RequestAt(T, 0);
    try StatusID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [StatusID]));
    S.Poll;
    Check(S.Search('artist', 'title'), 'active-close search begins');
    O := RequestAt(T, 1);
    try SearchID := O.Get('request_id', ''); finally O.Free; end;
    S.Close;
    O := RequestAt(T, 2);
    try
      QuitID := O.Get('request_id', '');
      Check((O.Get('op', '') = 'quit') and (QuitID <> SearchID), 'quit gets its own correlation ID');
    finally O.Free; end;
    // Adapter may complete the active operation before it consumes quit.
    T.Push(Format('{"type":"control_ack","protocol_version":1,"request_id":"%s","command":"quit","accepted":true,"target_request_id":null}'#10, [QuitID]));
    S.Poll;
    Check(S.ErrorCode <> 'protocol_error', 'null quit target is valid after a raced operation completion');
    Check(T.Active and (Pos('acknowledged', string(S.Status)) > 0),
          'accepted quit ack does not imply that a helper has exited');
    S.PollAt(High(QWord));
    Check(not T.Active and (S.Status = 'Catalog helper termination requested.'),
          'unresponsive acknowledged helper is terminated at the bounded close deadline');
  finally S.Free; T.Free; end;
end;

procedure TestBusyError(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; RequestID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'busy-error fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [RequestID]));
    S.Poll;
    Check(S.Authenticated and not S.Busy, 'status does not race ahead while busy');
    Check(S.Search('', ''), 'empty metadata query may be correlated');
    O := RequestAt(T, 1);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"error","protocol_version":1,"request_id":"%s","code":"busy"}'#10, [RequestID]));
    S.Poll;
    Check(not S.Busy and (S.ErrorCode = 'busy'), 'terminal busy error clears active search');
  finally S.Free; T.Free; end;
end;

procedure TestWrongEventKind(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; RequestID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'wrong-event fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"login","protocol_version":1,"request_id":"%s","auth_state":"signed_in"}'#10, [RequestID]));
    S.Poll;
    Check(S.ErrorCode = 'protocol_error', 'matching ID cannot authorize the wrong event kind');
    Check(not S.Authenticated, 'wrong-kind auth event cannot set signed-in state');
  finally S.Free; T.Free; end;
end;

procedure TestReauthenticationFailure(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; StatusID, LoginID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'reauth fake session starts');
    O := RequestAt(T, 0);
    try StatusID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [StatusID]));
    S.Poll;
    Check(S.Authenticated, 'status establishes current process auth snapshot');
    Check(S.Login('sample-user', 'new-temporary-password'), 'reauthentication request starts');
    Check(not S.Authenticated, 'reauth request clears prior signed-in state before result');
    O := RequestAt(T, 1);
    try LoginID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"error","protocol_version":1,"request_id":"%s","code":"authentication_failed"}'#10, [LoginID]));
    S.Poll;
    Check(not S.Authenticated and not S.Busy, 'failed reauthentication cannot retain stale auth state');
  finally S.Free; T.Free; end;
end;

procedure TestInvalidLoginResponses(const PythonPath, AdapterPath: string);
const
  Frames: array[0..3] of string = (
    '{"type":"login","protocol_version":1,"request_id":"%s","auth_state":"signed_in"}',
    '{"type":"login","protocol_version":1,"request_id":"%s","ok":"true","auth_state":"signed_in"}',
    '{"type":"login","protocol_version":1,"request_id":"%s","ok":false,"auth_state":"signed_in"}',
    '{"type":"login","protocol_version":1,"request_id":"%s","ok":true,"auth_state":"signed_out"}'
  );
var CaseIndex: integer; T: TFakeTransport; S: TCatalogSession;
  O: TJSONObject; StatusID, LoginID: string;
begin
  for CaseIndex := Low(Frames) to High(Frames) do
  begin
    T := TFakeTransport.Create;
    S := TCatalogSession.Create(T, false);
    try
      Check(S.Start(PythonPath, AdapterPath), 'login-response fake session starts');
      O := RequestAt(T, 0);
      try StatusID := O.Get('request_id', ''); finally O.Free; end;
      T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_out","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [StatusID]));
      S.Poll;
      Check(S.Login('sample-user', 'temporary-password'), 'login-response request starts');
      O := RequestAt(T, 1);
      try LoginID := O.Get('request_id', ''); finally O.Free; end;
      T.Push(UTF8String(Format(Frames[CaseIndex] + #10, [LoginID])));
      S.Poll;
      Check((S.ErrorCode = 'protocol_error') and not S.Authenticated,
            'missing, wrong-typed, false/inconsistent, or contradictory login success fails closed');
    finally S.Free; T.Free; end;
  end;
end;

procedure TestMalformedJSONTypes(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; RequestID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'malformed fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":{},"session_scope":"process_memory_only","busy":false,"capabilities":[]}'#10, [RequestID]));
    S.Poll;
    Check(S.ErrorCode = 'protocol_error', 'wrong-typed status fields fail closed without exception');
    Check(T.Terminated, 'invalid status terminates owned helper');
  finally S.Free; T.Free; end;

  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'malformed-results fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [RequestID]));
    S.Poll;
    Check(S.Search('artist', 'title'), 'search begins before malformed rows');
    O := RequestAt(T, 1);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"results","protocol_version":1,"request_id":"%s","songs":{}}'#10, [RequestID]));
    S.Poll;
    Check(S.ErrorCode = 'protocol_error', 'wrong-typed songs array is rejected');
  finally S.Free; T.Free; end;

  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'malformed-row fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [RequestID]));
    S.Poll;
    Check(S.Search('artist', 'title'), 'search begins before malformed item');
    O := RequestAt(T, 1);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"results","protocol_version":1,"request_id":"%s","songs":[{"id":"wrong","artist":4,"title":[]}]}'#10, [RequestID]));
    S.Poll;
    Check(S.ErrorCode = 'protocol_error', 'wrong-typed row fields fail closed without Draw exception');
  finally S.Free; T.Free; end;
end;

procedure TestTimeoutAndUnexpectedExit(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; RequestID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'timeout fake session starts');
    S.PollAt(High(QWord));
    Check((S.ErrorCode = 'request_timeout') and not S.Busy, 'pending status deadline clears busy');
    Check(T.Terminated, 'timed-out helper is terminated');
  finally S.Free; T.Free; end;

  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'search-timeout fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [RequestID]));
    S.Poll;
    Check(S.Search('', ''), 'timed search starts');
    S.PollAt(High(QWord));
    Check((S.ErrorCode = 'request_timeout') and not S.Busy and not S.Authenticated,
          'timed-out search clears busy and the dead process auth state');
  finally S.Free; T.Free; end;

  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'exit fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Active := false;
    S.Poll;
    Check((S.ErrorCode = 'helper_exited') and not S.Busy, 'unexpected exit does not leave pending status busy');
  finally S.Free; T.Free; end;
end;

procedure TestOversized(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; I: integer;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'oversize fake session starts');
    T.Push(StringOfChar('x', 65537));
    for I := 1 to 6 do S.Poll;
    Check(S.ErrorCode = 'protocol_error', 'oversized response frame is rejected');
    Check(T.Terminated, 'protocol failure terminates only injected owned helper');
  finally S.Free; T.Free; end;
end;

procedure TestCloseDuringStatus(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O, StatusRequest: TJSONObject; QuitID, StatusID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'early-close fake session starts');
    S.Close; // Simulates hiding the screen before the status frame is polled.
    O := RequestAt(T, 1);
    try
      QuitID := O.Get('request_id', '');
    finally O.Free; end;
    StatusRequest := RequestAt(T, 0);
    try StatusID := StatusRequest.Get('request_id', ''); finally StatusRequest.Free; end;
    Check(QuitID <> StatusID, 'quit and status have distinct request IDs');
    T.Push(Format('{"type":"control_ack","protocol_version":1,"request_id":"%s","command":"quit","accepted":true,"target_request_id":null,"code":"process_exit_requested"}'#10, [QuitID]));
    S.Poll;
    Check(Pos('acknowledged', string(S.Status)) > 0, 'quit while status is pending correctly has no active target');
    T.Active := false;
  finally S.Free; T.Free; end;
end;

procedure TestUnsafeCapability(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; RequestID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'capability fake session starts');
    O := RequestAt(T, 0);
    try RequestID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_out","session_scope":"process_memory_only","busy":false,"capabilities":{"login":true,"search":true,"details":true,"download":true}}'#10, [RequestID]));
    S.Poll;
    Check(S.ErrorCode = 'protocol_error', 'unexpected enabled-download capability is rejected');
    Check(T.Terminated, 'unexpected capability terminates only owned transport');
  finally S.Free; T.Free; end;
end;

procedure TestChildProcess(const PythonPath, AdapterPath: string);
var T: TCatalogProcessTransport; S: TCatalogSession; I: integer;
begin
  T := TCatalogProcessTransport.Create;
  S := TCatalogSession.Create(T, true);
  try
    Check(S.Start(PythonPath, AdapterPath), 'inert child starts with absolute paths');
    PollUntil(S, 'Sign-in required', 300);
    Check(not S.Authenticated, 'new process begins signed out');
    S.Close;
    for I := 1 to 300 do
    begin
      S.Poll;
      if not S.HelperRunning then Break;
      Sleep(5);
    end;
    Check(not S.HelperRunning, 'inert child exits after asynchronous quit');
    Check(Pos('closed', string(S.Status)) > 0, 'real process close is observed without blocking');
  finally S.Free; end;

  T := TCatalogProcessTransport.Create;
  S := TCatalogSession.Create(T, true);
  try
    Check(S.Start(PythonPath, AdapterPath), 'reopened session creates a fresh owned child');
    PollUntil(S, 'Sign-in required', 300);
    Check(not S.Authenticated, 'reopened process does not inherit previous auth state');
    S.Close;
    for I := 1 to 300 do
    begin
      S.Poll;
      if not S.HelperRunning then Break;
      Sleep(5);
    end;
    Check(not S.HelperRunning, 'reopened inert child also exits cleanly');
  finally S.Free; end;
end;

procedure TestNonreaderQueueAndHide(const PythonPath, NonreaderPath: string);
var T, Sentinel: TCatalogProcessTransport; S: TCatalogSession; I, PID, SentinelPID: integer; Started: QWord; ProbeResult, ProbeError: LongInt;
begin
  T := TCatalogProcessTransport.Create;
  Sentinel := TCatalogProcessTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Sentinel.Start(PythonPath, NonreaderPath);
    T.Start(PythonPath, NonreaderPath);
    PID := T.OwnedProcessID;
    Check((PID > 0) and T.Running, 'nonreader child starts as an exact owned process');
    Started := GetTickCount64;
    T.SendLine(UTF8String(StringOfChar('x', 32000)));
    T.ReadAvailable(16384); // at most 4096 bytes drain; the child never reads stdin
    // 32001 + 32001 fits the queue; the final 8001 bytes overflows it even after one partial write.
    T.SendLine(UTF8String(StringOfChar('y', 32000)));
    try
      T.SendLine(UTF8String(StringOfChar('z', 8000)));
      Check(false, 'outbound queue rejects capacity overflow');
    except
      Check(true, 'outbound queue is bounded');
    end;
    S.Close; // queue is full, so close takes the exact-child termination fallback
    S.ForceTerminate; // same action as screen hide; never joins or waits
    Check(GetTickCount64 - Started < 500, 'full-pipe hide/close returns without blocking UI');
    for I := 1 to 200 do
    begin
      if not T.Running then Break;
      Sleep(5);
    end;
    Check(not T.Running, 'hide kills the exact nonreader helper within a bounded interval');
    Check(Sentinel.Running, 'cleanup leaves an unrelated child process running');
    {$IFDEF UNIX}
    Check(fpGetPid <> PID, 'termination target is not the game process');
    {$ENDIF}
  finally
    S.Free; T.Free;
    Sentinel.TerminateOwned;
    Sentinel.Free;
  end;

  {$IFDEF LINUX}
  // Verify the hidden-screen path without calling session Poll or transport
  // Running after SIGKILL. kill(pid, 0) still succeeds for a zombie, so ESRCH
  // demonstrates that the independent waitpid monitor actually reaped it.
  T := TCatalogProcessTransport.Create;
  Sentinel := TCatalogProcessTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Sentinel.Start(PythonPath, NonreaderPath);
    SentinelPID := Sentinel.OwnedProcessID;
    T.Start(PythonPath, NonreaderPath);
    PID := T.OwnedProcessID;
    Check((PID > 0) and (SentinelPID > 0), 'reaper fixtures start with exact child PIDs');
    S.Close;
    S.ForceTerminate; // exact same nonblocking call used by screen hide
    ProbeResult := 0;
    ProbeError := 0;
    for I := 1 to 200 do
    begin
      ProbeResult := fpKill(PID, 0);
      if ProbeResult <> 0 then
      begin ProbeError := fpgeterrno; Break; end;
      Sleep(5);
    end;
    Check((ProbeResult <> 0) and (ProbeError = ESysESRCH),
          'hidden child is reaped without any further session Poll');
    Check(fpKill(SentinelPID, 0) = 0, 'hidden-child reaping leaves unrelated child running');
  finally
    S.Free; T.Free;
    Sentinel.TerminateOwned;
    Sentinel.Free;
  end;
  {$ENDIF}
end;

procedure TestClosedStdinIsContained(const PythonPath, ClosedPipePath: string);
var T: TCatalogProcessTransport; Started: QWord; I: integer; OutputText: UTF8String;
begin
  T := TCatalogProcessTransport.Create;
  try
    T.Start(PythonPath, ClosedPipePath);
    OutputText := '';
    for I := 1 to 100 do
    begin
      OutputText := OutputText + T.ReadAvailable(16384);
      if Pos('stdin-closed', string(OutputText)) > 0 then Break;
      Sleep(5);
    end;
    Check(Pos('stdin-closed', string(OutputText)) > 0, 'closed-stdin fixture reached its open-pipe state');
    Check(T.Running, 'closed-stdin helper remains alive before the attempted write');
    Started := GetTickCount64;
    T.SendLine('{}');
    T.ReadAvailable(16384); // pumps a nonblocking write that receives EPIPE
    Check(GetTickCount64 - Started < 500, 'closed-stdin EPIPE is handled without blocking');
    Check(T.FailureMessage <> '', 'closed helper pipe becomes an honest transport failure');
    Check(T.Running, 'SIGPIPE does not terminate the game/test process or child early');
    T.TerminateOwned;
    for I := 1 to 200 do
    begin
      if not T.Running then Break;
      Sleep(5);
    end;
    Check(not T.Running, 'closed-stdin fixture is terminated by owned-handle cleanup');
  finally T.Free; end;
end;

procedure TestActualAdapter(const PythonPath, AdapterPath: string);
var T: TCatalogProcessTransport; S: TCatalogSession; I: integer;
begin
  T := TCatalogProcessTransport.Create;
  S := TCatalogSession.Create(T, true);
  try
    Check(S.Start(PythonPath, AdapterPath), 'actual adapter starts with the explicit interpreter');
    PollUntil(S, 'Sign-in required', 300);
    Check(not S.Authenticated and not S.DownloadsEnabled, 'actual adapter status is signed out and download-disabled');
    S.Close; // The adapter's status and quit operations do not contact the network.
    for I := 1 to 300 do
    begin
      S.Poll;
      if not S.HelperRunning then Break;
      Sleep(5);
    end;
    Check(not S.HelperRunning, 'actual adapter exits after the separate quit request');
  finally S.Free; end;
end;

procedure TestOwnedTermination(const PythonPath, AdapterPath: string);
var T: TCatalogProcessTransport; I: integer; Started: QWord;
begin
  T := TCatalogProcessTransport.Create;
  try
    T.Start(PythonPath, AdapterPath); // inert child waits on stdin
    Check(T.Running, 'owned helper is initially running');
    Started := GetTickCount64;
    T.TerminateOwned;
    Check(GetTickCount64 - Started < 500, 'owned-child cleanup request is nonblocking');
    for I := 1 to 300 do
    begin
      if not T.Running then Break;
      Sleep(5);
    end;
    Check(not T.Running, 'only the owned helper process is terminated');
  finally T.Free; end;
end;

var PythonPath, AdapterPath: string;
begin
  if (ParamCount = 3) and (ParamStr(3) = '--ordinal-regression') then
  begin
    PythonPath := ParamStr(1);
    AdapterPath := ParamStr(2);
    TestFakeTransport(PythonPath, AdapterPath);
    WriteLn('PASS: ', Assertions, ' focused catalog ID/array-index assertions');
    Halt(0);
  end;
  if ParamCount <> 5 then
  begin
    WriteLn('Usage: catalog_bridge_test <absolute-python> <absolute-inert-child.py> <absolute-adapter.py> <absolute-nonreader.py> <absolute-closed-stdin.py>');
    Halt(2);
  end;
  PythonPath := ParamStr(1);
  AdapterPath := ParamStr(2);
  TestFakeTransport(PythonPath, AdapterPath);
  TestOversized(PythonPath, AdapterPath);
  TestCloseDuringStatus(PythonPath, AdapterPath);
  TestCloseActiveSearch(PythonPath, AdapterPath);
  TestWrongEventKind(PythonPath, AdapterPath);
  TestReauthenticationFailure(PythonPath, AdapterPath);
  TestInvalidLoginResponses(PythonPath, AdapterPath);
  TestUnsafeCapability(PythonPath, AdapterPath);
  TestBusyError(PythonPath, AdapterPath);
  TestMalformedJSONTypes(PythonPath, AdapterPath);
  TestTimeoutAndUnexpectedExit(PythonPath, AdapterPath);
  TestChildProcess(PythonPath, AdapterPath);
  TestNonreaderQueueAndHide(PythonPath, ParamStr(4));
  {$IFDEF UNIX}TestClosedStdinIsContained(PythonPath, ParamStr(5));{$ENDIF}
  TestOwnedTermination(PythonPath, ParamStr(2));
  TestActualAdapter(PythonPath, ParamStr(3));
  WriteLn('PASS: ', Assertions, ' catalog bridge assertions');
end.
