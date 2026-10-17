program CatalogBridgeTest;
{$mode delphi}{$H+}
// Match WorldParty.dpr's Unix Unicode manager for escaped JSON metadata.
uses {$IFDEF UNIX}cthreads, cwstring,{$ENDIF} SysUtils, Classes, fpjson, jsonparser, USongCatalogBridge
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  TFakeTransport = class(TCatalogTransport)
  public
    Active: boolean;
    Terminated: boolean;
    StartedPython, StartedAdapter, StartedCredentials: string;
    Requests: TStringList;
    Incoming: UTF8String;
    Failure: string;
    FailWrites: boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Start(const PythonPath, AdapterPath: string; const CredentialsPath: string = ''); override;
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

procedure TFakeTransport.Start(const PythonPath, AdapterPath: string; const CredentialsPath: string);
begin
  StartedPython := PythonPath;
  StartedAdapter := AdapterPath;
  StartedCredentials := CredentialsPath;
  Active := true;
end;

procedure TFakeTransport.SendLine(const Line: UTF8String);
begin
  if FailWrites then raise Exception.Create('fixture write failure');
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

function ContainsBytes(const Haystack, Needle: UTF8String): boolean;
// Byte-level containment. Windows AnsiString Pos() re-encodes differently
// codepage-tagged operands and can miss matching raw bytes, so compare the
// payloads directly.
var Position, Offset: integer;
begin
  Result := false;
  if Length(Needle) = 0 then Exit(true);
  if Length(Needle) > Length(Haystack) then Exit;
  for Position := 1 to Length(Haystack) - Length(Needle) + 1 do
  begin
    Result := true;
    for Offset := 0 to Length(Needle) - 1 do
      if Haystack[Position + Offset] <> Needle[Offset + 1] then
      begin
        Result := false;
        Break;
      end;
    if Result then Exit;
  end;
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

procedure StartReadyFake(const PythonPath, AdapterPath: string;
  out T: TFakeTransport; out S: TCatalogSession; const AuthState: string = 'signed_in';
  const DetailsCapability: string = 'true');
var O: TJSONObject; RequestID: string;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  Check(S.Start(PythonPath, AdapterPath), 'source-details fixture starts');
  O := RequestAt(T, 0);
  try RequestID := O.Get('request_id', ''); finally O.Free; end;
  T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"%s","session_scope":"process_memory_only","busy":false,"capabilities":{"details":%s,"download":false}}'#10,
    [RequestID, AuthState, DetailsCapability]));
  S.Poll;
end;

