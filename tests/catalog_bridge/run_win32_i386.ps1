[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$FpcPath,
  [Parameter(Mandatory = $true)][string]$UnitRoot,
  [Parameter(Mandatory = $true)][string]$PythonPath,
  [Parameter(Mandatory = $true)][string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Fpc = (Resolve-Path -LiteralPath $FpcPath).Path
$UnitRoot = (Resolve-Path -LiteralPath $UnitRoot).Path
$PythonPath = (Resolve-Path -LiteralPath $PythonPath).Path
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)

$GameRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'game'))
$GamePrefix = $GameRoot.TrimEnd('\') + '\'
if ($BuildDirectory.Equals($GameRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $BuildDirectory.StartsWith($GamePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'BuildDirectory must not be inside the game data directory.'
}

$TargetCpu = (& $Fpc -iTP).Trim()
$TargetOs = (& $Fpc -iTO).Trim()
if ($TargetCpu -ne 'i386' -or $TargetOs -ne 'win32') {
  throw "Expected FPC target i386-win32, got $TargetCpu-$TargetOs."
}

$UnitsOut = Join-Path $BuildDirectory 'units'
$BinOut = Join-Path $BuildDirectory 'bin'
New-Item -ItemType Directory -Force -Path $UnitsOut, $BinOut | Out-Null
$UnitFlags = @('-Fu' + $UnitRoot)
$UnitFlags += Get-ChildItem -LiteralPath $UnitRoot -Directory -Recurse |
  ForEach-Object { '-Fu' + $_.FullName }

$Bridge = Join-Path $RepoRoot 'src\base\USongCatalogBridge.pas'
$BridgeTest = Join-Path $RepoRoot 'tests\catalog_bridge\catalog_bridge_test.pas'
$BridgeExe = Join-Path $BinOut 'catalog_bridge_test.exe'

# Compile the actual bridge and its fixture test with the 32-bit Windows compiler.
$CompileBridge = @('-B', '-Cn') + $UnitFlags
$CompileBridge += ('-Fu' + (Join-Path $RepoRoot 'src\base'))
$CompileBridge += ('-FU' + $UnitsOut)
$CompileBridge += $Bridge
& $Fpc @CompileBridge
if ($LASTEXITCODE -ne 0) { throw 'Win32 bridge unit compile failed.' }

$CompileTest = @('-B') + $UnitFlags
$CompileTest += ('-Fu' + $UnitsOut)
$CompileTest += ('-Fu' + (Join-Path $RepoRoot 'src\base'))
$CompileTest += ('-FU' + $UnitsOut)
$CompileTest += ('-FE' + $BinOut)
$CompileTest += ('-o' + $BridgeExe)
$CompileTest += $BridgeTest
& $Fpc @CompileTest
if ($LASTEXITCODE -ne 0) { throw 'Win32 bridge fixture compile failed.' }

$FixtureArgs = @(
  $PythonPath,
  (Join-Path $RepoRoot 'tests\catalog_bridge\inert_child.py'),
  '--ordinal-regression'
)
& $BridgeExe @FixtureArgs
if ($LASTEXITCODE -ne 0) { throw 'Win32 bridge fixture regression failed.' }

Write-Output 'PASS: i386-win32 bridge compile and fixture regression.'
