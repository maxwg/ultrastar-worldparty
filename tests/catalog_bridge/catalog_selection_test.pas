program CatalogSelectionTest;
{$mode delphi}{$H+}
uses SysUtils, USongCatalogSelection;

var Assertions: integer = 0;

procedure Check(Value: boolean; const MessageText: string);
begin
  Inc(Assertions);
  if not Value then
  begin WriteLn('FAIL: ', MessageText); Halt(1); end;
end;

procedure CheckVisible(const S: TCatalogSelection);
begin
  Check((S.Selected >= 0) and (S.Selected < S.ResultCount), 'selected result is bounded');
  Check((S.Top >= 0) and (S.Top <= S.Selected) and
    (S.Selected < S.Top + CatalogVisibleRows), 'selected result stays in the six visible rows');
end;

var S: TCatalogSelection; I, OldTop: integer; Action: TCatalogSelectionAction;
begin
  ResetCatalogSelection(S);
  Check((S.Focus = 0) and (S.ResultCount = 0) and (S.Selected = -1) and
    (S.Top = 0) and not S.InDetails, 'reset starts empty with the artist field focused');
  Check(not BeginCatalogSourceDetails(S, 6), 'empty selection cannot enter details');
  SetCatalogResultCount(S, -1);
  Check(S.ResultCount = 0, 'negative result count is treated as empty');
  for I := 1 to 7 do
    Check(HandleCatalogNavigation(S, cnTab) = caNone, 'Tab alone never requests catalog work');
  Check(S.Focus = 0, 'empty-result focus cycle skips the unavailable result list');
  HandleCatalogNavigation(S, cnUp);
  Check(S.Focus = CatalogBackFocus, 'Up wraps across the seven ordinary focus targets');
  Check(HandleCatalogNavigation(S, cnEnter) = caClose, 'Back closes while no details view is open');
  Check(HandleCatalogNavigation(S, cnEscape) = caClose, 'Escape closes the catalog outside details');
  ResetCatalogSelection(S);
  for I := 1 to 4 do
  begin
    Check(HandleCatalogNavigation(S, cnEnter) = caNone, 'Enter in text inputs only advances focus');
    Check(S.Focus = I, 'input focus advances in the existing order');
  end;
  Check(HandleCatalogNavigation(S, cnEnter) = caSearch, 'only explicit Enter on Search requests search');
  HandleCatalogNavigation(S, cnTab);
  Check(HandleCatalogNavigation(S, cnEnter) = caSignIn, 'explicit Enter on Sign in requests sign-in');

  SetCatalogResultCount(S, 1);
  S.Focus := CatalogResultsFocus;
  CheckVisible(S);
  for I := 1 to 3 do
  begin
    Check(HandleCatalogNavigation(S, cnDown) = caNone, 'result arrows never fetch details');
    HandleCatalogNavigation(S, cnUp);
    Check(S.Selected = 0, 'one-result selection stays bounded on both arrows');
  end;
  Check(HandleCatalogNavigation(S, cnEnter) = caDetails, 'Enter on a selected result is the details activation boundary');
  Check(not S.InDetails, 'navigation action does not claim a request was accepted');
  HandleCatalogNavigation(S, cnTab);
  Check(S.Focus = 0, 'Tab leaves the result list and returns to input fields');

  SetCatalogResultCount(S, 30); S.Focus := CatalogResultsFocus;
  for I := 1 to 29 do
  begin
    Action := HandleCatalogNavigation(S, cnDown);
    Check(Action = caNone, 'scrolling results never emits a network action');
    Check(S.Selected = I, 'Down advances by one result');
    CheckVisible(S);
  end;
  Check((S.Selected = 29) and (S.Top = 24), 'last result is reachable with a bounded six-row viewport');
  HandleCatalogNavigation(S, cnDown);
  Check((S.Selected = 29) and (S.Top = 24), 'Down at the end does not wrap or overflow');
  OldTop := S.Top;
  Check(BeginCatalogSourceDetails(S, 35), 'accepted source request enters the details view');
  Check(S.InDetails and (S.DetailTop = 0) and (S.Focus = CatalogResultsFocus), 'source view begins at the first detail line');
  Check(not BeginCatalogSourceDetails(S, 35), 'details view cannot begin twice');
  Check(HandleCatalogNavigation(S, cnEnter) = caNone, 'Enter on a displayed source cannot open a link or refetch');
  for I := 1 to 40 do
    Check(HandleCatalogNavigation(S, cnDown) = caNone, 'detail scrolling never emits a network action');
  Check((S.DetailTop = 29) and (S.Selected = 29) and (S.Top = OldTop),
    'all 35 detail lines are reachable without moving the selected song');
  HandleCatalogNavigation(S, cnUp);
  Check(S.DetailTop = 28, 'Up scrolls source details by one line');
  SetCatalogDetailLineCount(S, 6);
  Check(S.DetailTop = 0, 'shortened detail content clamps the viewport');
  Check(HandleCatalogNavigation(S, cnEscape) = caNone, 'first Escape returns to results without closing the session');
  Check(not S.InDetails and (S.Selected = 29) and (S.Top = OldTop) and
    (S.Focus = CatalogResultsFocus), 'details back preserves selected result and viewport');
  Check(HandleCatalogNavigation(S, cnEscape) = caClose, 'second Escape closes the catalog');

  Check(BeginCatalogSourceDetails(S, 7), 'source details can be explicitly entered again');
  for I := 1 to 7 do HandleCatalogNavigation(S, cnTab);
  Check(S.Focus = CatalogBackFocus, 'Tab can reach Back from the details result area');
  Check(HandleCatalogNavigation(S, cnEnter) = caNone, 'Back in details returns to results rather than closing');
  Check(not S.InDetails and (S.Focus = CatalogResultsFocus), 'Back restores result-list focus');
  for I := 1 to 29 do
  begin HandleCatalogNavigation(S, cnUp); CheckVisible(S); end;
  Check((S.Selected = 0) and (S.Top = 0), 'all results can be scrolled back to the start');
  SetCatalogResultCount(S, 2); HandleCatalogNavigation(S, cnDown);
  Check((S.Selected = 1) and (S.Top = 0), 'smaller result set keeps selection and viewport bounded');
  Check(BeginCatalogSourceDetails(S, 8), 'replacement fixture enters source view');
  SetCatalogResultCount(S, 0);
  Check((S.Selected = -1) and (S.Top = 0) and not S.InDetails and (S.DetailTop = 0),
    'cleared results reset selected song, details mode and both viewports');
  Check((S.Focus = 0) and (HandleCatalogNavigation(S, cnEnter) = caNone),
    'asynchronously emptied list cannot turn Enter into another catalog request');
  ResetCatalogSelection(S, CatalogSearchFocus);
  SetCatalogResultCount(S, 30); S.Focus := CatalogResultsFocus;
  for I := 1 to 10 do HandleCatalogNavigation(S, cnDown);
  ResetCatalogSelection(S, CatalogSearchFocus);
  SetCatalogResultCount(S, 30);
  Check((S.Selected = 0) and (S.Top = 0) and not S.InDetails and
    (S.Focus = CatalogSearchFocus), 'new search resets even when the next result count is unchanged');
  ResetCatalogSelection(S);
  Check((S.Selected = -1) and (S.Focus = 0), 'reopened screen starts with no stale selection');
  // Shift+Tab reverses focus without navigating the selected song or issuing work.
  Check(HandleCatalogNavigation(S, cnBackTab) = caNone, 'reverse Tab emits no catalog request');
  Check(S.Focus = CatalogBackFocus, 'reverse Tab skips absent results');
  HandleCatalogNavigation(S, cnTab);
  Check(S.Focus = 0, 'forward Tab reverses empty-list back Tab');
  SetCatalogResultCount(S, 30);
  HandleCatalogNavigation(S, cnBackTab);
  Check(S.Focus = CatalogResultsFocus, 'reverse Tab from artist reaches available results');
  for I := 1 to 9 do HandleCatalogNavigation(S, cnDown);
  OldTop := S.Top;
  Check(HandleCatalogNavigation(S, cnBackTab) = caNone, 'reverse Tab leaves results without fetching');
  Check((S.Focus = CatalogBackFocus) and (S.Selected = 9) and (S.Top = OldTop),
    'reverse Tab preserves selected result and scroll');
  HandleCatalogNavigation(S, cnTab);
  Check(BeginCatalogSourceDetails(S, 35), 'reverse Tab details fixture enters');
  HandleCatalogNavigation(S, cnDown);
  HandleCatalogNavigation(S, cnBackTab);
  Check((S.Focus = CatalogBackFocus) and S.InDetails and (S.DetailTop = 1),
    'reverse Tab exits detail focus without scrolling or leaving detail view');
  Check(HandleCatalogNavigation(S, cnEnter) = caNone, 'reverse Tab makes detail Back directly reachable');
  Check(not S.InDetails and (S.Selected = 9), 'detail Back retains selection');
  WriteLn('PASS: ', Assertions, ' catalog selection/focus/source-view assertions');
end.
