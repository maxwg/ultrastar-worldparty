{*
    UltraStar WorldParty - Karaoke Game

	UltraStar WorldParty is the legal property of its developers,
	whose names	are too numerous to list here. Please refer to the
	COPYRIGHT file distributed with this source distribution.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program. Check "LICENSE" file. If not, see
	<http://www.gnu.org/licenses/>.
 *}

unit UNote;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  SysUtils,
  Classes,
  sdl2,
  dglOpenGL,
  UDisplay,
  UIni,
  ULog,
  ULyrics,
  UMusic,
  URecord,
  UScreenSingController,
  UScreenJukebox,
  USong,
  UTime;

type
  PPLayerNote = ^TPlayerNote;
  TPlayerNote = record
    Start:    integer;
    Length:   integer;
    Detect:   real;    // accurate place, detected in the note
    Tone:     real;
    Perfect:  boolean; // true if the note matches the original one, light the star
    Hit:      boolean; // true if the note hits the line
    NoteType: TNoteType;
  end;

  PPLayer = ^TPlayer;
  TPlayer = record
    Name:           UTF8String;

    // Index in Teaminfo record
    TeamID:         byte;
    PlayerID:       byte;

    // Scores
    Score:          real;
    ScoreLine:      real;
    ScoreGolden:    real;

    ScoreInt:       integer;
    ScoreLineInt:   integer;
    ScoreGoldenInt: integer;
    ScoreTotalInt:  integer;

    // LineBonus
    ScoreLast:      real;    // Last Line Score

    // PerfectLineTwinkle (effect)
    LastSentencePerfect: boolean;

    HighNote:       integer; // index of last note (= High(Note)?)
    LengthNote:     integer; // number of notes (= Length(Note)?).
    Note:           array of TPlayerNote;
  end;

  TStats = record
    Player: array of TPlayer;
    SongArtist:   String;
    SongTitle:    String;
  end;

  TMedleyPlaylist = record
    Song:               array of integer;
    NumMedleySongs:     integer;
    CurrentMedleySong:  integer;
    ApplausePlayed:     boolean;
    Stats:              array of TStats;
    NumPlayer:          integer;
  end;

{* Player and music info *}
var
  {**
   * Player info and state for each player.
   * The amount of players is given by PlayersPlay.
   *}
  Player: array of TPlayer;

  {**
   * Number of players or teams playing.
   * Possible values: 1 - 6
   *}
  PlayersPlay: integer;

  {**
   * Selected song for singing.
   *}
  CurrentSong: TSong;

  PlaylistMedley: TMedleyPlaylist;  // playlist medley

const
  MAX_SONG_SCORE = 10000;     // max. achievable points per song
  MAX_SONG_LINE_BONUS = 1000; // max. achievable line bonus per song

procedure Sing(Screen: TScreenSingController);
procedure NewSentence(CP: integer; Screen: TScreenSingController);
procedure NewBeatClick(Screen: TScreenSingController);  // executed when on then new beat for click
procedure NewBeatDetect(Screen: TScreenSingController); // executed when on then new beat for detection
procedure NewNote(CP: integer; Screen: TScreenSingController);       // detect note
function  GetMidBeat(Time: real): real;
function  GetTimeFromBeat(Beat: integer; SelfSong: TSong = nil): real;

procedure SingJukebox(Screen: TScreenJukebox);

implementation

uses
  Math,
  StrUtils,
  UCatCovers,
  UCommandLine,
  UCommon,
  UConfig,
  UDataBase,
  UGraphic,
  UGraphicClasses,
  UJoystick,
  ULanguage,
  UParty,
  UPathUtils,
  UPlatform,
  UPlaylist,
  USkins,
  USongs,
  UThemes,
  UPitchDisplay;

function GetTimeForBeats(BPM, Beats: real): real;
begin
  Result := 60 / BPM * Beats;
end;

function GetBeats(BPM, msTime: real): real;
begin
  Result := BPM * msTime / 60;
end;

function GetMidBeat(Time: real): real;
begin
  Result := Time * CurrentSong.BPM / 60;
end;

function GetTimeFromBeat(Beat: integer; SelfSong: TSong = nil): real;
var
  Song: TSong;
