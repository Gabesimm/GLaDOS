$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'openclaw-env.ps1')
# Refuse an API-key login even if the operator later changes the native CLI account.
$ErrorActionPreference = 'Continue' # Codex writes its successful status to stderr on Windows.
$codexStatus = & (Join-Path $env:APPDATA 'npm\codex.cmd') login status 2>&1 | Out-String
$codexExit = $LASTEXITCODE
$claudeStatus = & (Join-Path $env:USERPROFILE '.local\bin\claude.exe') auth status --text 2>&1 | Out-String
$claudeExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($codexExit -ne 0 -or $codexStatus -notmatch 'Logged in using ChatGPT') { throw 'Codex needs a ChatGPT subscription login. Run codex login first.' }
if ($claudeExit -ne 0 -or $claudeStatus -notmatch 'Login method: Claude (Pro|Max|Team|Enterprise)') { throw 'Claude needs its subscription login. Run claude auth login first.' }
& (Join-Path $PSScriptRoot 'node\openclaw.cmd') gateway run
exit $LASTEXITCODE
