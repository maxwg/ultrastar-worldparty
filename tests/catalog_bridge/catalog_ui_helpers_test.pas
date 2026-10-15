program CatalogUIHelpersTest;
{$mode delphi}{$H+}
uses SysUtils, USongCatalogLayout, USongCatalogInput, UUnicodeUtils;

procedure Check(Value: boolean; const MessageText: string);
begin
  if not Value then
  begin WriteLn('FAIL: ', MessageText); Halt(1); end;
end;

procedure CheckLayout(W, H: integer);
var L: TSongCatalogLayout; Ys: array[0..14] of integer; I: integer;
begin
  L := MakeSongCatalogLayout(W, H);
  if W < 320 then W := 800;
  if H < 240 then H := 600;
  Check((L.X >= 0) and (L.X < W), 'x inside render bounds');
  Ys[0] := L.TitleY;
  Ys[1] := L.InstructionsY;
  Ys[2] := L.ArtistY;
  Ys[3] := L.SongTitleY;
  Ys[4] := L.UsernameY;
  Ys[5] := L.PasswordY;
  Ys[6] := L.ActionsY;
  Ys[7] := L.StatusY;
  Ys[8] := L.ResultsLabelY;
  for I := 0 to 5 do Ys[9 + I] := L.ResultsFirstY + I * L.ResultsStep;
  for I := 0 to High(Ys) do
  begin
    Check((Ys[I] >= 0) and (Ys[I] + L.FontSize <= H - 4),
          'every label/action/status/result rectangle is vertically bounded');
    if I > 0 then
      Check(Ys[I] >= Ys[I - 1] + L.FontSize + 2,
            'every adjacent text rectangle has a non-overlap gap');
  end;
  Check((L.TextWidth > 0) and (L.FontSize > 0), 'text geometry positive');
  Check(L.X + L.TextWidth <= W - 4, 'text rectangles stay within right edge');
  Check(L.ResultsStep >= L.FontSize + 2, 'result rows have a non-overlap gap');
end;

var S: UTF8String;
begin
  CheckLayout(640, 480);
  CheckLayout(800, 600);
  CheckLayout(1280, 720);
  CheckLayout(1920, 1080);
  CheckLayout(320, 240);
  CheckLayout(160, 100); // invalid renderer dimensions use safe default
  Check(IsPrintableCatalogCharacter(Ord(':')), 'colon accepted');
  Check(IsPrintableCatalogCharacter(Ord('+')), 'plus accepted');
  Check(IsPrintableCatalogCharacter(Ord('/')), 'slash accepted');
  Check(IsPrintableCatalogCharacter(Ord('=')), 'equals accepted');
  Check(IsPrintableCatalogCharacter(Ord('(')), 'left paren accepted');
  Check(IsPrintableCatalogCharacter(Ord(')')), 'right paren accepted');
  Check(IsPrintableCatalogCharacter($FF0C), 'Unicode punctuation accepted');
  Check(not IsPrintableCatalogCharacter(0), 'NUL rejected');
  Check(not IsPrintableCatalogCharacter($7F), 'DEL rejected');
  Check(not IsPrintableCatalogCharacter($D800), 'surrogate rejected');
  Check(not IsPrintableCatalogCharacter($110000), 'out-of-range scalar rejected');
  S := 'A' + UCS4ToUTF8String($00E9) + UCS4ToUTF8String($FF0C);
  Check(LengthUTF8(S) = 3, 'test input has three Unicode characters');
  Check(LengthUTF8(TruncateCatalogLine(S, 2)) = 2,
        'single-line display truncation counts Unicode characters, not bytes');
  Check(TruncateCatalogLine(S, 0) = '', 'zero-width display truncates safely');
  Check(LengthUTF8(S) = 3, 'display truncation leaves underlying metadata unchanged');
  DeleteLastCatalogCharacter(S);
  Check((LengthUTF8(S) = 2) and (Pos('A', S) = 1), 'backspace removes one multibyte character');
  DeleteLastCatalogCharacter(S);
  Check(S = 'A', 'backspace preserves preceding UTF-8 bytes');
  DeleteLastCatalogCharacter(S);
  Check(S = '', 'backspace safely handles empty input');
  WriteLn('PASS: catalog UI geometry and UTF-8 input helpers');
end.
