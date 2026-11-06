# GLaDOS - local voice interface for Claude Code.
# Serves the page at http://localhost:8765, runs Claude Code headlessly for each message,
# turns replies into speech with Fish Audio, and transcribes the mic with ElevenLabs.
#
# Safety model: every message runs in LOOK-ONLY mode (read/search tools only; anything that
# changes the PC is blocked). When GLaDOS proposes a change it ends with [[CONFIRM]], and only
# an explicit confirmation from the page runs the next step with full permissions.
# A request that starts with "No need to ask" is PRE-APPROVED: it skips the confirmation step and
# runs at once with full permissions, the same as a confirmed plan.
# A request that is just asking to install something (e.g. "install ffmpeg") is also PRE-APPROVED
# for that reason alone: reads and installs run immediately, but writes/edits/deletes/other exec
# still require the normal plan-then-confirm step.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$Port       = 8765
$Root        = $PSScriptRoot
$Claude      = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$PersonaFile = Join-Path $Root 'persona.txt'
$WorkDir     = $env:USERPROFILE
$VoiceId     = 'ee885900b0874d12b1c3439d1e56cc95'   # Fish Audio voice model
$FishKey     = if ($env:FISH_API_KEY) { $env:FISH_API_KEY } else { [Environment]::GetEnvironmentVariable('FISH_API_KEY', 'User') }
$MaxSpeech   = 1500
$LogFile     = Join-Path $Root 'ultron.log'
$UploadDir   = Join-Path $Root 'uploads'
New-Item -ItemType Directory -Force -Path $UploadDir | Out-Null
$OutboxDir   = Join-Path $Root 'outbox'
New-Item -ItemType Directory -Force -Path $OutboxDir | Out-Null

# Claude in Chrome: free rein in every mode. Look-only runs may use every browser tool (read,
# navigate, click, type, submit, run script, upload) without a confirmation; only changes to
# the PC itself (files, commands) still need one.
$ChromeTools = 'list_connected_browsers,select_browser,tabs_context_mcp,read_page,get_page_text,find,read_console_messages,read_network_requests,shortcuts_list,computer,browser_batch,navigate,form_input,javascript_tool,file_upload,upload_image,gif_creator,resize_window,switch_browser,shortcuts_execute,tabs_create_mcp,tabs_close_mcp'
$ChromePre   = 'mcp__claude-in-chrome__'

# The bare server name also covers any browser tools added in future versions.
$LookOnlyAllowed    = 'Read,Glob,Grep,WebSearch,WebFetch,mcp__claude-in-chrome,' + (($ChromeTools -split ',' | ForEach-Object { $ChromePre + $_ }) -join ',')
$LookOnlyDisallowed = 'Bash,PowerShell,Write,Edit,NotebookEdit'

$PreApprovedPhrase = '^\W*no need to ask( me)?\b\W*'
# Install-only requests skip confirmation too (installing a package is low-risk and reversible);
# this does not match "uninstall" since \b requires a boundary right before "install".
$InstallRequestPhrase = '\binstall(s|ed|ing)?\b'

# Random per-run token: the page must send it back, so other websites can't drive GLaDOS.
$Token = [guid]::NewGuid().ToString('N')
$Url   = "http://localhost:$Port/"
# Phone access goes through `tailscale serve`, which gives GLaDOS a private HTTPS address on the
# tailnet (phones only allow the microphone on HTTPS pages) and forwards it here over loopback.
# Its requests carry the tailnet host name, so the server binds http://+:8765/ when the one-time
# admin reservation (`netsh http add urlacl url=http://+:8765/ user=<you>`) exists, and falls back
# to localhost-only otherwise. No firewall rule is needed: tailscale serve connects over loopback.
$TailnetOrigin = '^https://[a-z0-9-]+\.[a-z0-9-]+\.ts\.net$'

$script:SessionId      = $null
$script:PendingConfirm = $false
$script:CancelNote     = $false

