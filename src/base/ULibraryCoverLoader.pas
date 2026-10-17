unit ULibraryCoverLoader;
{$mode objfpc}{$H+}
interface
uses Classes, SyncObjs, sdl2;
type
  TLibraryCoverPaths = array of UTF8String;
  TLibraryCoverLoader = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FPaths: TLibraryCoverPaths;
    FRevision: LongInt;
    FDecoded: LongInt;
    FReady: boolean;
    FSurface: PSDL_Surface;
    FKey: UTF8String;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetPage(const Paths: TLibraryCoverPaths);
    function TryTake(out Key: UTF8String; out Surface: PSDL_Surface): boolean;
    function DecodeCount: LongInt;
  end;
implementation
uses Math, SysUtils, SDL2_image;
constructor TLibraryCoverLoader.Create;
begin
  inherited Create(true); FreeOnTerminate := false; Priority := tpLower;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, false, false, ''); Start;
end;
destructor TLibraryCoverLoader.Destroy;
begin
  Terminate;
  if Assigned(FWake) then FWake.SetEvent;
  WaitFor;
  if Assigned(FSurface) then SDL_FreeSurface(FSurface);
  FWake.Free; FLock.Free; inherited;
end;
procedure TLibraryCoverLoader.SetPage(const Paths: TLibraryCoverPaths);
begin
  FLock.Acquire;
  try
    FPaths := Copy(Paths); Inc(FRevision);
    if Assigned(FSurface) then SDL_FreeSurface(FSurface);
    FSurface := nil; FReady := false;
  finally FLock.Release; end;
  FWake.SetEvent;
end;
function TLibraryCoverLoader.TryTake(out Key: UTF8String; out Surface: PSDL_Surface): boolean;
begin
  FLock.Acquire;
  try
    Result := FReady;
    if Result then begin
      Key := FKey; Surface := FSurface; FSurface := nil; FReady := false;
    end;
  finally FLock.Release; end;
  if Result then FWake.SetEvent;
end;
function TLibraryCoverLoader.DecodeCount: LongInt;
begin Result := InterlockedCompareExchange(FDecoded, 0, 0); end;

function DecodeThumbnail(const Path: UTF8String): PSDL_Surface;
var Source: PSDL_Surface; Crop: TSDL_Rect; Side: integer;
begin
  Result := nil;
  {$IFDEF LIBRARY_E2E}Sleep(50);{$ENDIF} // Exercise typing during deliberately slow IO.
  // No ULog/global texture manager from the worker, including for missing art.
  Source := IMG_Load(PChar(Path));
  if not Assigned(Source) then Exit;
  try
    Side := Min(Source^.w, Source^.h);
    if Side <= 0 then Exit;
    Crop.x := (Source^.w - Side) div 2; Crop.y := (Source^.h - Side) div 2;
    Crop.w := Side; Crop.h := Side;
    Result := SDL_CreateRGBSurface(0, 256, 256, 24, $FF, $FF00, $FF0000, 0);
    if Assigned(Result) and (SDL_UpperBlitScaled(Source, @Crop, Result, nil) <> 0) then begin
      SDL_FreeSurface(Result); Result := nil;
    end;
  finally SDL_FreeSurface(Source); end;
end;
procedure TLibraryCoverLoader.Execute;
var Paths: TLibraryCoverPaths; Revision, I: integer; Surface: PSDL_Surface;
  Waiting, Stale: boolean;
begin
  Revision := -1; I := 0;
  while not Terminated do begin
    FLock.Acquire;
    try
      Stale := Revision <> FRevision;
      if Stale then begin Paths := FPaths; Revision := FRevision; I := 0; end;
      Waiting := FReady or (I >= Length(Paths));
    finally FLock.Release; end;
    if Waiting then begin FWake.WaitFor(100); Continue; end;
    InterlockedIncrement(FDecoded); Surface := DecodeThumbnail(Paths[I]);
    FLock.Acquire;
    try
      if not Terminated and (Revision = FRevision) then begin
        FSurface := Surface; Surface := nil; FKey := Paths[I]; FReady := true;
      end;
    finally FLock.Release; end;
    if Assigned(Surface) then SDL_FreeSurface(Surface);
    Inc(I);
  end;
end;
end.
