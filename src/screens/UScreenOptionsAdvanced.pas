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


unit UScreenOptionsAdvanced;

interface

{$MODE OBJFPC}

{$I switches.inc}

uses
  UCommon,
  sdl2,
  UMenu,
  UDisplay,
  UMusic,
  UFiles,
  UIni,
  UThemes,
  UAdvancedOptionsLayout;

type

  TScreenOptionsAdvanced = class(TMenu)
   protected
      // interaction IDs
	  ButtonExitIID: integer;

    public
      constructor Create; override;
      function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
      procedure OnShow; override;
  end;

implementation

uses
  UGraphic,
  UUnicodeUtils,
  SysUtils;

function TScreenOptionsAdvanced.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
begin
  Result := true;
  if (PressedDown) then
  begin // Key Down
    // check special keys
    case PressedKey of
      SDLK_ESCAPE,
      SDLK_BACKSPACE :
        begin
          UIni.Ini.Save;
          AudioPlayback.PlaySound(SoundLib.Back);
          FadeTo(@ScreenOptions);
        end;
      SDLK_RETURN:
        begin
          if SelInteraction = ButtonExitIID then
          begin
            UIni.Ini.Save;
            AudioPlayback.PlaySound(SoundLib.Back);
            FadeTo(@ScreenOptions);
          end;
        end;
      SDLK_DOWN:
        InteractNext;
      SDLK_UP :
        InteractPrev;
      SDLK_RIGHT:
        begin
          if (SelInteraction >= 0) and (SelInteraction < ButtonExitIID) then
          begin
            AudioPlayback.PlaySound(SoundLib.Option);
            InteractInc;
          end;
        end;
      SDLK_LEFT:
        begin
          if (SelInteraction >= 0) and (SelInteraction < ButtonExitIID) then
          begin
            AudioPlayback.PlaySound(SoundLib.Option);
            InteractDec;
          end;
        end;
    end;
  end;
end;

constructor TScreenOptionsAdvanced.Create;
var
  Row: Integer;
  Slide: TThemeSelectSlide;
  ExitButton: TThemeButton;
  procedure AddRow(Style: TThemeSelectSlide; var Value: Integer;
    const Values: array of UTF8String);
  begin
    Style.Y := AdvancedOptionsRowTop(Row);
    Style.H := AdvancedOptionsRowHeight;
    AddSelectSlide(Style, Value, Values, 'OPTION_VALUE_');
    Inc(Row);
  end;
begin
  inherited Create;
  LoadFromTheme(Theme.OptionsAdvanced);
  Row := 0;
  AddRow(Theme.OptionsAdvanced.SelectDebug, Ini.Debug, IDebug);
  AddRow(Theme.OptionsAdvanced.SelectOscilloscope, Ini.Oscilloscope, IOscilloscope);
  Slide := Theme.OptionsAdvanced.SelectOscilloscope;
  Slide.Text := 'Target note names (F6)';
  AddRow(Slide, Ini.NoteNames, IOscilloscope);
  Slide.Text := 'Detected pitch (F7)';
  AddRow(Slide, Ini.DetectedPitch, IOscilloscope);
  Slide.Text := 'Current pitch readout (F8)';
  AddRow(Slide, Ini.PitchReadout, IOscilloscope);
  Slide.Text := 'Show virtual audio inputs';
  AddRow(Slide, Ini.ShowVirtualAudioInputs, IOscilloscope);
  AddRow(Theme.OptionsAdvanced.SelectOnSongClick, Ini.OnSongClick, IOnSongClick);
  AddRow(Theme.OptionsAdvanced.SelectAskbeforeDel, Ini.AskBeforeDel, IAskbeforeDel);
  AddRow(Theme.OptionsAdvanced.SelectPartyPopup, Ini.PartyPopup, IPartyPopup);
  AddRow(Theme.OptionsAdvanced.SelectTopScores, Ini.TopScores, ITopScores);
  ExitButton := Theme.OptionsAdvanced.ButtonExit;
  ExitButton.Y := AdvancedOptionsExitTop(Row, ExitButton.H, ExitButton.Y);
  AddButton(ExitButton);
  ButtonExitIID := High(Interactions);
  Interaction := 0;
end;

procedure TScreenOptionsAdvanced.OnShow;
begin
  inherited;

  Interaction := 0;
end;

end.
