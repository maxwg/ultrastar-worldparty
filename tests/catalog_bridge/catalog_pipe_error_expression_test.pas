program CatalogPipeErrorExpressionTest;
{$mode delphi}{$H+}

function IsPortablePendingPipeWriteError(ErrorCode: LongWord): boolean;
begin
  Result := (ErrorCode = 232) or (ErrorCode = 997) or (ErrorCode = 536);
end;

procedure Check(Value: boolean; const MessageText: string);
begin
  if not Value then
  begin
    WriteLn('FAIL: ', MessageText);
    Halt(1);
  end;
end;

begin
  // Win32 values ERROR_NO_DATA, ERROR_IO_PENDING, ERROR_PIPE_LISTENING.
  // This program compiles the portable expression that the Windows-only branch
  // calls, covering values that cannot be represented in a Pascal byte set.
  Check(IsPortablePendingPipeWriteError(232), 'ERROR_NO_DATA matches');
  Check(IsPortablePendingPipeWriteError(997), 'ERROR_IO_PENDING matches');
  Check(IsPortablePendingPipeWriteError(536), 'ERROR_PIPE_LISTENING matches');
  Check(not IsPortablePendingPipeWriteError(231), 'unrelated code rejected');
  Check(not IsPortablePendingPipeWriteError(0), 'success code rejected');
  WriteLn('PASS: portable Windows pipe error equality expression');
end.
