# Server-side OpenClaw adapter. The gateway credential never enters the browser.
function Reset-OpenClawConversation {
    $script:OpenClawConversation = [guid]::NewGuid().ToString('N')
    $script:OpenClawPendingPlan = $null
    $script:OpenClawPendingRequest = $null
    $script:OpenClawLastResult = $null
}
Reset-OpenClawConversation

function New-OpenClawTurn($body) {
    $confirmed = [bool]$body.confirm
    $text = [string]$body.text
    if ($confirmed -and (-not $script:PendingConfirm -or -not $script:OpenClawPendingPlan)) {
        throw 'There is nothing waiting for confirmation.'
    }
    $preApproved = (-not $confirmed) -and (($text -match $PreApprovedPhrase) -or ($text -match $InstallRequestPhrase))
    $execute = $confirmed -or $preApproved
    # GLaDOS herself now carries full read/write/exec permissions (no separate read-only tier),
    # so a confirmed step runs in the same continuous session rather than switching agents.
    $agent = 'glados'
    if ($confirmed) {
        $text = "The user confirmed this exact destructive step. Carry out only this, nothing more.`nOriginal request: $($script:OpenClawPendingRequest)`nApproved step: $($script:OpenClawPendingPlan)"
    } elseif ($preApproved) {
        $text = 'The user explicitly pre-approved this request: ' + ($text -replace $PreApprovedPhrase, '')
    } else {
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'Please provide a message.' }
        if ($script:CancelNote) { $text = "The user cancelled the previous plan; it was not authorized.`n" + $text }
        if ($script:OpenClawLastResult) { $text = "Result of the previous confirmed task (reference only): $($script:OpenClawLastResult)`nCurrent user message: " + $text }
    }
    $conversation = $script:OpenClawConversation
    return @{ agent = $agent; execute = $execute; original = [string]$body.text; payload = @{
        model = "openclaw/$agent"; user = "glados-$conversation"; stream = $true
        messages = @(@{role = 'user'; content = $text})
    } }
}

function Get-OpenClawActivity([string]$SessionUser) {
    $sessionLookup = $SessionUser -replace '^glados-', ''
    $nodeExe = Join-Path $Root 'node\node.exe'
    $pollScript = Join-Path $Root 'poll-execute-reply.mjs'
    try {
        $out = & $nodeExe $pollScript $Root 'glados' $sessionLookup 0 '--peek' 2>$null | Select-Object -Last 1
        $parsed = $out | ConvertFrom-Json
        if ($parsed.ok -and $parsed.text) { return [string]$parsed.text }
    } catch { }
    return $null
}

function Invoke-OpenClawStream($payload, $resp) {
    $secretFile = Join-Path $Root 'openclaw\gateway.token'
    if (-not (Test-Path -LiteralPath $secretFile)) { throw 'OpenClaw setup is incomplete: gateway token is missing.' }
    $gatewayToken = [IO.File]::ReadAllText($secretFile).Trim()
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(660)
    $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $gatewayToken)
    $content = New-Object Net.Http.StringContent(($payload | ConvertTo-Json -Depth 10 -Compress), [Text.Encoding]::UTF8, 'application/json')
    $response = $null
    try {
        $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, 'http://127.0.0.1:18789/v1/chat/completions')
        $request.Content = $content
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ([int]$response.StatusCode -eq 500) {
                throw 'Both the GPT and Claude subscription routes are currently unavailable. OpenClaw is healthy; wait for a provider limit to reset or connect another provider. The request was not automatically retried.'
            }
            throw "OpenClaw returned HTTP $([int]$response.StatusCode). Check the gateway log; the request was not automatically retried."
        }
        $reader = New-Object IO.StreamReader($response.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
        $replyBuilder = New-Object Text.StringBuilder
        $streamStarted = [DateTime]::UtcNow
        Send-Line $resp @{type='status'; text='OpenClaw accepted the request; the model is processing it'}
        while ($true) {
            # OpenClaw may spend a while reasoning or running tools before its next SSE
            # event. Don't leave the browser/Tailscale response idle during that interval.
            $readTask = $reader.ReadLineAsync()
            while (-not $readTask.IsCompleted) {
                $readCompleted = $readTask.Wait([TimeSpan]::FromSeconds(15))
                if (-not $readCompleted) {
                    $elapsed = [int]([DateTime]::UtcNow - $streamStarted).TotalSeconds
                    if ($replyBuilder.Length -gt 0) {
                        $phase = "Drafting the response ($($replyBuilder.Length) characters received)"
                    } else {
                        $activity = Get-OpenClawActivity -SessionUser $payload.user
                        if ($activity) { $phase = "Latest activity: $activity" }
                        elseif ($elapsed -lt 30) { $phase = 'Waiting for the model to begin responding' }
                        else { $phase = 'Model is processing the request; no response text has arrived yet' }
                    }
                    Send-Line $resp @{type='status'; text="OpenClaw: $phase ($elapsed seconds)"}
                }
            }
            $line = $readTask.GetAwaiter().GetResult()
            if ($null -eq $line) { break }
            if (-not $line -or -not $line.StartsWith('data:')) { continue }
            $data = $line.Substring(5).Trim()
            if ($data -eq '[DONE]') { break }
            try { $event = $data | ConvertFrom-Json } catch { continue }
            if (-not $event.choices -or $event.choices.Count -eq 0) { continue }
            $delta = [string]$event.choices[0].delta.content
            if ($delta) {
                if ($replyBuilder.Length -eq 0) { Send-Line $resp @{type='status'; text='OpenClaw: drafting the response'} }
                [void]$replyBuilder.Append($delta)
                Send-Line $resp @{type='delta'; text=$delta}
            }
        }
        $reader.Dispose(); $request.Dispose()
        $reply = $replyBuilder.ToString()
        if ([string]::IsNullOrWhiteSpace($reply)) { throw 'OpenClaw returned no final reply. Check the gateway before retrying a task that could have made changes.' }
        return $reply
    } finally {
        if ($response) { $response.Dispose() }
        $content.Dispose(); $client.Dispose()
    }
}

