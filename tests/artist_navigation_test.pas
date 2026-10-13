program ArtistNavigationTest;
{$mode objfpc}{$H+}{$codepage utf8}
uses UArtistNavigation;
var Targets: TArtistTargets; I: Integer;
procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then begin WriteLn('FAIL: ', MessageText); Halt(1); end;
end;
begin
  Check(ArtistBucket('ABBA') = 1, 'uppercase artist');
  Check(ArtistBucket('  beatles') = 2, 'leading spaces and lowercase');
  Check(ArtistBucket('Zebra') = 26, 'last letter');
  Check(ArtistBucket('123') = 0, 'digits bucket');
  Check(ArtistBucket('') = 0, 'empty artist safe');
  Check(ArtistBucket('東京') = 0, 'non-Latin safe');
  Check(ArtistBucket('Eclair') = 5, 'uses caller accent-normalized artist');
  for I := 0 to ArtistBucketCount - 1 do Targets[I] := -1;
  Check(NextArtistBucket(Targets, 1, 1) = -1, 'empty filtered library');
  Targets[1] := 0; Targets[3] := 2; Targets[26] := 9;
  Check(NextArtistBucket(Targets, 1, 1) = 3, 'skip empty B');
  Check(NextArtistBucket(Targets, 3, -1) = 1, 'previous letter');
  Check(NextArtistBucket(Targets, 26, 1) = 1, 'forward wrap');
  Check(NextArtistBucket(Targets, 1, -1) = 26, 'backward wrap');
  Check(NextArtistBucket(Targets, -1, 1) = -1, 'invalid lower bound');
  Check(NextArtistBucket(Targets, 27, 1) = -1, 'invalid upper bound');
  Check(NextArtistBucket(Targets, 1, 0) = -1, 'zero direction');
  Targets[3] := -1; Targets[26] := -1;
  Check(NextArtistBucket(Targets, 1, 1) = 1, 'single nonempty bucket');
  Targets[0] := 4;
  Check(NextArtistBucket(Targets, 1, -1) = 0, 'miscellaneous bucket reachable');
  WriteLn('PASS: 17 artist navigation assertions');
end.
