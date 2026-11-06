$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'openclaw-env.ps1')
$env:FISH_PROXY_PORT = '18766'
$env:FISH_VOICE_ID = 'ee885900b0874d12b1c3439d1e56cc95'
function Test-FishProxy {
    try { $null = Invoke-WebRequest 'http://127.0.0.1:18766/' -UseBasicParsing -TimeoutSec 2; return $true } catch { return $false }
}
$fishProxy = Join-Path $PSScriptRoot 'fish-proxy\fish-stream.mjs'
if ((Test-Path -LiteralPath $fishProxy) -and -not (Test-FishProxy)) {
    Start-Process -FilePath (Join-Path $PSScriptRoot 'node\node.exe') -ArgumentList @($fishProxy) -WorkingDirectory (Join-Path $PSScriptRoot 'fish-proxy') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $PSScriptRoot 'fish-proxy\fish.stdout.log') -RedirectStandardError (Join-Path $PSScriptRoot 'fish-proxy\fish.stderr.log') | Out-Null
    for ($i = 0; $i -lt 20; $i++) { if (Test-FishProxy) { break }; Start-Sleep -Milliseconds 500 }
}
function Test-LocalOllama {
    try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2; return $true } catch { return $false }
}
$ollamaExe = Join-Path $PSScriptRoot 'ollama\ollama.exe'
if ((Test-Path -LiteralPath $ollamaExe) -and -not (Test-LocalOllama)) {
    Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WorkingDirectory (Split-Path $ollamaExe) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $PSScriptRoot 'ollama\ollama.stdout.log') -RedirectStandardError (Join-Path $PSScriptRoot 'ollama\ollama.stderr.log') | Out-Null
    for ($i = 0; $i -lt 30; $i++) { if (Test-LocalOllama) { break }; Start-Sleep -Seconds 1 }
}
function Test-GladosGateway {
    try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:18789/v1/models' -Headers @{Authorization = "Bearer $env:GLADOS_GATEWAY_TOKEN"} -TimeoutSec 2; return $true } catch { return $false }
}
if (-not (Test-GladosGateway)) {
    # The gateway takes ~2 minutes to become ready after boot; don't spawn a second one while the first is still starting.
    $gatewayStarting = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'openclaw\.mjs.* gateway run' }).Count -gt 0
    if (-not $gatewayStarting) {
        $gatewayScript = Join-Path $PSScriptRoot 'openclaw-gateway.ps1'
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$gatewayScript+'"')) -RedirectStandardOutput (Join-Path $env:OPENCLAW_STATE_DIR 'gateway.stdout.log') -RedirectStandardError (Join-Path $env:OPENCLAW_STATE_DIR 'gateway.stderr.log') | Out-Null
    }
    $ready = $false
    for ($i = 0; $i -lt 240; $i++) { if (Test-GladosGateway) { $ready = $true; break }; Start-Sleep -Milliseconds 1000 }
    if (-not $ready) { throw 'OpenClaw did not start. Check openclaw\gateway.stderr.log.' }
}
try { $null = Invoke-WebRequest 'http://localhost:8765/' -UseBasicParsing -TimeoutSec 2; $uiRunning = $true } catch { $uiRunning = $false }
if ($uiRunning) { throw 'A GLaDOS server is already running. Close that server before using this launcher; it will not be stopped automatically.' }
$nodeScript = Join-Path $PSScriptRoot 'Start-GLaDOS-Node.ps1'
$nodeConnected = $false
try {
    $nodeStatusText = & (Join-Path $PSScriptRoot 'node\openclaw.cmd') nodes status --json 2>$null
    if ($LASTEXITCODE -eq 0) {
        $nodeStatus = ($nodeStatusText -join "`n") | ConvertFrom-Json
        $nodeConnected = @($nodeStatus.nodes | Where-Object { $_.displayName -eq 'GLaDOS PC' -and $_.connected }).Count -gt 0
    }
} catch { $nodeConnected = $false }
if (-not $nodeConnected) {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $nodeScript + '"')) -RedirectStandardOutput (Join-Path $env:OPENCLAW_STATE_DIR 'node.stdout.log') -RedirectStandardError (Join-Path $env:OPENCLAW_STATE_DIR 'node.stderr.log') | Out-Null
    Start-Sleep -Seconds 2
}
$env:GLADOS_BRAIN = 'openclaw'
& (Join-Path $PSScriptRoot 'server.ps1')
