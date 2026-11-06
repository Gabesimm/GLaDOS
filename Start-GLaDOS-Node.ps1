$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'openclaw-env.ps1')
$openclaw = Join-Path $PSScriptRoot 'node\openclaw.cmd'
& $openclaw node run --host 127.0.0.1 --port 18789 --display-name 'GLaDOS PC' --commands screen.snapshot,computer.act