function Log($msg) { Add-Content -Path $LogFile -Value "$(Get-Date -Format s) $msg" -Encoding UTF8 }

function Open-Ui {
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
              "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    # Autoplay flag lets replies to "Hey GLaDOS" play before the window is clicked (ignored if Edge is already running).
    if ($edge) { Start-Process $edge @("--app=$Url", '--autoplay-policy=no-user-gesture-required') } else { Start-Process $Url }
}

function Quote-Arg([string]$s) {
    if ($s -notmatch '[\s"]' -and $s.Length -gt 0) { return $s }
    '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Send-Bytes($resp, [byte[]]$bytes, [string]$type, [int]$status = 200) {
    $resp.StatusCode = $status
    $resp.ContentType = $type
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Send-Json($resp, $obj, [int]$status = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 5))
    Send-Bytes $resp $bytes 'application/json; charset=utf-8' $status
}

# One JSON object per line, flushed right away so the page can show progress live.
function Send-Line($resp, $obj) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 5) + "`n")
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        $resp.OutputStream.Flush()
    } catch { }   # page closed or navigated away; keep going
}

function Read-Body($req) {
    $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    if ($raw) { $raw | ConvertFrom-Json } else { $null }
}

function Get-SpeechText([string]$text) {
    $t = $text -replace '\[\[CONFIRM\]\]', ''
    $t = [regex]::Replace($t, '(?s)```.*?```', ' ')
    $t = [regex]::Replace($t, '`([^`]*)`', '$1')
    $t = [regex]::Replace($t, '<[^>]+>', '')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]+\)', '$1')
    $t = [regex]::Replace($t, '(?m)^\s*(#+|[-*>]|\d+\.)\s+', '')
    $t = [regex]::Replace($t, '[*_#|]', '')
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    if ($t.Length -gt $MaxSpeech) {
        $cut = $t.Substring(0, $MaxSpeech)
        $end = $cut.LastIndexOfAny([char[]]'.!?')
        $t = if ($end -gt 200) { $cut.Substring(0, $end + 1) } else { $cut }
    }
    $t
}

function Describe-Tool($tool) {
    $i = $tool.input
    $detail = switch -Regex ($tool.name) {
        '^(Read|Write|Edit)$' { Split-Path -Leaf ([string]$i.file_path) }
        '^(Glob|Grep)$'       { [string]$i.pattern }
        '^WebSearch$'         { [string]$i.query }
        '^WebFetch$'          { ([string]$i.url) -replace '^https?://', '' }
        '^(Bash|PowerShell)$' { [string]$i.description }
        default               { '' }
    }
    $label = switch ($tool.name) {
        'Read' { 'Reading' }  'Write' { 'Writing' }  'Edit' { 'Editing' }
        'Glob' { 'Looking for' }  'Grep' { 'Searching for' }
        'WebSearch' { 'Searching the web for' }  'WebFetch' { 'Opening' }
        'Bash' { 'Running' }  'PowerShell' { 'Running' }
        default { "Using $($tool.name)" }
    }
    if ($detail.Length -gt 60) { $detail = $detail.Substring(0, 57) + '...' }
    "$label $detail".Trim()
}

