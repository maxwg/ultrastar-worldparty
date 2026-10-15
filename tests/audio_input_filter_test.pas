program AudioInputFilterTest;
{$mode objfpc}{$H+}
uses SysUtils, UAudioInputFilter;
var
  Assertions: Integer;
  DeviceNames, ActiveMappedNames: TAudioInputDeviceNames;
  VisibleIndices: TAudioInputDeviceIndices;

procedure Check(Condition: Boolean; const Why: String);
begin
  Inc(Assertions);
  if not Condition then
  begin
    WriteLn('FAIL: ', Why);
    Halt(1);
  end;
end;

begin
  Assertions := 0;
  Check(not IsRecognizedVirtualAudioInput('USB microphone'), 'ordinary device name is not guessed virtual');
  Check(not IsRecognizedVirtualAudioInput('Unknown input'), 'unknown device stays unclassified');
  Check(IsRecognizedVirtualAudioInput('Stereo Mix (Realtek)'), 'stereo mix recognized');
  Check(IsRecognizedVirtualAudioInput('VB-Audio Virtual Cable'), 'virtual cable recognized');
  Check(IsRecognizedVirtualAudioInput('Monitor of Built-in Audio'), 'monitor source recognized');
  Check(not ShouldShowAudioInputDevice('Stereo Mix', False, False), 'virtual hidden by default');
  Check(ShouldShowAudioInputDevice('Stereo Mix', True, False), 'virtual shown when opted in');
  Check(ShouldShowAudioInputDevice('Stereo Mix', False, True), 'saved virtual preference preserved');
  Check(ShouldShowAudioInputDevice('Unknown input', False, False), 'unknown device remains available');

  { BASS device names are unique; only the actively mapped duplicate remains visible. }
  SetLength(DeviceNames, 3);
  DeviceNames[0] := 'Stereo Mix';
  DeviceNames[1] := 'USB microphone';
  DeviceNames[2] := 'Stereo Mix (2)';
  SetLength(ActiveMappedNames, 1);
  ActiveMappedNames[0] := 'Stereo Mix (2)';
  VisibleIndices := FilterVisibleAudioInputDevices(DeviceNames,
    ActiveMappedNames, False);
  Check((Length(VisibleIndices) = 2) and (VisibleIndices[0] = 1) and
    (VisibleIndices[1] = 2), 'active BASS duplicate is retained by its unique name');

  { SDL preserves its raw-name contract, so same-named devices share a saved config. }
  SetLength(DeviceNames, 2);
  DeviceNames[0] := 'Monitor of Built-in Audio';
  DeviceNames[1] := 'Monitor of Built-in Audio';
  SetLength(ActiveMappedNames, 1);
  ActiveMappedNames[0] := 'Monitor of Built-in Audio';
  VisibleIndices := FilterVisibleAudioInputDevices(DeviceNames,
    ActiveMappedNames, False);
  Check((Length(VisibleIndices) = 2) and (VisibleIndices[0] = 0) and
    (VisibleIndices[1] = 1), 'mapped duplicate SDL names remain visible');

  VisibleIndices := FilterVisibleAudioInputDevices(DeviceNames,
    nil, False);
  Check((Length(VisibleIndices) = 0), 'unmapped virtual duplicates stay hidden');

  VisibleIndices := FilterVisibleAudioInputDevices(DeviceNames,
    nil, True);
  Check((Length(VisibleIndices) = 2), 'Show virtual inputs reveals all matches');
  WriteLn('PASS: ', Assertions, ' audio input filter assertions');
end.
