program ArtistNavigationTest;
{$mode objfpc}{$H+}{$codepage utf8}
uses
  {$IFDEF Unix}
  cwstring,
  {$ENDIF}
  UArtistNavigation, UUnicodeUtils;
var
  Targets: TArtistTargets;
  Entries: TArtistSearchEntries;
  EmptyEntries: TArtistSearchEntries;
  I, Assertions: Integer;
  State: TSearchInputState;
  Transition: TSearchInputTransition;
  SearchText: UTF8String;
procedure Check(Value: Boolean; const MessageText: String);
begin
  Inc(Assertions);
  if not Value then begin WriteLn('FAIL: ', MessageText); Halt(1); end;
end;
begin
  Assertions := 0;
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

  SetLength(Entries, 6);
  Entries[0].Artist := 'Aardvark'; Entries[0].Visible := true; Entries[0].IsCategory := false;
  Entries[1].Artist := 'Björk'; Entries[1].Visible := true; Entries[1].IsCategory := false;
  Entries[2].Artist := 'Category A'; Entries[2].Visible := true; Entries[2].IsCategory := true;
  Entries[3].Artist := 'Adele'; Entries[3].Visible := true; Entries[3].IsCategory := false;
  Entries[4].Artist := '東京'; Entries[4].Visible := true; Entries[4].IsCategory := false;
  Entries[5].Artist := 'Another hidden artist'; Entries[5].Visible := false; Entries[5].IsCategory := false;
  Check(FindArtistPrefixTarget(Entries, 0, 'a') = 3, 'artist prefix starts after current, skipping visible category headers and hidden songs');
  Check(FindArtistPrefixTarget(Entries, 3, 'A') = 0, 'artist prefix wraps and ignores case');
  Check(FindArtistPrefixTarget(Entries, -1, 'b') = 1, 'artist prefix starts at beginning');
  Check(FindArtistPrefixTarget(Entries, 0, '東') = 4, 'Unicode artist prefix');
  Check(FindArtistPrefixTarget(Entries, 0, 'missing') = -1, 'unmatched artist prefix');
  Check(FindArtistPrefixTarget(Entries, 0, '') = -1, 'empty artist prefix');
  Check(FindArtistPrefixTarget(EmptyEntries, 0, 'a') = -1, 'no visible songs');

  Check(IsSearchTextCharacter(Ord('a'), false, false), 'plain printable input is searchable');
  Check(not IsSearchTextCharacter(Ord('a'), true, false), 'Ctrl/Alt/GUI printable shortcuts are preserved');
  Check(IsSearchTextCharacter(Ord('a'), true, true), 'mode modifier allows AltGr printable input');
  Check(not IsSearchTextCharacter(13, false, false), 'control keys are not search characters');
  Check(not IsSearchTextCharacter(0, false, false), 'empty key event is not searchable');
  Check(IsSearchTextCharacter(UCS4Char($00E9), false, false), 'Unicode printable input is searchable');

  State.Active := false;
  State.Text := 'old query';
  Transition := UpdateSearchInput(State, sieCharacter, Ord('a'));
  Check((Transition.Action = siaJumpArtist) and Transition.State.Active and
    (Transition.State.Text = 'a'), 'first character opens search, clears stale query, and jumps');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieCharacter, Ord('b'));
  Check((Transition.Action = siaFilter) and (Transition.State.Text = 'ab'),
    'second character filters the query');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieBackspace, 0);
  Check((Transition.Action = siaJumpArtist) and (Transition.State.Text = 'a'),
    'backspace from two characters restores one-character artist jump');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieBackspace, 0);
  Check((Transition.Action = siaClear) and (Transition.State.Text = ''),
    'backspace from one character clears the filter');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieEscape, 0);
  Check((Transition.Action = siaClose) and not Transition.State.Active and
    (Transition.State.Text = ''), 'Escape clears and closes search');

  State.Active := false;
  State.Text := 'stale query';
  Transition := UpdateSearchInput(State, sieToggle, 0);
  Check((Transition.Action = siaOpen) and Transition.State.Active and
    (Transition.State.Text = ''), 'F3 reopen clears stale query');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieToggle, 0);
  Check((Transition.Action = siaClose) and not Transition.State.Active and
    (Transition.State.Text = ''), 'F3 closes and clears search');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieCharacter, Ord('x'), false);
  Check((Transition.Action = siaIgnored) and not Transition.State.Active,
    'zero-song library does not open search');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieToggle, 0, false);
  Check((Transition.Action = siaIgnored) and not Transition.State.Active and
    (Transition.State.Text = ''), 'F3 stays closed when there are no visible songs');

  State.Active := true;
  State.Text := 'éa';
  Transition := UpdateSearchInput(State, sieBackspace, 0);
  Check((Transition.Action = siaJumpArtist) and (Transition.State.Text = 'é') and
    (LengthUTF8(Transition.State.Text) = 1), 'backspace removes one Unicode character');
  State.Active := true;
  State.Text := StringOfChar('x', 24);
  Transition := UpdateSearchInput(State, sieCharacter, UCS4Char($00E9));
  Check((Transition.Action = siaFilter) and (LengthUTF8(Transition.State.Text) = 25),
    'Unicode character limit counts codepoints');
  Check(Length(Transition.State.Text) = 26, 'Unicode text retains UTF-8 bytes');
  State := Transition.State;
  Transition := UpdateSearchInput(State, sieCharacter, Ord('z'));
  Check((Transition.Action = siaIgnored) and
    (Transition.State.Text = State.Text), 'search character limit is enforced');
  WriteLn('PASS: ', Assertions, ' artist navigation and type-to-search assertions');
end.