function Invoke-Chat($ctx, $body) {
    $resp = $ctx.Response
    $resp.ContentType = 'application/x-ndjson; charset=utf-8'
    $resp.SendChunked = $true

    $confirmed = [bool]$body.confirm
    if ($confirmed -and -not $script:PendingConfirm) {
        Send-Line $resp @{ type = 'reply'; text = 'There is nothing waiting for confirmation.'; needsConfirm = $false }
        $resp.OutputStream.Close(); return
    }

    # The phrase is checked here on the user's own words, so GLaDOS can never pre-approve herself.
    $preApproved = (-not $confirmed) -and (([string]$body.text -match $PreApprovedPhrase) -or ([string]$body.text -match $InstallRequestPhrase))
    if ($confirmed) {
        $prompt = 'CONFIRMED: The user confirmed. Carry out exactly the plan you just proposed, nothing more, then briefly say what you did.'
    } elseif ($preApproved) {
        $request = [string]$body.text -replace $PreApprovedPhrase, ''
        $prompt = "PRE-APPROVED: $request"
    } else {
        $prompt = [string]$body.text
    }
    if (-not $confirmed -and $script:CancelNote) { $prompt = "(The user cancelled your previous proposal, so it was not carried out.) $prompt" }
    $script:PendingConfirm = $false
    $script:CancelNote = $false

    $argList = @('-p', '--chrome', '--model', 'sonnet', '--output-format', 'stream-json', '--verbose', '--append-system-prompt-file', $PersonaFile)
    if ($script:SessionId) { $argList += @('--resume', $script:SessionId) }
    if ($confirmed -or $preApproved) {
        $argList += '--dangerously-skip-permissions'
    } else {
        $argList += @('--permission-mode', 'default', '--allowedTools', $LookOnlyAllowed, '--disallowedTools', $LookOnlyDisallowed)
    }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Claude
    $psi.Arguments = ($argList | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['GLADOS_UI'] = '1'

    Log "chat confirmed=$confirmed preApproved=$preApproved session=$($script:SessionId)"
    Send-Line $resp @{ type = 'status'; text = $(if ($confirmed) { 'Carrying out the plan' } elseif ($preApproved) { 'Pre-approved' } else { 'Thinking' }) }

    $p = [Diagnostics.Process]::Start($psi)
    $inBytes = [Text.Encoding]::UTF8.GetBytes($prompt)
    $p.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
    $p.StandardInput.Close()
    $errTask = $p.StandardError.ReadToEndAsync()

    $final = $null; $isError = $false
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        try { $ev = $line | ConvertFrom-Json } catch { continue }
        if ($ev.session_id) { $script:SessionId = $ev.session_id }
        if ($ev.type -eq 'assistant') {
            foreach ($block in @($ev.message.content)) {
                if ($block.type -eq 'tool_use') { Send-Line $resp @{ type = 'status'; text = (Describe-Tool $block) } }
            }
        } elseif ($ev.type -eq 'result') {
            $final = [string]$ev.result
            $isError = [bool]$ev.is_error
        }
    }
    $p.WaitForExit()
    $stderr = $errTask.Result

    if ($null -eq $final -or $final -eq '') {
        Log "no result. exit=$($p.ExitCode) stderr=$stderr"
        if ($stderr -match 'session|conversation') { $script:SessionId = $null }
        $msg = if ($stderr) { ($stderr.Trim() -split "`n")[0] } else { "Claude Code exited with code $($p.ExitCode)." }
        Send-Line $resp @{ type = 'error'; text = $msg }
    } else {
        $needs = (-not $confirmed) -and ($final -match '\[\[CONFIRM\]\]')
        $script:PendingConfirm = $needs
        $clean = ($final -replace '\[\[CONFIRM\]\]', '').Trim()
        if ($isError) { Log "result error: $clean" }
        Send-Line $resp @{ type = 'reply'; text = $clean; needsConfirm = $needs }
    }
    $resp.OutputStream.Close()
}

# Photo from the page -> saved to disk -> { path } so /chat can ask Claude to look at it.
function Invoke-Image($ctx) {
    $req = $ctx.Request
    $ms = New-Object IO.MemoryStream
    $req.InputStream.CopyTo($ms)
    $bytes = $ms.ToArray()
    if ($bytes.Length -lt 100) { Send-Json $ctx.Response @{ error = 'No image received' } 400; return }

    $type = if ($req.ContentType) { ($req.ContentType -split ';')[0] } else { 'image/jpeg' }
    $ext  = switch -Regex ($type) {
        'png'  { 'png' }
        'webp' { 'webp' }
        'gif'  { 'gif' }
        default { 'jpg' }
    }
    $name = "img_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$([guid]::NewGuid().ToString('N').Substring(0,6)).$ext"
    $path = Join-Path $UploadDir $name
    [IO.File]::WriteAllBytes($path, $bytes)
    Log "image saved: $path ($($bytes.Length) bytes)"
    Send-Json $ctx.Response @{ path = $path }
}

