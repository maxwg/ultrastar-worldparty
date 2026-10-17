[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CompilerRoot)
$ErrorActionPreference='Stop'
$repo = Split-Path $PSScriptRoot -Parent
$compiler = Join-Path $CompilerRoot 'installed\bin\i386-win32\fpc.exe'
$binutils = Join-Path $CompilerRoot 'b\install\binw32'
$out = Join-Path $repo 'build\ui-clean'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$originalPath = $env:Path
Push-Location (Join-Path $repo 'src')
try {
  $env:Path = (Split-Path $compiler) + ';' + $binutils + ';' + $env:Path
  & (Join-Path $binutils 'windres.exe') -i (Join-Path $repo 'res\link.rc') -o (Join-Path $repo 'res\link.res')
  if ($LASTEXITCODE -ne 0) { throw 'Resource compilation failed' }
  $arguments = @('-B','-n','-Si','-Sg','-Sc','-vewn',
    ('-Fu'+(Join-Path $CompilerRoot 'installed\units\i386-win32\*')),
    ('-Fu'+(Join-Path $repo 'src\base')), ('-Fu'+(Join-Path $repo 'src\screens')),
    ('-Fu'+(Join-Path $repo 'src\menu')), ('-Fi'+(Join-Path $repo 'src')),
    ('-FD'+$binutils), 'WorldParty.dpr', ('-FE'+$out), ('-FU'+$out),
    '-O4','-Xs','-oWorldParty.exe')
  & $compiler @arguments *> (Join-Path $repo 'build\ui-clean-compile.log')
  if ($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $repo 'build\ui-clean-compile.log') -Tail 25
    throw 'Game compilation failed'
  }
  Get-Item (Join-Path $out 'WorldParty.exe') | Select-Object FullName,Length,LastWriteTime
} finally { Pop-Location; $env:Path=$originalPath }
