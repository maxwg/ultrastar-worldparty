[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$CompilerRoot,
  [switch]$Capture,
  [switch]$Vocals,
  [ValidateSet('development','heldout','all')][string]$Split='development'
)
$ErrorActionPreference='Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo 'build\pitch-tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$compiler = Join-Path $CompilerRoot 'installed\bin\i386-win32\fpc.exe'
$flags = @('-B','-n','-Si','-Sg','-Sc','-O4',
  ('-Fu'+(Join-Path $CompilerRoot 'installed\units\i386-win32\*')),
  ('-Fu'+(Join-Path $repo 'src\base')),
  ('-FD'+(Join-Path $CompilerRoot 'b\install\binw32')),
  ('-FE'+$out),('-FU'+$out))
foreach($test in @('pitch_display_test','pitch_tracker_test','pitch_benchmark')) {
  & $compiler @flags (Join-Path $PSScriptRoot ($test+'.pas')) *> (Join-Path $out ($test+'-compile.log'))
  if($LASTEXITCODE -ne 0){Get-Content (Join-Path $out ($test+'-compile.log'));throw 'Pitch test compilation failed'}
  if($test -eq 'pitch_benchmark') {
    $sources = foreach($name in @('src/base/UPitchDisplay.pas','tests/pitch_benchmark.pas')) {
      [ordered]@{path=$name;sha256=(Get-FileHash (Join-Path $repo $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $receipt = [ordered]@{
      base_revision=(& git -C $repo rev-parse HEAD)
      executable_sha256=(Get-FileHash (Join-Path $out 'pitch_benchmark.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
      files=@($sources)
    }
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $out 'pitch_benchmark.exe.sources.json')
  }
  if($test -ne 'pitch_benchmark') {
    & (Join-Path $out ($test+'.exe'))
    if($LASTEXITCODE -ne 0){throw ($test+' failed')}
  }
}
if($Capture) {
  & (Join-Path $repo 'tools\build_windows.ps1') -CompilerRoot $CompilerRoot
  Copy-Item (Join-Path $repo 'game\*.dll') -Destination $out -Force
  $captureFlags = @('-n','-Si','-Sg','-Sc','-O2',
    ('-Fu'+(Join-Path $repo 'build\ui-clean')),
    ('-Fu'+(Join-Path $CompilerRoot 'installed\units\i386-win32\*')),
    ('-Fu'+(Join-Path $repo 'src\base')),('-Fi'+(Join-Path $repo 'src')),
    ('-FD'+(Join-Path $CompilerRoot 'b\install\binw32')),
    ('-FE'+$out),('-FU'+$out))
  & $compiler @captureFlags (Join-Path $PSScriptRoot 'record_capture_state_test.pas') *> (Join-Path $out 'capture-compile.log')
  if($LASTEXITCODE -ne 0){Get-Content (Join-Path $out 'capture-compile.log');throw 'Capture test compilation failed'}
  Push-Location $out
  try {
    & (Join-Path $out 'record_capture_state_test.exe')
    if($LASTEXITCODE -ne 0){throw 'Capture regression failed'}
  } finally { Pop-Location }
}
if($Vocals) {
  & python (Join-Path $PSScriptRoot 'vocal_benchmark.py') --download --harness (Join-Path $out 'pitch_benchmark.exe') --split $Split
  if($LASTEXITCODE -ne 0){throw 'Solo-vocal benchmark failed'}
}
