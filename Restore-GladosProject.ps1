<#
Restores a GLaDOS/OpenClaw backup zip onto a (possibly new) machine.
Unzips into a staging folder, rewrites all hardcoded absolute paths from the
original machine's base path to this machine's target base path, then copies
the result into place. Existing files at the destination are NOT overwritten
without confirmation.
#>
param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [string]$TargetBase = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$stagingRoot = Join-Path $env:TEMP ("glados-restore-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
Expand-Archive -Path $ZipPath -DestinationPath $stagingRoot -Force

$sourceBaseFile = Join-Path $stagingRoot "SOURCE_BASE_PATH.txt"
if (-not (Test-Path $sourceBaseFile)) {
    throw "SOURCE_BASE_PATH.txt not found in archive; this doesn't look like a Backup-GladosProject.ps1 zip."
}
$sourceBase = (Get-Content $sourceBaseFile -Raw).Trim()

Write-Output "Rewriting paths: '$sourceBase' -> '$TargetBase'"

# Rewrite both forward-slash and escaped-backslash variants (JSON uses both across the file).
$sourceFwd = $sourceBase -replace '\\', '/'
$targetFwd = $TargetBase -replace '\\', '/'
$sourceEsc = $sourceBase -replace '\\', '\\\\'
$targetEsc = $TargetBase -replace '\\', '\\\\'

$textFiles = Get-ChildItem $stagingRoot -Recurse -File -Include *.json, *.md, *.txt
foreach ($f in $textFiles) {
    if ($f.Name -eq "SOURCE_BASE_PATH.txt") { continue }
    $content = Get-Content $f.FullName -Raw
    $updated = $content.Replace($sourceEsc, $targetEsc).Replace($sourceFwd, $targetFwd).Replace($sourceBase, $TargetBase)
    if ($updated -ne $content) {
        Set-Content -Path $f.FullName -Value $updated -Encoding utf8 -NoNewline
    }
}

Write-Output ""
Write-Output "Staged, path-rewritten restore is ready at: $stagingRoot"
Write-Output "Review it, then manually copy into place, e.g.:"
Write-Output "  Copy-Item '$stagingRoot\openclaw.json' '$TargetBase\openclaw\openclaw.json'"
Write-Output "  Copy-Item '$stagingRoot\workspaces\*' '$TargetBase\openclaw\workspaces\' -Recurse"
Write-Output "  Copy-Item '$stagingRoot\state\openclaw.sqlite' '$TargetBase\openclaw\state\openclaw.sqlite'"
Write-Output "  Copy-Item '$stagingRoot\claude-memory\*' 'C:\Users\<you>\.claude\projects\<project-key>\memory\' -Recurse"
Write-Output ""
Write-Output "Remaining manual steps on the new machine:"
Write-Output "  1. Install Node.js and OpenClaw (npm install)."
Write-Output "  2. Reinstall Ollama and run: ollama pull qwen3:8b"
Write-Output "  3. Re-auth the Discord channel / re-run browser-extension pairing (secrets are not carried in the backup)."
Write-Output "This script does NOT overwrite your live config automatically -- copy the staged files in yourself after reviewing the diff."
