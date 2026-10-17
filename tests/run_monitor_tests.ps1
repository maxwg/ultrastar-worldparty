[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CompilerRoot)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo 'build\monitor-tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& (Join-Path $repo 'tools\build_windows.ps1') -CompilerRoot $CompilerRoot
Copy-Item (Join-Path $repo 'game\*.dll') -Destination $out -Force
$compiler = Join-Path $CompilerRoot 'installed\bin\i386-win32\fpc.exe'
$flags = @('-n','-Si','-Sg','-Sc','-O2',
  ('-Fu'+(Join-Path $repo 'build\ui-clean')),
  ('-Fu'+(Join-Path $CompilerRoot 'installed\units\i386-win32\*')),
  ('-Fu'+(Join-Path $repo 'src\base')),('-Fi'+(Join-Path $repo 'src')),
  ('-FD'+(Join-Path $CompilerRoot 'b\install\binw32')),
  ('-FE'+$out),('-FU'+$out))
foreach($test in @('voice_monitor_test','voice_monitor_stream_test')) {
  & $compiler @flags (Join-Path $PSScriptRoot ($test+'.pas')) *> (Join-Path $out ($test+'-compile.log'))
  if($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $out ($test+'-compile.log'))
    throw ($test+' compilation failed')
  }
  Push-Location $out
  try {
    & (Join-Path $out ($test+'.exe')) | Tee-Object -FilePath (Join-Path $out ($test+'-result.txt'))
    if($LASTEXITCODE -ne 0){throw ($test+' failed')}
  } finally { Pop-Location }
}
