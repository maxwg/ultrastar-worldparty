program CatalogAutoSignInTest;
{$mode objfpc}{$H+}
uses UCatalogAutoSignIn;
var Attempted: boolean; Checks: integer;
procedure Check(OK: boolean);
begin Inc(Checks); if not OK then Halt(1); end;
begin
  Attempted := false;
  Check(not ClaimCatalogAutoSignIn(Attempted, true, false, true, false, false));
  Check(not Attempted);
  Check(not ClaimCatalogAutoSignIn(Attempted, false, true, true, false, false));
  Check(not ClaimCatalogAutoSignIn(Attempted, false, false, false, false, false));
  Check(not ClaimCatalogAutoSignIn(Attempted, false, false, true, true, false));
  Check(not ClaimCatalogAutoSignIn(Attempted, false, false, true, false, true));
  Check(ClaimCatalogAutoSignIn(Attempted, false, false, true, false, false));
  Check(Attempted);
  Check(not ClaimCatalogAutoSignIn(Attempted, false, false, true, false, false));
  WriteLn('PASS: ', Checks, ' auto sign-in state assertions');
end.