function SeedCurrentResults(T: TFakeTransport; S: TCatalogSession): string;
var O: TJSONObject;
begin
  Check(S.Search('fixture artist', 'fixture title'), 'source-details fixture search begins');
  O := RequestAt(T, T.Requests.Count - 1);
  try Result := O.Get('request_id', ''); finally O.Free; end;
  T.Push(Format('{"type":"results","protocol_version":1,"request_id":"%s","songs":[{"id":2147483648,"artist":"Beyonc\u00e9","title":"Part: 2","language":"Fran\u00e7ais"},{"id":9223372036854775807,"artist":"Other","title":"Maximum ID"}]}'#10, [Result]));
  T.Push(Format('{"type":"idle","protocol_version":1,"request_id":"%s"}'#10, [Result]));
  S.Poll;
  Check((S.ResultCount = 2) and (S.Results.Count = 2) and not S.Busy,
    'typed and display result collections publish together');
end;

function StartSelectedDetails(T: TFakeTransport; S: TCatalogSession): string;
var O: TJSONObject;
begin
  Check(S.Details(S.ResultItems[0].SongID), 'current typed result starts source-details request');
  O := RequestAt(T, T.Requests.Count - 1);
  try Result := O.Get('request_id', ''); finally O.Free; end;
end;

procedure TestDeadSessionActionGates(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; BeforeCount: integer;
begin
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    BeforeCount := T.Requests.Count;
    T.Active := false; // No Poll: an operation must check the live helper itself.
    Check(not S.Search('fixture', 'fixture'), 'dead helper rejects search before another Poll');
    Check(T.Requests.Count = BeforeCount, 'dead helper receives no new protocol request');
    Check(not S.Authenticated, 'dead helper action gate clears stale authentication');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S, 'signed_out');
  try
    BeforeCount := T.Requests.Count; T.Active := false;
    Check(not S.Login('fixture-user', 'fixture-password'), 'dead signed-out helper rejects sign-in before another Poll');
    Check(T.Requests.Count = BeforeCount, 'dead signed-out helper receives no sign-in request or credentials');
  finally S.Free; T.Free; end;
end;

procedure TestResultSelectionBounds(const PythonPath, AdapterPath: string);
const Counts: array[0..2] of integer = (0, 30, 31);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject;
  CaseIndex, I, ExpectedCount: integer; SearchID, Rows: string;
begin
  for CaseIndex := Low(Counts) to High(Counts) do
  begin
    StartReadyFake(PythonPath, AdapterPath, T, S);
    try
      Check(S.Search('fixture', 'fixture'), 'bounded selection fixture starts search');
      O := RequestAt(T, T.Requests.Count - 1);
      try SearchID := O.Get('request_id', ''); finally O.Free; end;
      Rows := '';
      for I := 1 to Counts[CaseIndex] do
      begin
        if I > 1 then Rows := Rows + ',';
        Rows := Rows + Format('{"id":%d,"artist":"fixture","title":"row"}', [I]);
      end;
      T.Push(Format('{"type":"results","protocol_version":1,"request_id":"%s","songs":[%s]}'#10, [SearchID, Rows]));
      T.Push(Format('{"type":"idle","protocol_version":1,"request_id":"%s"}'#10, [SearchID])); S.Poll;
      ExpectedCount := Counts[CaseIndex]; if ExpectedCount > 30 then ExpectedCount := 30;
      Check((S.ResultCount = ExpectedCount) and (S.Results.Count = ExpectedCount) and
        (S.ErrorCode = '') and not S.Busy, 'zero/30/31 rows preserve bounded first-30 display and typed API');
      if ExpectedCount > 0 then
        Check(S.ResultItems[ExpectedCount - 1].SongID = ExpectedCount, 'last retained typed ID matches display row boundary');
    finally S.Free; T.Free; end;
  end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S);
    Check(S.Search('replacement', 'fixture'), 'atomic result replacement starts search');
    O := RequestAt(T, T.Requests.Count - 1);
    try SearchID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"results","protocol_version":1,"request_id":"%s","songs":[{"id":1,"artist":"valid","title":"first"},{"id":2,"artist":false,"title":"invalid"}]}'#10, [SearchID])); S.Poll;
    Check((S.ErrorCode = 'protocol_error') and (S.ResultCount = 0) and (S.Results.Count = 0),
      'malformed later row publishes neither partial typed metadata nor display rows');
  finally S.Free; T.Free; end;
end;

procedure TestSourceDetails(const PythonPath, AdapterPath: string);
const Link = 'https://www.youtube.com/watch?v=ABCDEFGHIJK';
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject;
  SearchID, DetailID: string; BeforeCount: integer;
begin
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    Check(S.DetailsSupported and not S.DownloadsEnabled, 'source details support does not enable downloads');
    SearchID := SeedCurrentResults(T, S);
    Check((S.ResultItems[0].SongID = Int64(2147483648)) and
      (S.ResultItems[1].SongID = High(Int64)), 'typed catalog IDs preserve the full positive Int64 range');
    Check((Pos('Beyonc', S.ResultItems[0].Artist) = 1) and
      (Length(S.ResultItems[0].Artist) = 8) and (S.ResultItems[0].Title = 'Part: 2'),
      'typed metadata preserves UTF-8 and colons independently of display formatting');
    Check(ContainsBytes(S.Results[0], S.ResultItems[0].Artist),
      'display rows preserve the exact UTF-8 artist bytes from typed metadata');
    S.Results[0] := 'truncated display with no ID';
    DetailID := StartSelectedDetails(T, S);
    O := RequestAt(T, T.Requests.Count - 1);
    try
      Check((O.Get('op', '') = 'details') and (O.Get('protocol_version', 0) = 1), 'details uses existing v1 operation');
      Check((O.Find('id').JSONType = jtNumber) and not (O.Find('id') is TJSONFloatNumber) and
        (O.Find('id').AsInt64 = Int64(2147483648)), 'selected ID is a JSON integer, never a string');
      Check((O.Count = 4) and (O.Find('url') = nil) and (O.Find('root') = nil) and
        (O.Find('password') = nil), 'details sends only version, correlation, operation and numeric ID');
      Check(DetailID <> SearchID, 'details has its own request correlation');
    finally O.Free; end;
    BeforeCount := T.Requests.Count;
    Check(not S.Details(S.ResultItems[1].SongID), 'repeated activation is blocked while details is pending');
    Check(T.Requests.Count = BeforeCount, 'repeated activation sends no second request');
    T.Push('{"type":"details","protocol_version":1,"request_id":"stale-details","id":42,"links":["https://untrusted.invalid/"]}'#10);
    S.Poll;
    Check(S.Busy and (S.DetailSongID = 0) and (S.DetailLinks.Count = 0), 'stale details do not change the selected result');
    T.Push(Format('{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":["%s"]}'#10, [DetailID, Link]));
    S.Poll;
    Check(S.Busy and (S.DetailSongID = Int64(2147483648)) and (S.DetailLinks.Count = 1) and
      (S.DetailLinks[0] = Link), 'valid correlated source details publish without completing before idle');
    T.Push(Format('{"type":"idle","protocol_version":1,"request_id":"%s"}'#10, [DetailID]));
    S.Poll;
    Check(not S.Busy and (S.ErrorCode = '') and not S.DownloadsEnabled, 'details completion stays download-disabled');
    Check(S.Details(S.ResultItems[1].SongID), 'maximum Int64 result can request details');
    O := RequestAt(T, T.Requests.Count - 1);
    try
      DetailID := O.Get('request_id', '');
      Check(O.Find('id').AsInt64 = High(Int64), 'maximum Int64 request is not narrowed on serialization');
    finally O.Free; end;
    T.Push(Format('{"type":"details","protocol_version":1,"request_id":"%s","id":9223372036854775807,"links":[]}'#10, [DetailID]));
    T.Push(Format('{"type":"idle","protocol_version":1,"request_id":"%s"}'#10, [DetailID]));
    S.Poll;
    Check((S.DetailSongID = High(Int64)) and (S.DetailLinks.Count = 0) and not S.Busy,
      'empty media-source list is valid, without reusing a previous result link');
    Check(S.Search('new', 'query'), 'new search begins after source details');
    Check((S.DetailSongID = 0) and (S.DetailLinks.Count = 0) and (S.ResultCount = 0),
      'new search clears prior selection data and source details');
  finally S.Free; T.Free; end;
end;

procedure TestSourceDetailsGates(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; BeforeCount: integer;
begin
  T := TFakeTransport.Create; S := TCatalogSession.Create(T, false);
  try
    Check(not S.Details(42) and (T.Requests.Count = 0), 'unstarted session cannot request details');
    Check(S.Start(PythonPath, AdapterPath), 'pending-status gate fixture starts');
    BeforeCount := T.Requests.Count;
    Check(not S.Details(42) and (T.Requests.Count = BeforeCount), 'details cannot race ahead of initial status');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S, 'signed_out');
  try
    BeforeCount := T.Requests.Count;
    Check(not S.Details(42) and (T.Requests.Count = BeforeCount), 'signed-out details sends no request');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S, 'signed_in', 'false');
  try
    SeedCurrentResults(T, S); BeforeCount := T.Requests.Count;
    Check(not S.Details(S.ResultItems[0].SongID) and (T.Requests.Count = BeforeCount),
      'adapter must explicitly advertise source-details support');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S, 'signed_in', '"true"');
  try
    Check((S.ErrorCode = 'protocol_error') and T.Terminated and not S.DetailsSupported,
      'wrong-typed details capability fails closed');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); BeforeCount := T.Requests.Count;
    Check(not S.Details(0) and not S.Details(-1) and not S.Details(42), 'only a positive ID in current results can be selected');
    Check(T.Requests.Count = BeforeCount, 'invalid and absent IDs produce no protocol request');
    T.Active := false;
    Check(not S.Details(Int64(2147483648)) and not S.Authenticated and
      (T.Requests.Count = BeforeCount), 'dead helper cannot accept details before Poll observes its exit');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); S.ForceTerminate; BeforeCount := T.Requests.Count;
    Check(not S.Details(Int64(2147483648)) and (T.Requests.Count = BeforeCount), 'terminated session cannot request details');
    Check((S.ResultCount = 0) and (S.DetailSongID = 0), 'termination clears typed selection data');
  finally S.Free; T.Free; end;
end;

procedure TestInvalidSourceDetails(const PythonPath, AdapterPath: string);
const Frames: array[0..17] of string = (
  '{"type":"details","protocol_version":1,"request_id":"%s","id":"2147483648","links":[]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648.0,"links":[]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":true,"links":[]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":-1,"links":[]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":42,"links":[]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":9223372036854775808,"links":[]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","links":[]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":{}}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":[null]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":[4]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":["http://www.youtube.com/watch?v=ABCDEFGHIJK"]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":["https://untrusted.invalid/"]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":["https://www.youtube.com/watch?v=ABCDEFGHIJKextra"]}',
  '{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":["https://www.youtube.com/watch?v=ABCDEFGHIJK","bad"]}',
  '{"type":"idle","protocol_version":1,"request_id":"%s"}',
  '{"type":"details","protocol_version":2,"request_id":"%s","id":2147483648,"links":[]}',
  '{"type":"results","protocol_version":1,"request_id":"%s","songs":[]}'
);
var I, J, BeforeCount: integer; T: TFakeTransport; S: TCatalogSession;
  DetailID, LinkArray: string;
begin
  for I := Low(Frames) to High(Frames) do
  begin
    StartReadyFake(PythonPath, AdapterPath, T, S);
    try
      SeedCurrentResults(T, S); DetailID := StartSelectedDetails(T, S);
      T.Push(UTF8String(Format(Frames[I] + #10, [DetailID]))); S.Poll;
      Check((S.ErrorCode = 'protocol_error') and T.Terminated and not S.Busy and not S.Authenticated,
        'wrong source-detail ID/type/shape/operation/version fails closed, case ' + IntToStr(I));
      Check((S.DetailSongID = 0) and (S.DetailLinks.Count = 0) and (S.ResultCount = 0),
        'invalid detail frame never publishes partial source or selection data');
      BeforeCount := T.Requests.Count;
      Check(not S.Details(Int64(2147483648)) and (T.Requests.Count = BeforeCount), 'protocol-failed session cannot be reused');
    finally S.Free; T.Free; end;
  end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); DetailID := StartSelectedDetails(T, S);
    LinkArray := '';
    for J := 1 to 31 do
    begin
      if J > 1 then LinkArray := LinkArray + ',';
      LinkArray := LinkArray + '"https://www.youtube.com/watch?v=ABCDEFGHIJK"';
    end;
    T.Push(Format('{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":[%s]}'#10, [DetailID, LinkArray]));
    S.Poll;
    Check((S.ErrorCode = 'protocol_error') and (S.DetailLinks.Count = 0), 'source-link collection is explicitly bounded');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); DetailID := StartSelectedDetails(T, S);
    T.Push(Format('{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":[],"padding":"%s"}'#10, [DetailID, StringOfChar('x', 65537)]));
    for J := 1 to 6 do S.Poll;
    Check((S.ErrorCode = 'protocol_error') and T.Terminated and (S.DetailSongID = 0), 'oversized source-detail frame cannot publish data');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); DetailID := StartSelectedDetails(T, S);
    for J := 1 to 2 do
      T.Push(Format('{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":[]}'#10, [DetailID]));
    S.Poll;
    Check((S.ErrorCode = 'protocol_error') and (S.DetailSongID = 0), 'duplicate details payload fails closed before idle');
  finally S.Free; T.Free; end;
end;

procedure TestSourceDetailsLifecycle(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject;
  DetailID, QuitID: string; BeforeCount: integer;
begin
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); DetailID := StartSelectedDetails(T, S);
    T.Push(Format('{"type":"error","protocol_version":1,"request_id":"%s","code":"authentication_required"}'#10, [DetailID])); S.Poll;
    Check(not S.Busy and not S.Authenticated and (S.DetailSongID = 0) and
      (S.ErrorCode = 'authentication_required'), 'expired details session clears authentication and pending data');
    BeforeCount := T.Requests.Count;
    Check(not S.Details(Int64(2147483648)) and (T.Requests.Count = BeforeCount), 'expired session requires new explicit sign-in');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); StartSelectedDetails(T, S); S.PollAt(High(QWord));
    Check((S.ErrorCode = 'request_timeout') and T.Terminated and not S.Busy and
      not S.Authenticated and (S.DetailSongID = 0), 'details deadline terminates only the owned helper and clears state');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); StartSelectedDetails(T, S); T.Active := false; S.Poll;
    Check((S.ErrorCode = 'helper_exited') and not S.Busy and not S.Authenticated,
      'helper exit during details does not leave the session busy');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); StartSelectedDetails(T, S); T.Failure := 'fixture transport failure'; S.Poll;
    Check((S.ErrorCode = 'transport_failed') and T.Terminated and (S.DetailSongID = 0),
      'details transport failure clears pending and visible source data');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); T.FailWrites := true;
    Check(not S.Details(Int64(2147483648)) and (S.ErrorCode = 'request_write_failed') and
      T.Terminated and not S.Busy and not S.Authenticated and (S.DetailSongID = 0),
      'details write failure terminates the helper and clears pending authentication/data');
  finally S.Free; T.Free; end;
  StartReadyFake(PythonPath, AdapterPath, T, S);
  try
    SeedCurrentResults(T, S); DetailID := StartSelectedDetails(T, S); S.Close;
    O := RequestAt(T, T.Requests.Count - 1);
    try QuitID := O.Get('request_id', ''); finally O.Free; end;
    Check(QuitID <> DetailID, 'closing details sends an independently correlated quit');
    BeforeCount := T.Requests.Count;
    Check(not S.Details(Int64(2147483648)) and (T.Requests.Count = BeforeCount), 'closing session rejects new source requests');
    T.Push(Format('{"type":"details","protocol_version":1,"request_id":"%s","id":2147483648,"links":[]}'#10, [DetailID]));
    T.Push(Format('{"type":"control_ack","protocol_version":1,"request_id":"%s","command":"quit","accepted":true,"target_request_id":"%s"}'#10, [QuitID, DetailID]));
    S.Poll;
    Check((S.ErrorCode = '') and (Pos('acknowledged', S.Status) > 0) and (S.DetailSongID = 0),
      'late details cannot republish after close; quit acknowledgement matches active details target');
    S.ForceTerminate;
    Check(T.Terminated and (S.ResultCount = 0) and (S.DetailLinks.Count = 0), 'hide/terminate clears source and selection state');
  finally S.Free; T.Free; end;
end;

procedure TestOutboundEscaping(const PythonPath, AdapterPath: string);
// Locks the single-wire-escape contract: typed UTF-8 values reach the helper
// as one layer of \uXXXX text, never as double-escaped literal backslash-u.
// The raw request line is compared directly because the FPC win32 JSON
// parser corrupts \uXXXX escapes above U+007F while decoding fixtures.
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject;
  StatusID: string; RawLine: UTF8String; Raw: RawByteString; ArtistRaw: UTF8String;
begin
  T := TFakeTransport.Create;
  S := TCatalogSession.Create(T, false);
  try
    Check(S.Start(PythonPath, AdapterPath), 'wire session starts');
    O := RequestAt(T, 0);
    try StatusID := O.Get('request_id', ''); finally O.Free; end;
    T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [StatusID]));
    S.Poll;
    // 'Fa' + U+00E7 + 'ade Test': build the exact UTF-8 byte sequence and tag
    // it CP_UTF8 without conversion so the bytes reach the bridge unaltered.
    Raw := 'Fa' + AnsiChar(195) + AnsiChar(167) + 'ade Test';
    SetCodePage(Raw, 65001, false);
    ArtistRaw := UTF8String(Raw);
    Check(S.Search(ArtistRaw, 'Fixture'), 'accented search request starts');
    RawLine := T.Requests[T.Requests.Count - 1];
    Check(ContainsBytes(RawLine, '{"protocol_version":1,"request_id":"worldparty-2","op":"search","artist":"Fa\u00E7ade Test","title":"Fixture"}'),
      'accented artist reaches the wire as a single \uXXXX escape sequence');
    Check(not ContainsBytes(RawLine, '\\u00E7'),
      'accented artist is never double-escaped on the wire');
  finally S.Free; T.Free; end;
end;

procedure TestStoredLogin(const PythonPath, AdapterPath: string);
const
  FixturePayload = '{"user":"fixture-user","pass":"fixture-pass"}';
var
  T: TFakeTransport; S: TCatalogSession; O: TJSONObject;
  StatusID, LoginID: string; FixPath: string; Payload: RawByteString;
begin
  // Cases that need a real on-disk fixture.
  FixPath := ExtractFilePath(ParamStr(0)) + 'bridge_fixture_credentials.json';
  Payload := FixturePayload;
  with TFileStream.Create(FixPath, fmCreate) do
  try
    if Length(Payload) > 0 then WriteBuffer(Payload[1], Length(Payload));
  finally Free; end;
  try
    // Configured start forwards the credentials file to the transport argv.
    T := TFakeTransport.Create;
    S := TCatalogSession.Create(T, false);
    try
      Check(S.Start(PythonPath, AdapterPath, FixPath), 'stored-credentials session starts');
      Check(T.StartedCredentials = FixPath, 'stored credentials reach the transport');
      Check(S.StoredCredentials = FixPath, 'session remembers stored credentials');
      O := RequestAt(T, 0);
      try StatusID := O.Get('request_id', ''); finally O.Free; end;
      T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_out","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [StatusID]));
      S.Poll;
      Check(not S.Authenticated and not S.Busy, 'stored session is signed out before login');
      // LoginStored sends credentials_file only, never user/password values.
      Check(S.LoginStored, 'stored login request starts');
      O := RequestAt(T, 1);
      try
        LoginID := O.Get('request_id', '');
        Check(O.Get('op', '') = 'login', 'stored login operation is login');
        Check(O.Get('credentials_file', '') = FixPath, 'stored login references the credentials file');
        Check(O.Get('user', '') = '', 'stored login sends no user field');
        Check(O.Get('password', '') = '', 'stored login sends no password field');
      finally O.Free; end;
      T.Push(Format('{"type":"login","protocol_version":1,"request_id":"%s","ok":true,"auth_state":"signed_in"}'#10, [LoginID]));
      S.Poll;
      Check(S.Authenticated and (S.ErrorCode = '') and not S.Busy, 'stored login success authenticates the session');
    finally S.Free; T.Free; end;

    // Empty plain login still refuses to reach the helper.
    T := TFakeTransport.Create;
    S := TCatalogSession.Create(T, false);
    try
      Check(S.Start(PythonPath, AdapterPath), 'plain session starts');
      O := RequestAt(T, 0);
      try StatusID := O.Get('request_id', ''); finally O.Free; end;
      T.Push(Format('{"type":"status","protocol_version":1,"request_id":"%s","auth_state":"signed_out","session_scope":"process_memory_only","busy":false,"capabilities":{"download":false}}'#10, [StatusID]));
      S.Poll;
      Check(S.StoredCredentials = '', 'plain session has no stored credentials');
      Check(not S.LoginStored and (T.Requests.Count = 1), 'unconfigured stored login is refused');
      Check((S.ErrorCode = '') and (Pos('credentials file', string(S.Status)) > 0),
        'unconfigured stored login explains the missing credentials file');
    finally S.Free; T.Free; end;

    // A configured but missing file fails closed before transport start.
    T := TFakeTransport.Create;
    S := TCatalogSession.Create(T, false);
    try
      Check(not S.Start(PythonPath, AdapterPath, FixPath + '.missing'), 'missing credentials file session rejects');
      Check(not T.Active, 'missing credentials file never starts the helper');
      Check((S.ErrorCode = '') and (Pos('file is not available', string(S.Status)) > 0),
        'missing credentials file session explains the unavailable file');
    finally S.Free; T.Free; end;
  finally
    DeleteFile(FixPath);
  end;
end;

procedure TestOptInDownload(const PythonPath, AdapterPath: string);
var T: TFakeTransport; S: TCatalogSession; O: TJSONObject; ID, Root, Link: string;
  procedure Reply(const Kind, Fields: string);
  begin
    T.Push('{"type":"' + Kind + '","protocol_version":1,"request_id":"' + ID + '"' + Fields + '}'#10);
    S.Poll;
  end;
  procedure Latest;
  begin
    O := RequestAt(T, T.Requests.Count - 1);
    try ID := O.Get('request_id', ''); finally O.Free; end;
  end;
begin
  Root := ExpandFileName('fixture-library');
  Link := 'https://www.youtube.com/watch?v=abcDEF123_-';
  T := TFakeTransport.Create; S := TCatalogSession.Create(T, false);
  try
    S.AllowDownloads := true;
    Check(S.Start(PythonPath, AdapterPath), 'opt-in session starts'); Latest;
    Reply('status', ',"auth_state":"signed_in","session_scope":"process_memory_only","busy":false,"capabilities":{"details":true,"download":true}');
    Check(S.DownloadsEnabled, 'explicit opt-in accepts download capability');
    SeedCurrentResults(T, S);
    ID := StartSelectedDetails(T, S);
    Reply('details', ',"id":2147483648,"links":["' + Link + '"]'); Reply('idle', '');
    Check(not S.DownloadSong(2147483648, 'https://example.com', Root), 'unverified source rejected');
    Check(not S.DownloadSong(99, Link, Root), 'wrong selected chart rejected');
    Check(not S.DownloadSong(2147483648, Link, 'relative'), 'relative install root rejected');
    Check(S.DownloadSong(2147483648, Link, Root), 'explicit source download starts'); Latest;
    Check(not S.DownloadSong(2147483648, Link, Root), 'double click cannot start second download');
    Reply('progress', ',"percent":30');
    Check(S.Busy and (S.ErrorCode = ''), 'download progress keeps session alive');
    O := TJSONObject.Create;
    try
      O.Add('type', 'installed'); O.Add('protocol_version', 1); O.Add('request_id', ID);
      O.Add('id', Int64(2147483648));
      O.Add('folder', IncludeTrailingPathDelimiter(Root) + 'USDB-2147483648');
      T.Push(UTF8String(O.AsJSON) + #10); S.Poll;
    finally O.Free; end;
    Reply('idle', '');
    Check(not S.Busy and (S.InstalledFolder <> '') and (S.ErrorCode = ''), 'correlated install completes');
  finally S.Free; T.Free; end;
end;

var PythonPath, AdapterPath: string;
begin
  if (ParamCount = 3) and (ParamStr(3) = '--source-details-regression') then
  begin
    PythonPath := ParamStr(1); AdapterPath := ParamStr(2);
    TestDeadSessionActionGates(PythonPath, AdapterPath);
    TestResultSelectionBounds(PythonPath, AdapterPath);
    TestSourceDetails(PythonPath, AdapterPath);
    TestSourceDetailsGates(PythonPath, AdapterPath);
    TestInvalidSourceDetails(PythonPath, AdapterPath);
    TestSourceDetailsLifecycle(PythonPath, AdapterPath);
    WriteLn('PASS: ', Assertions, ' focused catalog source-details assertions');
    Halt(0);
  end;
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
  TestDeadSessionActionGates(PythonPath, AdapterPath);
  TestResultSelectionBounds(PythonPath, AdapterPath);
  TestSourceDetails(PythonPath, AdapterPath);
  TestSourceDetailsGates(PythonPath, AdapterPath);
  TestInvalidSourceDetails(PythonPath, AdapterPath);
  TestSourceDetailsLifecycle(PythonPath, AdapterPath);
  TestOversized(PythonPath, AdapterPath);
  TestCloseDuringStatus(PythonPath, AdapterPath);
  TestCloseActiveSearch(PythonPath, AdapterPath);
  TestWrongEventKind(PythonPath, AdapterPath);
  TestReauthenticationFailure(PythonPath, AdapterPath);
  TestInvalidLoginResponses(PythonPath, AdapterPath);
  TestStoredLogin(PythonPath, AdapterPath);
  TestOutboundEscaping(PythonPath, AdapterPath);
  TestOptInDownload(PythonPath, AdapterPath);
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
