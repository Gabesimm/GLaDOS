# Spotify control for GLaDOS. Uses the app credentials in ~/.spotify_config.json and the saved
# login in ~/.spotify_tokens.json, refreshing the access token automatically when it expires.
#
# Usage: spotify.ps1 <command> [query]
#   play <song>            search for a song and play it (e.g. "Flashlight Pile of Heads")
#   play-album <album>     play an album
#   play-artist <artist>   play an artist
#   play-playlist <name>   play one of your playlists (falls back to searching all playlists)
#   queue <song>           add a song to the queue
#   pause | resume | next | previous
#   volume <0-100>
#   shuffle <on|off>
#   repeat <off|track|context>
#   status                 what's playing now
#   devices                list available Spotify devices
#   playlists              list your playlists

param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $env:USERPROFILE '.spotify_config.json'
$TokenFile  = Join-Path $env:USERPROFILE '.spotify_tokens.json'
$Query = ($Rest -join ' ').Trim()

function Fail($msg) { Write-Output "ERROR: $msg"; exit 1 }

function Get-Token {
    if (-not (Test-Path $TokenFile)) { Fail 'Not logged in to Spotify (no saved tokens).' }
    $tok = Get-Content $TokenFile -Raw | ConvertFrom-Json

    # expires_at is added by this script; older files only have the file's write time to go on.
    $expiresAt = if ($tok.PSObject.Properties['expires_at']) { [datetime]$tok.expires_at }
                 else { (Get-Item $TokenFile).LastWriteTime.AddSeconds([int]$tok.expires_in) }
    if ((Get-Date) -lt $expiresAt.AddSeconds(-60)) { return $tok.access_token }

    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($cfg.client_id):$($cfg.client_secret)"))
    try {
        $new = Invoke-RestMethod -Method Post -Uri 'https://accounts.spotify.com/api/token' `
            -Headers @{ Authorization = "Basic $basic" } -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ grant_type = 'refresh_token'; refresh_token = $tok.refresh_token }
    } catch {
        Fail "Could not refresh the Spotify login: $($_.ErrorDetails.Message)"
    }
    $saved = [ordered]@{
        access_token  = $new.access_token
        token_type    = $new.token_type
        expires_in    = $new.expires_in
        expires_at    = (Get-Date).AddSeconds([int]$new.expires_in).ToString('o')
        refresh_token = $(if ($new.refresh_token) { $new.refresh_token } else { $tok.refresh_token })
        scope         = $(if ($new.scope) { $new.scope } else { $tok.scope })
    }
    $saved | ConvertTo-Json | Set-Content -Path $TokenFile -Encoding UTF8
    $saved.access_token
}

$script:Token = $null
function Api([string]$Method, [string]$Path, $Body = $null) {
    if (-not $script:Token) { $script:Token = Get-Token }
    $params = @{
        Method = $Method; Uri = "https://api.spotify.com/v1$Path"; UseBasicParsing = $true
        Headers = @{ Authorization = "Bearer $($script:Token)" }
    }
    if ($Method -ne 'GET') {
        $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Compress -Depth 5 } else { '{}' }
        $params.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = 'application/json'
    }
    try {
        $r = Invoke-WebRequest @params
        $data = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null }
        [pscustomobject]@{ Status = [int]$r.StatusCode; Data = $data; Error = $null }
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $msg = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $_.Exception.Message }
        [pscustomobject]@{ Status = $status; Data = $null; Error = $msg }
    }
}

function Enc([string]$s) { [Uri]::EscapeDataString($s) }

# Playback commands need an active device. If none is active, wake one up (opening the
# Spotify app if necessary) and transfer playback to it.
function Ensure-Device {
    $d = (Api GET '/me/player/devices').Data.devices
    if ($d | Where-Object { $_.is_active }) { return }
    if (-not $d) {
        Start-Process 'spotify:' -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 15 -and -not $d; $i++) { Start-Sleep -Seconds 1; $d = (Api GET '/me/player/devices').Data.devices }
        if (-not $d) { Fail 'No Spotify device found. Open the Spotify app and try again.' }
    }
    $pick = ($d | Where-Object { $_.type -eq 'Computer' } | Select-Object -First 1)
    if (-not $pick) { $pick = $d | Select-Object -First 1 }
    [void](Api PUT '/me/player' @{ device_ids = @($pick.id); play = $false })
    Start-Sleep -Milliseconds 700
}

function Player([string]$Method, [string]$Path, $Body = $null) {
    $r = Api $Method $Path $Body
    if ($r.Status -eq 404) { Ensure-Device; $r = Api $Method $Path $Body }
    if ($r.Error) {
        if ($r.Status -eq 403) { Fail "Spotify refused: $($r.Error) (playback control needs Spotify Premium)." }
        Fail $r.Error
    }
    $r
}

function Find-One([string]$Type, [string]$Q) {
    if (-not $Q) { Fail "Say what to search for." }
    $r = Api GET "/search?type=$Type&limit=1&q=$(Enc $Q)"
    if ($r.Error) { Fail $r.Error }
    $item = $r.Data."${Type}s".items | Where-Object { $_ } | Select-Object -First 1
    if (-not $item) { Fail "Nothing found on Spotify for '$Q'." }
    $item
}

function Artists($item) { ($item.artists | ForEach-Object { $_.name }) -join ', ' }

switch ($Command.ToLower()) {
    'play' {
        if (-not $Query) { [void](Player PUT '/me/player/play'); 'Resumed playback.'; break }
        $t = Find-One 'track' $Query
        [void](Player PUT '/me/player/play' @{ uris = @($t.uri) })
        "Playing '$($t.name)' by $(Artists $t)."
    }
    'play-album' {
        $a = Find-One 'album' $Query
        [void](Player PUT '/me/player/play' @{ context_uri = $a.uri })
        "Playing the album '$($a.name)' by $(Artists $a)."
    }
    'play-artist' {
        $a = Find-One 'artist' $Query
        [void](Player PUT '/me/player/play' @{ context_uri = $a.uri })
        "Playing $($a.name)."
    }
    'play-playlist' {
        if (-not $Query) { Fail 'Say which playlist.' }
        $mine = (Api GET '/me/playlists?limit=50').Data.items | Where-Object { $_ }
        $p = $mine | Where-Object { $_.name -eq $Query } | Select-Object -First 1
        if (-not $p) { $p = $mine | Where-Object { $_.name -like "*$Query*" } | Select-Object -First 1 }
        if (-not $p) { $p = Find-One 'playlist' $Query }
        [void](Player PUT '/me/player/play' @{ context_uri = $p.uri })
        "Playing the playlist '$($p.name)'."
    }
    'queue' {
        $t = Find-One 'track' $Query
        [void](Player POST "/me/player/queue?uri=$(Enc $t.uri)")
        "Queued '$($t.name)' by $(Artists $t)."
    }
    'pause'    { [void](Player PUT '/me/player/pause'); 'Paused.' }
    'resume'   { [void](Player PUT '/me/player/play'); 'Resumed playback.' }
    'next'     { [void](Player POST '/me/player/next'); 'Skipped to the next track.' }
    'previous' { [void](Player POST '/me/player/previous'); 'Went back to the previous track.' }
    'volume' {
        $v = 0
        if (-not [int]::TryParse($Query, [ref]$v) -or $v -lt 0 -or $v -gt 100) { Fail 'Volume must be a number from 0 to 100.' }
        [void](Player PUT "/me/player/volume?volume_percent=$v"); "Volume set to $v%."
    }
    'shuffle' {
        $on = $Query -match '^(on|true|yes)$'
        [void](Player PUT "/me/player/shuffle?state=$($on.ToString().ToLower())"); "Shuffle $(if ($on) { 'on' } else { 'off' })."
    }
    'repeat' {
        if ($Query -notin 'off', 'track', 'context') { Fail 'Repeat must be off, track or context.' }
        [void](Player PUT "/me/player/repeat?state=$Query"); "Repeat set to $Query."
    }
    'status' {
        $r = Api GET '/me/player'
        if ($r.Error) { Fail $r.Error }
        if ($r.Status -eq 204 -or -not $r.Data -or -not $r.Data.item) { 'Nothing is playing right now.'; break }
        $s = $r.Data
        $state = if ($s.is_playing) { 'Playing' } else { 'Paused' }
        "$state '$($s.item.name)' by $(Artists $s.item) on $($s.device.name) (volume $($s.device.volume_percent)%, shuffle $(if ($s.shuffle_state) { 'on' } else { 'off' }), repeat $($s.repeat_state))."
    }
    'devices' {
        $d = (Api GET '/me/player/devices').Data.devices
        if (-not $d) { 'No Spotify devices are available. The Spotify app may be closed.'; break }
        $d | ForEach-Object { "$($_.name) ($($_.type))$(if ($_.is_active) { ' - active' })" }
    }
    'playlists' {
        $r = Api GET '/me/playlists?limit=50'
        if ($r.Error) { Fail $r.Error }
        $r.Data.items | Where-Object { $_ } | ForEach-Object { "$($_.name) ($($_.tracks.total) tracks)" }
    }
    default { Fail "Unknown command '$Command'. Use play, play-album, play-artist, play-playlist, queue, pause, resume, next, previous, volume, shuffle, repeat, status, devices or playlists." }
}