begin

  if (SelfSong <> nil) then
    Song := SelfSong
  else
    Song := CurrentSong;

  Result := Song.GAP / 1000 + Beat * 60 / Song.BPM;
end;

procedure Sing(Screen: TScreenSingController);
var
  Count:   integer;
  CountGr: integer;
  CP:      integer;
  PetGr:   integer;
begin
  { Update the shared detector at most every 20ms, not only at score beats. }
  for Count := 0 to PlayersPlay-1 do
    AudioInputProcessor.Sound[Count].AnalyzeBuffer;
  LyricsState.UpdateBeats();

  PetGr := 0;
  if (CurrentSong.isDuet) and (PlayersPlay <> 1) then
    PetGr := 1;

  // sentences routines
  for CountGr := 0 to PetGr do //High(CurrentSong.Lines)
  begin;
    CP := CountGr;

    // old parts
    LyricsState.OldLine := CurrentSong.Lines[CP].Current;

    // choose current parts
    for Count := 0 to CurrentSong.Lines[CP].High do
    begin
      if LyricsState.CurrentBeat >= CurrentSong.Lines[CP].Line[Count].Start then
        CurrentSong.Lines[CP].Current := Count;
    end;

    // clean player note if there is a new line
    // (optimization on halfbeat time)
    if CurrentSong.Lines[CP].Current <> LyricsState.OldLine then
      NewSentence(CP, Screen);

  end; // for CountGr

  // make some operations on clicks
  if {(LyricsState.CurrentBeatC >= 0) and }(LyricsState.OldBeatC <> LyricsState.CurrentBeatC) then
    NewBeatClick(Screen);

  // make some operations when detecting new voice pitch
  if (LyricsState.CurrentBeatD >= 0) and (LyricsState.OldBeatD <> LyricsState.CurrentBeatD) then
    NewBeatDetect(Screen);
end;

procedure SingJukebox(Screen: TScreenJukebox);
var
  Count:   integer;
  CountGr: integer;
  CP:      integer;
begin
  LyricsState.UpdateBeats();

  // sentences routines
  for CountGr := 0 to 0 do //High(CurrentSong.Lines)
  begin;
    CP := CountGr;
    // old parts
    LyricsState.OldLine := CurrentSong.Lines[CP].Current;

    // choose current parts
    for Count := 0 to CurrentSong.Lines[CP].High do
    begin
      if LyricsState.CurrentBeat >= CurrentSong.Lines[CP].Line[Count].Start then
        CurrentSong.Lines[CP].Current := Count;
    end;
  end; // for CountGr

  // on sentence change...
  Screen.onSentenceChange(CurrentSong.Lines[0].Current);
end;

procedure NewSentence(CP: integer; Screen: TScreenSingController);
var
  I: integer;
begin
  // clean note of player
  for I := 0 to High(Player) do
  begin
    if (not CurrentSong.isDuet) or (I mod 2 = CP) then
    begin
      Player[I].LengthNote := 0;
      Player[I].HighNote := -1;
      SetLength(Player[I].Note, 0);
    end;
  end;

  Screen.onSentenceChange(CP, CurrentSong.Lines[CP].Current)
end;

procedure NewBeatClick;
var
  Count: integer;
begin
  // beat click
  if not (CurrentSong.isDuet) or (PlayersPlay = 1) then
  begin
    if (Ini.BeatClick = 1) and ((LyricsState.CurrentBeatC + 4) mod 4 = 0) then //FIXME after remove resolution and notesgap use 4 as default...
      UMusic.AudioPlayback.PlaySound(UMusic.SoundLib.BeatClick);

    for Count := 0 to CurrentSong.Lines[0].Line[CurrentSong.Lines[0].Current].HighNote do
    begin
      //basisbit todo
      if (CurrentSong.Lines[0].Line[CurrentSong.Lines[0].Current].Note[Count].Start = LyricsState.CurrentBeatC) then
      begin
        // click assist
        if Ini.ClickAssist = 1 then
          UMusic.AudioPlayback.PlaySound(UMusic.SoundLib.BeatClick);

        // drum machine
        (*
        TempBeat := LyricsState.CurrentBeat; // + 2;
        if (TempBeat mod 8 = 0) then Music.PlayDrum;
        if (TempBeat mod 8 = 4) then Music.PlayClap;
        //if (TempBeat mod 4 = 2) then Music.PlayHihat;
        if (TempBeat mod 4 <> 0) then Music.PlayHihat;
        *)
      end;
    end;
  end;
