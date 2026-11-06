<#
Packs the portable GLaDOS/OpenClaw project state into a single zip:
config, per-agent workspaces, session index db, and Claude memory files.
Excludes tmp/cache/npm/extensions/plugins/logs/backups (all reinstallable or disposable).
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot "backups")
)

$ErrorActionPreference = "Stop"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stagingRoot = Join-Path $env:TEMP "glados-backup-$stamp"
$zipPath = Join-Path $OutDir "glados-backup-$stamp.zip"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

$sourceBase = $PSScriptRoot
$openclawBase = Join-Path $sourceBase "openclaw"

# 1. openclaw.json + last-good backup (skip rolling .bak.N noise)
Copy-Item (Join-Path $openclawBase "openclaw.json") $stagingRoot -Force
Copy-Item (Join-Path $openclawBase "openclaw.json.last-good") $stagingRoot -Force -ErrorAction SilentlyContinue

# 2. workspaces (AGENTS.md, SOUL.md, per-agent memory)
Copy-Item (Join-Path $openclawBase "workspaces") (Join-Path $stagingRoot "workspaces") -Recurse -Force

# 3. session index db
$stateDst = Join-Path $stagingRoot "state"
New-Item -ItemType Directory -Force -Path $stateDst | Out-Null
Copy-Item (Join-Path $openclawBase "state\openclaw.sqlite") $stateDst -Force -ErrorAction SilentlyContinue

# 4. Claude Code memory files
$memSrc = "$env:USERPROFILE\.claude\projects\C--Users-$env:USERNAME-Ultron\memory"
if (Test-Path $memSrc) {
    Copy-Item $memSrc (Join-Path $stagingRoot "claude-memory") -Recurse -Force
}

# 5. record the source base path so restore can rewrite it
Set-Content -Path (Join-Path $stagingRoot "SOURCE_BASE_PATH.txt") -Value $sourceBase -Encoding utf8

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$stagingRoot\*" -DestinationPath $zipPath
Remove-Item $stagingRoot -Recurse -Force

Write-Output "Backup created: $zipPath"
Write-Output "Note: credentials\browser-extension-relay.secret and any Discord tokens are NOT included (secrets stay local)."
Write-Output "Note: Ollama/Qwen model weights are NOT included (reinstall Ollama + 'ollama pull qwen3:8b' on the new machine)."