# Video from the page -> saved to disk -> { path }, same flow as the photo upload.
function Invoke-Video($ctx) {
    $req = $ctx.Request
    $ms = New-Object IO.MemoryStream
    $req.InputStream.CopyTo($ms)
    $bytes = $ms.ToArray()
    if ($bytes.Length -lt 100) { Send-Json $ctx.Response @{ error = 'No video received' } 400; return }

    $type = if ($req.ContentType) { ($req.ContentType -split ';')[0] } else { 'video/mp4' }
    $ext  = switch -Regex ($type) {
        'quicktime' { 'mov' }
        'webm'      { 'webm' }
        'matroska'  { 'mkv' }
        default     { 'mp4' }
    }
    $name = "vid_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$([guid]::NewGuid().ToString('N').Substring(0,6)).$ext"
    $path = Join-Path $UploadDir $name
    [IO.File]::WriteAllBytes($path, $bytes)
    Log "video saved: $path ($($bytes.Length) bytes)"
    Send-Json $ctx.Response @{ path = $path }
}

# PC -> phone: whatever's dropped in outbox/ is listed and served for download over Tailscale.
function Invoke-FilesList($ctx) {
    $files = @(Get-ChildItem -Path $OutboxDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
        @{ name = $_.Name; size = $_.Length; modified = $_.LastWriteTime.ToString('s') }
    })
    Send-Json $ctx.Response @{ files = $files }
}

