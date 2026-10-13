{ Artist alphabet navigation. UI-independent so the real navigation rules can
  be tested without SDL, audio devices, or a song library. }
unit UArtistNavigation;
{$mode objfpc}{$H+}
interface
const
  ArtistAlphabet = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  ArtistBucketCount = 27;
type
  TArtistTargets = array[0..ArtistBucketCount - 1] of Integer;
function ArtistBucket(const NormalizedArtist: UTF8String): Integer;
function NextArtistBucket(const Targets: TArtistTargets; Current, Direction: Integer): Integer;
implementation
uses SysUtils;
function ArtistBucket(const NormalizedArtist: UTF8String): Integer;
var S: UTF8String; C: Char;
begin
  Result := 0;
  S := Trim(NormalizedArtist);
  if S = '' then Exit;
  C := UpCase(S[1]);
  if (C >= 'A') and (C <= 'Z') then Result := Ord(C) - Ord('A') + 1;
end;
function NextArtistBucket(const Targets: TArtistTargets; Current, Direction: Integer): Integer;
var Step, Candidate: Integer;
begin
  Result := -1;
  if (Current < 0) or (Current >= ArtistBucketCount) or (Direction = 0) then Exit;
  if Direction > 0 then Direction := 1 else Direction := -1;
  for Step := 1 to ArtistBucketCount do
  begin
    Candidate := (Current + Direction * Step + ArtistBucketCount) mod ArtistBucketCount;
    if Targets[Candidate] >= 0 then Exit(Candidate);
  end;
end;
end.
