unit UAudioInputFilter;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

type
  TAudioInputDeviceNames = array of UTF8String;
  TAudioInputDeviceIndices = array of Integer;

function IsRecognizedVirtualAudioInput(const Name: UTF8String): Boolean;
function ShouldShowAudioInputDevice(const Name: UTF8String;
  ShowVirtual, ExistingPreference: Boolean): Boolean;
function FilterVisibleAudioInputDevices(const DeviceNames,
  ActivelyMappedNames: TAudioInputDeviceNames;
  ShowVirtual: Boolean): TAudioInputDeviceIndices;

implementation

uses
  SysUtils;

function IsRecognizedVirtualAudioInput(const Name: UTF8String): Boolean;
const
  Markers: array[0..15] of UTF8String = (
    'loopback', 'stereo mix', 'what u hear', 'what you hear',
    'monitor of ', 'monitor source', 'wave out mix', 'vb-audio',
    'vb cable', 'virtual audio cable', 'virtual cable', 'cable input',
    'cable output', 'voicemeeter', 'soundflower', 'blackhole'
  );
var
  I: Integer;
  LowerName: UTF8String;
begin
  LowerName := LowerCase(Trim(Name));
  for I := Low(Markers) to High(Markers) do
    if Pos(Markers[I], LowerName) > 0 then
      Exit(True);
  Result := False;
end;

function ShouldShowAudioInputDevice(const Name: UTF8String;
  ShowVirtual, ExistingPreference: Boolean): Boolean;
begin
  Result := ShowVirtual or ExistingPreference or
    not IsRecognizedVirtualAudioInput(Name);
end;

function FilterVisibleAudioInputDevices(const DeviceNames,
  ActivelyMappedNames: TAudioInputDeviceNames;
  ShowVirtual: Boolean): TAudioInputDeviceIndices;
var
  DeviceIndex, PreferenceIndex: Integer;
  ExistingPreference: Boolean;
begin
  SetLength(Result, 0);
  for DeviceIndex := 0 to High(DeviceNames) do
  begin
    ExistingPreference := False;
    for PreferenceIndex := 0 to High(ActivelyMappedNames) do
      if ActivelyMappedNames[PreferenceIndex] = Trim(DeviceNames[DeviceIndex]) then
      begin
        ExistingPreference := True;
        Break;
      end;

    if ShouldShowAudioInputDevice(DeviceNames[DeviceIndex], ShowVirtual,
      ExistingPreference) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := DeviceIndex;
    end;
  end;
end;

end.
