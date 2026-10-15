{ Artist alphabet navigation. UI-independent so the real navigation rules can
  be tested without SDL, audio devices, or a song library. }
unit UArtistNavigation;
{$mode objfpc}{$H+}
interface
uses UUnicodeUtils;
const
  ArtistAlphabet = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  ArtistBucketCount = 27;
type
  TArtistTargets = array[0..ArtistBucketCount - 1] of Integer;
  TArtistSearchEntry = record
    Artist: UTF8String;
    Visible: Boolean;
    IsCategory: Boolean;
  end;
  TArtistSearchEntries = array of TArtistSearchEntry;
  TSearchInputEvent = (sieCharacter, sieBackspace, sieEscape, sieToggle);
  TSearchInputAction = (siaIgnored, siaOpen, siaJumpArtist, siaFilter, siaClear, siaClose);
  TSearchInputState = record
    Active: Boolean;
    Text: UTF8String;
  end;
  TSearchInputTransition = record
    State: TSearchInputState;
    Action: TSearchInputAction;
  end;
function ArtistBucket(const NormalizedArtist: UTF8String): Integer;
function NextArtistBucket(const Targets: TArtistTargets; Current, Direction: Integer): Integer;
function FindArtistPrefixTarget(const Entries: array of TArtistSearchEntry;
  CurrentIndex: Integer; const Prefix: UTF8String): Integer;
function IsSearchTextCharacter(Character: UCS4Char; HasShortcutModifier,
  IsModeModifier: Boolean): Boolean;
function UpdateSearchInput(const State: TSearchInputState; Event: TSearchInputEvent;
  Character: UCS4Char; CanOpen: Boolean = true): TSearchInputTransition;
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

function FindArtistPrefixTarget(const Entries: array of TArtistSearchEntry;
  CurrentIndex: Integer; const Prefix: UTF8String): Integer;
var Step, Candidate, Count: Integer;
begin
  Result := -1;
  Count := Length(Entries);
  if (Count = 0) or (Prefix = '') then Exit;
  if CurrentIndex < -1 then CurrentIndex := -1;
  if CurrentIndex >= Count then CurrentIndex := Count - 1;
  // Start just after the current global song, wrapping once. Include the
  // current item only on the final step so a one-artist library still works.
  for Step := 1 to Count do
  begin
    Candidate := (CurrentIndex + Step + Count) mod Count;
    if Entries[Candidate].Visible and not Entries[Candidate].IsCategory
      and UTF8StartsText(Prefix, Entries[Candidate].Artist) then
      Exit(Candidate);
  end;
end;

function IsSearchTextCharacter(Character: UCS4Char; HasShortcutModifier,
  IsModeModifier: Boolean): Boolean;
begin
  Result := UUnicodeUtils.IsPrintableChar(Character)
    and (not HasShortcutModifier or IsModeModifier);
end;

function UpdateSearchInput(const State: TSearchInputState; Event: TSearchInputEvent;
  Character: UCS4Char; CanOpen: Boolean): TSearchInputTransition;
const MAX_SEARCH_CHARACTERS = 25;
var CharacterText: UTF8String; CurrentLength: Integer;
begin
  Result.State := State;
  Result.Action := siaIgnored;
  case Event of
    sieCharacter:
      begin
        if not IsSearchTextCharacter(Character, false, false) then Exit;
        if not Result.State.Active then
        begin
          if not CanOpen then Exit;
          // A closed search starts a fresh query, even if stale text was left
          // by an interrupted or older screen transition.
          Result.State.Text := '';
          Result.State.Active := true;
        end;
        CurrentLength := LengthUTF8(Result.State.Text);
        if CurrentLength >= MAX_SEARCH_CHARACTERS then Exit;
        CharacterText := UCS4ToUTF8String(Character);
        if CharacterText = '' then Exit;
        Result.State.Text := Result.State.Text + CharacterText;
        if CurrentLength = 0 then
          Result.Action := siaJumpArtist
        else
          Result.Action := siaFilter;
      end;
    sieBackspace:
      begin
        if not Result.State.Active then Exit;
        CurrentLength := LengthUTF8(Result.State.Text);
        if CurrentLength > 0 then
          UTF8Delete(Result.State.Text, CurrentLength, 1);
        CurrentLength := LengthUTF8(Result.State.Text);
        if CurrentLength = 0 then
          Result.Action := siaClear
        else if CurrentLength = 1 then
          Result.Action := siaJumpArtist
        else
          Result.Action := siaFilter;
      end;
    sieEscape:
      begin
        if not Result.State.Active then Exit;
        Result.State.Active := false;
        Result.State.Text := '';
        Result.Action := siaClose;
      end;
    sieToggle:
      begin
        Result.State.Text := '';
        if Result.State.Active then
        begin
          Result.State.Active := false;
          Result.Action := siaClose;
        end
        else if CanOpen then
        begin
          Result.State.Active := true;
          Result.Action := siaOpen;
        end;
      end;
  end;
end;
end.