function Invoke-FilesGet($ctx, $body) {
    $name = [string]$body.name
    if (-not $name -or $name -match '[\\/]') { Send-Json $ctx.Response @{ error = 'Invalid file name' } 400; return }
    $path = Join-Path $OutboxDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Send-Json $ctx.Response @{ error = 'Not found' } 404; return }

    $ext  = [IO.Path]::GetExtension($name).TrimStart('.').ToLower()
    $type = switch ($ext) {
        'png'  { 'image/png' }
        'jpg'  { 'image/jpeg' }
        'jpeg' { 'image/jpeg' }
        'gif'  { 'image/gif' }
        'webp' { 'image/webp' }
        'pdf'  { 'application/pdf' }
        'txt'  { 'text/plain' }
        default { 'application/octet-stream' }
    }
    $ctx.Response.Headers['Content-Disposition'] = "attachment; filename=`"$name`""
    Send-Bytes $ctx.Response ([IO.File]::ReadAllBytes($path)) $type
    Log "outbox file sent: $name"
}

function Invoke-Tts($ctx, $body) {
    $text = Get-SpeechText ([string]$body.text)
    if (-not $text) { $ctx.Response.StatusCode = 204; $ctx.Response.Close(); return }
    if (-not $FishKey) { Send-Json $ctx.Response @{ error = 'FISH_API_KEY is not set' } 500; return }

    try {
        $json = @{ text = $text } | ConvertTo-Json -Compress
        $client = New-Object Net.Http.HttpClient
        $content = New-Object Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
        $proxy = $client.PostAsync('http://127.0.0.1:18766/tts', $content).GetAwaiter().GetResult()
        try {
            if (-not $proxy.IsSuccessStatusCode) { throw "Fish streaming proxy returned HTTP $([int]$proxy.StatusCode)" }
            Send-Bytes $ctx.Response $proxy.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() 'audio/mpeg'
        } finally { $proxy.Dispose(); $content.Dispose(); $client.Dispose() }
    } catch {
        Log "tts error: $($_.Exception.Message) $($_.ErrorDetails.Message)"
        Send-Json $ctx.Response @{ error = 'Text-to-speech failed' } 502
    }
}

# Push-to-talk audio from the page -> ElevenLabs speech-to-text -> { text }
function Invoke-Stt($ctx) {
    $sttClock = [Diagnostics.Stopwatch]::StartNew()
    $req = $ctx.Request
    $ms = New-Object IO.MemoryStream
    $req.InputStream.CopyTo($ms)
    $audio = $ms.ToArray()
    Log "stt received: $($audio.Length) bytes content-type=$($req.ContentType) origin=$($req.Headers['Origin'])"
    if ($audio.Length -lt 1000) { Log "stt skipped: only $($audio.Length) bytes"; Send-Json $ctx.Response @{ text = '' }; return }
    if (-not $env:ELEVENLABS_API_KEY) { Send-Json $ctx.Response @{ error = 'ELEVENLABS_API_KEY is not set' } 500; return }

    $type = if ($req.ContentType) { ($req.ContentType -split ';')[0] } else { 'audio/webm' }
    $ext  = if ($type -match 'ogg') { 'ogg' } elseif ($type -match 'mp4') { 'mp4' } else { 'webm' }

    $client = New-Object Net.Http.HttpClient
    try {
        $client.DefaultRequestHeaders.Add('xi-api-key', $env:ELEVENLABS_API_KEY)
        $form = New-Object Net.Http.MultipartFormDataContent
        $form.Add((New-Object Net.Http.StringContent('scribe_v1')), 'model_id')
        $form.Add((New-Object Net.Http.StringContent('false')), 'tag_audio_events')
        $file = New-Object Net.Http.ByteArrayContent(,$audio)
        $file.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse($type)
        $form.Add($file, 'file', "speech.$ext")
        $res  = $client.PostAsync('https://api.elevenlabs.io/v1/speech-to-text', $form).Result
        $json = $res.Content.ReadAsStringAsync().Result
        if (-not $res.IsSuccessStatusCode) {
            Log "stt error $([int]$res.StatusCode): $json"
            Send-Json $ctx.Response @{ error = 'Speech-to-text failed'; detail = $json } 502; return
        }
        $heard = [string]($json | ConvertFrom-Json).text
        Log "stt timing: total=$([int]$sttClock.ElapsedMilliseconds)ms bytes=$($audio.Length)"
        Send-Json $ctx.Response @{ text = $heard }
    } finally {
        $client.Dispose()
    }
}

# Live PC stats for the side panel. Runs in its own runspace with its own listener on /stats/,
# so the numbers keep flowing even while the main loop is busy with a long /chat request.
$StatsScript = {
    param($Prefix, $Token, $LogFile)
    function New-Counter($cat, $name, $inst) {
        try { $c = New-Object Diagnostics.PerformanceCounter($cat, $name, $inst, $true); [void]$c.NextValue(); $c } catch { $null }
    }
    function Read-Counter($c) { if ($c) { try { $c.NextValue() } catch { 0 } } else { 0 } }
    try {
        $cpu = New-Counter 'Processor Information' '% Processor Utility' '_Total'
        if (-not $cpu) { $cpu = New-Counter 'Processor' '% Processor Time' '_Total' }
        $disk     = New-Counter 'PhysicalDisk' '% Idle Time' '_Total'
        $memAvail = New-Counter 'Memory' 'Available Bytes' ''
        $memTotal = [double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        $gpu = @{}; $net = @{}; $lastScan = [datetime]::MinValue
        $stats = @{ cpu = 0; mem = 0; memUsed = 0; memTotal = [math]::Round($memTotal / 1GB, 1); gpu = 0; disk = 0; rx = 0; tx = 0 }

        $listener = New-Object Net.HttpListener
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $task = $listener.GetContextAsync()

        while ($listener.IsListening) {
            # GPU engine and network instances come and go, so rescan them now and then.
            if (((Get-Date) - $lastScan).TotalSeconds -ge 10) {
                $names = try { (New-Object Diagnostics.PerformanceCounterCategory 'GPU Engine').GetInstanceNames() | Where-Object { $_ -like '*engtype_3D' } } catch { @() }
                foreach ($n in @($gpu.Keys)) { if ($names -notcontains $n) { $gpu[$n].Dispose(); $gpu.Remove($n) } }
                foreach ($n in $names) { if (-not $gpu.ContainsKey($n)) { $c = New-Counter 'GPU Engine' 'Utilization Percentage' $n; if ($c) { $gpu[$n] = $c } } }
                $names = try { (New-Object Diagnostics.PerformanceCounterCategory 'Network Interface').GetInstanceNames() } catch { @() }
                foreach ($n in $names) {
                    if (-not $net.ContainsKey($n)) { $net[$n] = @{ rx = New-Counter 'Network Interface' 'Bytes Received/sec' $n; tx = New-Counter 'Network Interface' 'Bytes Sent/sec' $n } }
                }
                $lastScan = Get-Date
            }

            $g = 0; foreach ($c in $gpu.Values) { $g += Read-Counter $c }
            $rx = 0; $tx = 0; foreach ($n in $net.Values) { $rx += Read-Counter $n.rx; $tx += Read-Counter $n.tx }
            $used = $memTotal - (Read-Counter $memAvail)
            $stats.cpu     = [math]::Round([math]::Min(100, (Read-Counter $cpu)), 1)
            $stats.gpu     = [math]::Round([math]::Min(100, $g), 1)
            $stats.disk    = [math]::Round([math]::Max(0, 100 - (Read-Counter $disk)), 1)
            $stats.mem     = [math]::Round(100 * $used / $memTotal, 1)
            $stats.memUsed = [math]::Round($used / 1GB, 1)
            $stats.rx      = [math]::Round($rx)
            $stats.tx      = [math]::Round($tx)

            # Answer requests for about a second, then sample again.
            $until = (Get-Date).AddSeconds(1)
            while (($left = ($until - (Get-Date)).TotalMilliseconds) -gt 0) {
                if (-not $task.AsyncWaitHandle.WaitOne([int]$left)) { break }
                $ctx = $task.GetAwaiter().GetResult()
                $task = $listener.GetContextAsync()
                try {
                    $resp = $ctx.Response
                    if ($ctx.Request.Headers['X-GLaDOS-Token'] -ne $Token) { $resp.StatusCode = 403; $resp.Close(); continue }
                    $bytes = [Text.Encoding]::UTF8.GetBytes(($stats | ConvertTo-Json -Compress))
                    $resp.ContentType = 'application/json'
                    $resp.Headers['Cache-Control'] = 'no-store'
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    $resp.OutputStream.Close()
                } catch { }
            }
        }
    } catch {
        Add-Content -Path $LogFile -Value "$(Get-Date -Format s) stats error: $($_.Exception.Message)" -Encoding UTF8
    }
}

function Handle($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath

    if ($req.HttpMethod -eq 'GET') {
        if ($path -eq '/') {
            $html = [IO.File]::ReadAllText((Join-Path $Root 'index.html'), [Text.Encoding]::UTF8).Replace('{{TOKEN}}', $Token)
            Send-Bytes $ctx.Response ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
        } elseif ($path -eq '/chamber-preview' -or $path -eq '/chamber-preview.html') {
            $html = [IO.File]::ReadAllText((Join-Path $Root 'chamber-preview.html'), [Text.Encoding]::UTF8)
            Send-Bytes $ctx.Response ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
        } elseif ($path -eq '/glados_model.glb' -or $path -eq '/glados_model_mobile.glb' -or $path -eq '/chamber_model.glb' -or $path -eq '/chamber_from_scratch/chamber_environment.glb' -or $path -match '^/core_variants/[a-zA-Z0-9_-]+\.glb$') {
            # 3D model assets for the GLaDOS viewer scene, served straight from disk. The path is
            # resolved and checked against $Root before reading so a crafted path (e.g. "..") can't
            # escape the project directory.
            $rel = $path.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
            $full = [IO.Path]::GetFullPath((Join-Path $Root $rel))
            $rootFull = [IO.Path]::GetFullPath($Root)
            if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $full -PathType Leaf)) {
                $ctx.Response.Headers['Cache-Control'] = 'public, max-age=604800, immutable'
                Send-Bytes $ctx.Response ([IO.File]::ReadAllBytes($full)) 'model/gltf-binary'
            } else {
                $ctx.Response.StatusCode = 404; $ctx.Response.Close()
            }
        } else {
            $ctx.Response.StatusCode = 404; $ctx.Response.Close()
        }
        return
    }

    # Every action needs the page's token and must come from this page, not another website.
    $origin = $req.Headers['Origin']
    $originOk = (-not $origin) -or ($origin.TrimEnd('/') -eq $Url.TrimEnd('/')) -or ($origin -match $TailnetOrigin)
    if ($req.HttpMethod -ne 'POST' -or $req.Headers['X-GLaDOS-Token'] -ne $Token -or -not $originOk) {
        $ctx.Response.StatusCode = 403; $ctx.Response.Close(); return
    }

    if ($path -eq '/stt') { Invoke-Stt $ctx; return }
    if ($path -eq '/image') { Invoke-Image $ctx; return }
    if ($path -eq '/video') { Invoke-Video $ctx; return }

    $body = Read-Body $req
    switch ($path) {
        '/chat'        { if ($env:GLADOS_BRAIN -eq 'openclaw') { Invoke-OpenClawChat $ctx $body } else { Invoke-Chat $ctx $body } }
        '/tts'         { Invoke-Tts $ctx $body }
        '/files/list'  { Invoke-FilesList $ctx }
        '/files/get'   { Invoke-FilesGet $ctx $body }
        '/cancel' { $script:OpenClawPendingPlan = $null; $script:OpenClawPendingRequest = $null; $script:PendingConfirm = $false; $script:CancelNote = $true; Send-Json $ctx.Response @{ ok = $true } }
        '/reset'  { Reset-OpenClawConversation; $script:SessionId = $null; $script:PendingConfirm = $false; $script:CancelNote = $false; Send-Json $ctx.Response @{ ok = $true } }
        default   { $ctx.Response.StatusCode = 404; $ctx.Response.Close() }
    }
}

. (Join-Path $Root 'openclaw-bridge.ps1')

# --- start ---
function Start-Listener([string]$base) {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add($base)
    try { $l.Start(); $l } catch { $l.Close(); Log "could not bind ${base}: $($_.Exception.Message)"; $null }
}

# All hosts (for tailscale serve) if the admin reservation exists, otherwise localhost only.
$BindBase = "http://+:$Port/"
$listener = Start-Listener $BindBase
if (-not $listener) {
    $BindBase = $Url
    $listener = Start-Listener $BindBase
}
if (-not $listener) {
    # Most likely GLaDOS is already running, so just open the window. The log line above says
    # why if it isn't (for example a leftover URL reservation for this port).
    Open-Ui
    exit 0
}

$statsPs = [PowerShell]::Create().AddScript($StatsScript).AddArgument("${BindBase}stats/").AddArgument($Token).AddArgument($LogFile)
$null = $statsPs.BeginInvoke()

Log "GLaDOS started on $Url"
Write-Host "GLaDOS is running at $Url  (close this window to shut GLaDOS down)" -ForegroundColor Red
Open-Ui

while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(250)) { }   # lets Ctrl+C work between requests
    $ctx = $task.GetAwaiter().GetResult()
    try {
        Handle $ctx
    } catch {
        Log "request error: $($_.Exception.Message)"
        try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch { }
    }
}