end;

procedure NewBeatDetect(Screen: TScreenSingController);
  var
    MaxCP, CP, SentenceEnd: integer;
    I, J: cardinal;
begin
  // check for sentence end
  // we check all lines here because a new sentence may
  // have been started even before the old one finishes
  // due to corrupt lien breaks
  // checking only current line works to, but may lead to
  // weird ratings for the song files w/ the mentioned
  // errors
  // To-Do Philipp : check current and last line should
  // do it for most corrupt txt and for lines in
  // non-corrupt txts that start immediatly after the prev.
  // line ends
  MaxCP := 0;
  if (CurrentSong.isDuet) and (PlayersPlay <> 1) then
    MaxCP := 1;

  if (assigned(Screen)) then
  begin
    for J := 0 to MaxCP do
    begin
      CP := J;

      NewNote(CP, Screen);

      for I := 0 to CurrentSong.Lines[CP].High do
      begin
        with CurrentSong.Lines[CP].Line[I] do
        begin
          if (HighNote >= 0) then
          begin
            SentenceEnd := Note[HighNote].Start + Note[HighNote].Length;

            if (LyricsState.OldBeatD < SentenceEnd) and (LyricsState.CurrentBeatD >= SentenceEnd) then
              Screen.OnSentenceEnd(CP, I);
          end;
        end;
      end;
    end;
  end;
end;

procedure NewNote(CP: integer; Screen: TScreenSingController);
var
  LineFragmentIndex:   integer;
  CurrentLineFragment: PLineFragment;
  PlayerIndex:         integer;
  CurrentSound:        TCaptureBuffer;
  CurrentPlayer:       PPlayer;
  LastPlayerNote:      PPlayerNote;
  Line: 	       PLine;
  SentenceIndex:       integer;
  SentenceMin:         integer;
  SentenceMax:         integer;
  SentenceDetected:    integer; // sentence of detected note
  ActualBeat:          integer;
  ActualTone:          integer;
  NoteAvailable:       boolean;
  RapAvailable:        boolean;
  NewNote:             boolean;
  Range:               integer;
  NoteHit:             boolean;
  MaxSongPoints:       integer; // max. points for the song (without line bonus)
  CurNotePoints:       real;    // Points for the cur. Note (PointsperNote * ScoreFactor[CurNote])
  CurrentNoteType:     TNoteType;
  BackfillCount:       integer;
  MatchedLineFragment: PLineFragment;
