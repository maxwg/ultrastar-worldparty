[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$CompilerRoot,
  [string]$PythonPath = (Get-Command python -ErrorAction Stop).Source,
  [string]$FfmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source,
  [switch]$NoFade,
  [switch]$CancelDownload,
  [switch]$WideWindow
)
$ErrorActionPreference='Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$root = Join-Path $repo ('work\library-e2e-' + [Guid]::NewGuid().ToString('N').Substring(0,10))
$runtime = Join-Path $root 'runtime'
$units = Join-Path $root 'units'
New-Item -ItemType Directory -Path $runtime,$units | Out-Null
foreach($name in @('avatars','covers','fonts','languages','licenses','plugins','resources','soundfonts','sounds','themes','visuals','webs')) {
  New-Item -ItemType Junction -Path (Join-Path $runtime $name) -Target (Join-Path $repo ('game\'+$name)) | Out-Null
}
$prepareArguments=@((Join-Path $PSScriptRoot 'prepare.py'),'--repo',$repo,'--runtime',$runtime,'--ffmpeg',$FfmpegPath)
if($NoFade){$prepareArguments+='--no-fade'}
if($WideWindow){$prepareArguments+='--wide-window'}
& $PythonPath @prepareArguments
if($LASTEXITCODE -ne 0){throw 'Fixture preparation failed'}
$compiler = Join-Path $CompilerRoot 'installed\bin\i386-win32\fpc.exe'
$flags = @('-B','-n','-Si','-Sg','-Sc','-vewn','-dLIBRARY_E2E','-dDEBUG_MODE',
  ('-Fu'+(Join-Path $CompilerRoot 'installed\units\i386-win32\*')),
  ('-Fu'+(Join-Path $repo 'src\base')), ('-Fu'+(Join-Path $repo 'src\screens')),
  ('-Fu'+(Join-Path $repo 'src\menu')), ('-Fu'+$PSScriptRoot), ('-Fi'+(Join-Path $repo 'src')),
  ('-FD'+(Join-Path $CompilerRoot 'b\install\binw32')), 'WorldParty.dpr',
  ('-FE'+$runtime), ('-FU'+$units), '-O2','-gl','-oWorldPartyE2E.exe')
Push-Location (Join-Path $repo 'src')
try { & $compiler @flags *> (Join-Path $root 'compile.log'); $code=$LASTEXITCODE }
finally { Pop-Location }
if($code -ne 0){Get-Content (Join-Path $root 'compile.log') -Tail 20;throw 'Test game compilation failed'}
$testFlags=@('-n','-Si','-Sg','-Sc',('-Fu'+$units),
  ('-Fu'+(Join-Path $CompilerRoot 'installed\units\i386-win32\*')),
  ('-Fu'+(Join-Path $repo 'src\base')),
  ('-FD'+(Join-Path $CompilerRoot 'b\install\binw32')),
  ('-FE'+$root),('-FU'+$units),'-O2')
foreach($test in @('library_search_index_test','text_input_events_test')) {
  & $compiler @testFlags (Join-Path $repo ('tests\'+$test+'.pas')) *> (Join-Path $root ($test+'-compile.log'))
  if($LASTEXITCODE -ne 0){Get-Content (Join-Path $root ($test+'-compile.log'));throw 'Search regression compilation failed'}
  & (Join-Path $root ($test+'.exe')) | Tee-Object -FilePath (Join-Path $root ($test+'-result.txt'))
  if($LASTEXITCODE -ne 0){throw 'Search regression failed'}
}
$runArguments=@((Join-Path $PSScriptRoot 'run.py'),'--runtime',$runtime)
if($CancelDownload){$runArguments+='--cancel-download'}
& $PythonPath @runArguments
if($LASTEXITCODE -ne 0){throw 'End-to-end game verification failed'}
Write-Output ('Evidence: '+$root)