function Wait-OpenClawSessionReply($Agent, $SessionUser, $TimeoutSeconds, $resp) {
    # A confirmed/delegated task almost always spawns a specialist worker and pauses
    # (sessions_spawn + sessions_yield) waiting on it. The chat-completions stream closes at
    # that pause point, before the coordinator's real final answer exists, so the caller sees
    # an empty reply. The true answer lands in the session's own transcript once it actually
    # finishes, so poll that directly instead of reporting a false "no response" failure.
    $dbPath = Join-Path $Root "openclaw\agents\$Agent\agent\openclaw-agent.sqlite"
    if (-not (Test-Path -LiteralPath $dbPath)) { return $null }
    $pollScript = Join-Path $Root 'poll-execute-reply.mjs'
    $nodeExe = Join-Path $Root 'node\node.exe'
    $sessionLookup = $SessionUser -replace '^glados-', ''
    # Poll in short slices so the page gets a real progress heartbeat every ~15s (whatever the
    # coordinator or delegated worker is actually doing right now) instead of going silent for
    # up to 8 minutes, which otherwise looks identical to the app being frozen.
    $sliceSeconds = 15
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $thisSlice = [Math]::Min($sliceSeconds, $TimeoutSeconds - $elapsed)
        $out = & $nodeExe $pollScript $Root $Agent $sessionLookup $thisSlice 2>&1 | Select-Object -Last 1
        try {
            $parsed = $out | ConvertFrom-Json
            if ($parsed.ok) { return $parsed.text }
        } catch {}
        $elapsed += $thisSlice
        if ($elapsed -lt $TimeoutSeconds) {
            $label = $null
            try {
                $peekOut = & $nodeExe $pollScript $Root $Agent $sessionLookup 0 '--peek' 2>&1 | Select-Object -Last 1
                $peekParsed = $peekOut | ConvertFrom-Json
                if ($peekParsed.ok) { $label = "$($peekParsed.text) ($elapsed seconds elapsed)" }
            } catch {}
            if (-not $label) { $label = "Worker is running; waiting for its next reported action ($elapsed`s elapsed)" }
            Send-Line $resp @{type = 'status'; text = $label}
        }
    }
    return $null
}

function Invoke-OpenClawChat($ctx, $body) {
    $resp = $ctx.Response
    $resp.ContentType = 'application/x-ndjson; charset=utf-8'
    $resp.SendChunked = $true
    try {
        $turn = New-OpenClawTurn $body
        # Consume confirmation before contacting the gateway; failure never replays a change.
        $script:PendingConfirm = $false
        $script:OpenClawPendingPlan = $null
        $script:OpenClawPendingRequest = $null
        $script:CancelNote = $false
        Send-Line $resp @{type = 'status'; text = $(if ($turn.execute) { 'OpenClaw: starting the approved task' } else { 'OpenClaw: sending request to GPT / Claude' })}
        try {
            $reply = Invoke-OpenClawStream $turn.payload $resp
        } catch {
            $streamErr = $_.Exception.Message
            # A confirmed task is already dispatched and running server-side regardless of what
            # happens to this HTTP connection (empty reply, dropped connection, timeout), so any
            # failure here is worth checking against the session's real outcome before giving up.
            if ($turn.execute -or $streamErr -match 'no final reply') {
                Send-Line $resp @{type = 'status'; text = 'OpenClaw: delegated task launched; monitoring worker activity'}
                $reply = Wait-OpenClawSessionReply -Agent $turn.agent -SessionUser $turn.payload.user -TimeoutSeconds 480 -resp $resp
            }
            if (-not $reply) { throw $streamErr }
        }
        $needs = (-not $turn.execute) -and ($reply -match '\[\[CONFIRM\]\]')
        $clean = ($reply -replace '\[\[CONFIRM\]\]', '').Trim()
        $script:PendingConfirm = $needs
        if ($needs) {
            $script:OpenClawPendingPlan = $clean
            $script:OpenClawPendingRequest = $turn.original
        }
        if ($turn.execute) { $script:OpenClawLastResult = $clean.Substring(0, [Math]::Min(4000, $clean.Length)) }
        Send-Line $resp @{type = 'reply'; text = $clean; needsConfirm = $needs}
    } catch {
        $msg = $_.Exception.Message
        Log ('OpenClaw request failed: ' + $msg)
        Send-Line $resp @{type = 'error'; text = $msg}
    } finally { $resp.OutputStream.Close() }
}