begin
  ActualTone := 0;
  NoteHit := false;

  // TODO: add duet mode support
  // use CurrentSong.Lines[LineSetIndex] with LineSetIndex depending on the current player

  // count min and max sentence range for checking
  // (detection is delayed to the notes we see on the screen)
  SentenceMin := CurrentSong.Lines[CP].Current-1;
  if (SentenceMin < 0) then
    SentenceMin := 0;
  SentenceMax := CurrentSong.Lines[CP].Current;

  for ActualBeat := LyricsState.OldBeatD+1 to LyricsState.CurrentBeatD do
  begin
    // analyze player signals
    for PlayerIndex := 0 to PlayersPlay-1 do
    begin
      if (not CurrentSong.isDuet) or (PlayerIndex mod 2 = CP) then
      begin
        // check for an active note at the current time defined in the lyrics
        NoteAvailable := false;
        RapAvailable := false;
        SentenceDetected := SentenceMin;
        MatchedLineFragment := nil;
        for SentenceIndex := SentenceMin to SentenceMax do
        begin
          Line := @CurrentSong.Lines[CP].Line[SentenceIndex];
          for LineFragmentIndex := 0 to Line.HighNote do
          begin
            CurrentLineFragment := @Line.Note[LineFragmentIndex];
            // check if line is active
            if ((CurrentLineFragment.Start <= ActualBeat) and
              (CurrentLineFragment.Start + CurrentLineFragment.Length-1 >= ActualBeat)) and
              (CurrentLineFragment.NoteType <> ntFreestyle) and       // but ignore FreeStyle notes
              (CurrentLineFragment.Length > 0) then                   // and make sure the note length is at least 1
            begin
              SentenceDetected := SentenceIndex;
              MatchedLineFragment := CurrentLineFragment;
              NoteAvailable := true;
              RapAvailable := CurrentLineFragment.NoteType in [ntRap, ntRapGolden];
              Break;
            end;
          end;
          if NoteAvailable then Break;
        end;

        CurrentPlayer := @Player[PlayerIndex];
        CurrentSound := AudioInputProcessor.Sound[PlayerIndex];

        // at the beginning of the song there is no previous note
        if (Length(CurrentPlayer.Note) > 0) and (CurrentPlayer.HighNote > -1) then
          LastPlayerNote := @CurrentPlayer.Note[CurrentPlayer.HighNote]
        else
          LastPlayerNote := nil;

        // analyze buffer
        CurrentSound.AnalyzeBuffer;
        { Never carry a backfill count from another beat or player. }
        BackfillCount := 0;

        // add note if possible
        if (NoteAvailable and (MatchedLineFragment <> nil) and
            (CurrentSound.ToneValid or CurrentSound.ScorePitch.Valid or
             (CurrentSound.VoiceActive and RapAvailable))) then
        begin
          CurrentLineFragment := MatchedLineFragment;
          CurrentNoteType := CurrentLineFragment.NoteType;
          Line := @CurrentSong.Lines[CP].Line[SentenceDetected];

          ActualTone := Round(FoldPitchToTarget(CurrentSound.ScorePitch.Midi,
            CurrentLineFragment.Tone+60))-60;
          if (ScreenSong.Mode = smNormal) then
            Range := Ini.PlayerLevel[PlayerIndex]
          else
            Range := Ini.Difficulty;
          NoteHit := False;
          { Pitch policy is shared with the real-vocal benchmark. A brief
            unvoiced dropout only counts inside the same already-hit note. }
          if ((CurrentLineFragment.NoteType in [ntRap, ntRapGolden]) and
              CurrentSound.VoiceActive) or
             (CurrentSound.ScorePitch.Valid and
              PitchMatchesNote(CurrentSound.ScorePitch.Midi,
               CurrentLineFragment.Tone+60, Range) and
              (CurrentSound.ToneValid or
               ((LastPlayerNote <> nil) and LastPlayerNote.Hit and
                (LastPlayerNote.Start >= CurrentLineFragment.Start) and
                (LastPlayerNote.Start+LastPlayerNote.Length = ActualBeat)))) then
          begin
            ActualTone := CurrentLineFragment.Tone;
            NoteHit := true;

            { Credit no more than 180ms after a newly detected onset. If an
              earlier unhit pitch exists *inside this note*, that is evidence
              against backfilling it; we must not rewrite wrong singing. }
            if (LastPlayerNote = nil) or
               (LastPlayerNote.Start + LastPlayerNote.Length <= CurrentLineFragment.Start) then
              BackfillCount := OnsetBackfillBeats(CurrentSong.BPM,
                CurrentLineFragment.Length, ActualBeat-CurrentLineFragment.Start,
                False);
            if (BackfillCount > 0) and (Ini.Debug = 1) then
              Log.LogInfo(Format('player=%d beat=%d onset_beats=%d bpm=%.1f',
                [PlayerIndex+1, ActualBeat, BackfillCount, CurrentSong.BPM]),
                'PitchOnsetGrace');

            if (Ini.LineBonus > 0) then
              MaxSongPoints := MAX_SONG_SCORE - MAX_SONG_LINE_BONUS
            else
              MaxSongPoints := MAX_SONG_SCORE;

            CurNotePoints := (MaxSongPoints / CurrentSong.Lines[CP].ScoreValue) * ScoreFactor[CurrentLineFragment.NoteType];

            case CurrentLineFragment.NoteType of
              ntNormal:    CurrentPlayer.Score       := CurrentPlayer.Score       + CurNotePoints * (1 + BackfillCount);
              ntGolden:    CurrentPlayer.ScoreGolden := CurrentPlayer.ScoreGolden + CurNotePoints * (1 + BackfillCount);
              ntRap:       CurrentPlayer.Score       := CurrentPlayer.Score       + CurNotePoints * (1 + BackfillCount);
              ntRapGolden: CurrentPlayer.ScoreGolden := CurrentPlayer.ScoreGolden + CurNotePoints * (1 + BackfillCount);
            end;

            CurrentPlayer.ScoreInt := round(CurrentPlayer.Score / 10) * 10;

            if (CurrentPlayer.ScoreInt < CurrentPlayer.Score) then
              CurrentPlayer.ScoreGoldenInt := ceil(CurrentPlayer.ScoreGolden / 10) * 10
            else
              CurrentPlayer.ScoreGoldenInt := floor(CurrentPlayer.ScoreGolden / 10) * 10;

            CurrentPlayer.ScoreTotalInt := CurrentPlayer.ScoreInt +
                                           CurrentPlayer.ScoreGoldenInt +
                                           CurrentPlayer.ScoreLineInt;
          end;

          // check if we have to add a new note or extend the note's length
          if (SentenceDetected = SentenceMax) and
             (CurrentSound.ToneValid or CurrentSound.ScorePitch.Valid or
              (CurrentSound.VoiceActive and (CurrentNoteType in [ntRap, ntRapGolden]))) then
          begin
            if BackfillCount > 0 then
            begin
              { Prune any unhit onset fragments that were recorded during backfilled beats }
              while (CurrentPlayer.HighNote >= 0) and
                    (CurrentPlayer.Note[CurrentPlayer.HighNote].Start >= CurrentLineFragment.Start) and
                    (not CurrentPlayer.Note[CurrentPlayer.HighNote].Hit) do
              begin
                Dec(CurrentPlayer.HighNote);
                Dec(CurrentPlayer.LengthNote);
                SetLength(CurrentPlayer.Note, CurrentPlayer.LengthNote);
              end;
              if CurrentPlayer.HighNote >= 0 then
                LastPlayerNote := @CurrentPlayer.Note[CurrentPlayer.HighNote]
              else
                LastPlayerNote := nil;
            end;

            // we will add a new note
            NewNote := true;

            // if previous note (if any) was the same, extend previous note
            if (BackfillCount = 0) and
               ((CurrentPlayer.LengthNote > 0) and
                (LastPlayerNote <> nil) and
                (LastPlayerNote.Tone = ActualTone) and
                ((LastPlayerNote.Start + LastPlayerNote.Length) = ActualBeat)) then
            begin
              NewNote := false;
            end;

            // if note starts on ActualBeat, always start a new player note
            if (BackfillCount = 0) and (CurrentLineFragment.Start = ActualBeat) then
              NewNote := true;

            // add new note
            if NewNote then
            begin
              Inc(CurrentPlayer.LengthNote);
              Inc(CurrentPlayer.HighNote);
              SetLength(CurrentPlayer.Note, CurrentPlayer.LengthNote);

              LastPlayerNote := @CurrentPlayer.Note[CurrentPlayer.HighNote];
              with LastPlayerNote^ do
              begin
                if BackfillCount > 0 then
                begin
                  Start    := CurrentLineFragment.Start;
                  Length   := 1 + BackfillCount;
                end
                else
                begin
                  Start    := ActualBeat;
                  Length   := 1;
                end;
                Tone     := ActualTone;
                Hit      := NoteHit;
                NoteType := CurrentNoteType;
              end;
            end
            else
            begin
              if (LastPlayerNote <> nil) then
                Inc(LastPlayerNote.Length);
            end;

            // check for perfect note
            if (LastPlayerNote <> nil) and LastPlayerNote.Hit and
               (CurrentLineFragment.Start  = LastPlayerNote.Start) and
               (CurrentLineFragment.Length = LastPlayerNote.Length) and
               (CurrentLineFragment.Tone   = LastPlayerNote.Tone) then
            begin
              LastPlayerNote.Perfect := true;
            end;
          end; // if SentenceDetected = SentenceMax

        end; // if Detected

        { Once a note ends, a subsequent matching pitch cannot prove that it
          was sung. Do not award whole short notes after their scoring window. }
      end;
    end; // for PlayerIndex
  end; // for ActualBeat
  //Log.LogStatus('EndBeat', 'NewBeat');
end;

end.
