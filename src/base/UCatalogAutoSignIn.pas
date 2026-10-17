unit UCatalogAutoSignIn;
{$mode objfpc}{$H+}
interface
function ClaimCatalogAutoSignIn(var Attempted: boolean;
  Busy, Authenticated, HasCredentials, HasError, EditingAccount: boolean): boolean;
implementation
function ClaimCatalogAutoSignIn(var Attempted: boolean;
  Busy, Authenticated, HasCredentials, HasError, EditingAccount: boolean): boolean;
begin
  Result := not Attempted and not Busy and not Authenticated and
    HasCredentials and not HasError and not EditingAccount;
  if Result then Attempted := true;
end;
end.
