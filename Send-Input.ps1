# Direct mouse/keyboard control via raw Win32 SendInput, independent of OpenClaw's
# computer tool / cua-computer plugin entirely. Works across all monitors since mouse
# moves use real screen pixel coordinates (SetCursorPos), same coordinate space as
# Capture-Monitor.ps1's monitor Bounds.
#
# Usage:
#   Send-Input.ps1 -Action MouseMove -X 2800 -Y 400
#   Send-Input.ps1 -Action MouseClick -X 2800 -Y 400                    # move + left click
#   Send-Input.ps1 -Action MouseClick -X 2800 -Y 400 -Button Right
#   Send-Input.ps1 -Action MouseClick -X 2800 -Y 400 -Clicks 2          # double-click
#   Send-Input.ps1 -Action MouseClick                                   # click at current position, no move
#   Send-Input.ps1 -Action MouseScroll -ScrollAmount -3                 # scroll down 3 notches (positive = up)
#   Send-Input.ps1 -Action KeyType -Text "hello world"                  # types literal Unicode text
#   Send-Input.ps1 -Action KeyCombo -Keys "CTRL+A"
#   Send-Input.ps1 -Action KeyCombo -Keys "ALT+F4"
#   Send-Input.ps1 -Action KeyCombo -Keys "ENTER"                       # single key also works here
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('MouseMove','MouseClick','MouseScroll','KeyType','KeyCombo')]
    [string]$Action,
    [int]$X = -1,
    [int]$Y = -1,
    [ValidateSet('Left','Right','Middle')]
    [string]$Button = 'Left',
    [int]$Clicks = 1,
    [int]$ScrollAmount = 0,
    [string]$Text,
    [string]$Keys
)
$ErrorActionPreference = 'Stop'

if (-not ('GladosInput' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct INPUT { public uint type; public InputUnion U; }
[StructLayout(LayoutKind.Explicit)]
public struct InputUnion {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
}
[StructLayout(LayoutKind.Sequential)]
public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
public static class GladosInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
}
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
"@
}

# PowerShell does not reliably persist assignments made through a multi-level chained
# property path on value types (e.g. `$input.U.ki.wScan = x` silently no-ops on the real
# struct). Every nested struct below is fully built in its own variable first, then
# assigned upward in single, one-level assignments only.
$inputSize = [Runtime.InteropServices.Marshal]::SizeOf([type][INPUT])
# The first SendInput call in a freshly started process can race with JIT/DLL-load
# overhead and silently drop the very first keystroke. A zero-count warm-up call
# forces that one-time cost to happen before any real input is sent.
[void][GladosInput]::SendInput(0, @(), $inputSize)
Start-Sleep -Milliseconds 60

function New-MouseInput([uint32]$flags, [uint32]$mouseData = 0) {
    $mi = New-Object MOUSEINPUT
    $mi.dwFlags = $flags
    $mi.mouseData = $mouseData
    $u = New-Object InputUnion
    $u.mi = $mi
    $inp = New-Object INPUT
    $inp.type = [GladosInput]::INPUT_MOUSE
    $inp.U = $u
    return $inp
}

function New-KeybdInput([uint16]$vk, [uint16]$scan, [uint32]$flags) {
    $ki = New-Object KEYBDINPUT
    $ki.wVk = $vk
    $ki.wScan = $scan
    $ki.dwFlags = $flags
    $u = New-Object InputUnion
    $u.ki = $ki
    $inp = New-Object INPUT
    $inp.type = [GladosInput]::INPUT_KEYBOARD
    $inp.U = $u
    return $inp
}

function Send-MouseButton([string]$btn, [bool]$down) {
    $flag = switch ($btn) {
        'Left'   { if ($down) { [GladosInput]::MOUSEEVENTF_LEFTDOWN }   else { [GladosInput]::MOUSEEVENTF_LEFTUP } }
        'Right'  { if ($down) { [GladosInput]::MOUSEEVENTF_RIGHTDOWN }  else { [GladosInput]::MOUSEEVENTF_RIGHTUP } }
        'Middle' { if ($down) { [GladosInput]::MOUSEEVENTF_MIDDLEDOWN } else { [GladosInput]::MOUSEEVENTF_MIDDLEUP } }
    }
    $inp = New-MouseInput -flags $flag
    $sent = [GladosInput]::SendInput(1, @($inp), $inputSize)
    if ($sent -ne 1) { throw "SendInput (mouse button) failed, last error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
}

function Send-KeyEvent([uint16]$vk, [bool]$down) {
    $flags = if ($down) { 0 } else { [GladosInput]::KEYEVENTF_KEYUP }
    $inp = New-KeybdInput -vk $vk -scan 0 -flags $flags
    $sent = [GladosInput]::SendInput(1, @($inp), $inputSize)
    if ($sent -ne 1) { throw "SendInput (key event) failed, last error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
}

function Send-UnicodeChar([char]$c) {
    foreach ($down in @($true, $false)) {
        $flags = [GladosInput]::KEYEVENTF_UNICODE -bor $(if ($down) { 0 } else { [GladosInput]::KEYEVENTF_KEYUP })
        $inp = New-KeybdInput -vk 0 -scan ([uint16][int]$c) -flags $flags
        $sent = [GladosInput]::SendInput(1, @($inp), $inputSize)
        if ($sent -ne 1) { throw "SendInput (unicode char) failed, last error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    }
}

$vkMap = @{
    'CTRL'=0x11; 'CONTROL'=0x11; 'ALT'=0x12; 'SHIFT'=0x10; 'WIN'=0x5B; 'WINDOWS'=0x5B
    'ENTER'=0x0D; 'RETURN'=0x0D; 'TAB'=0x09; 'ESC'=0x1B; 'ESCAPE'=0x1B; 'SPACE'=0x20
    'BACKSPACE'=0x08; 'DELETE'=0x2E; 'DEL'=0x2E; 'HOME'=0x24; 'END'=0x23
    'PAGEUP'=0x21; 'PAGEDOWN'=0x22; 'UP'=0x26; 'DOWN'=0x28; 'LEFT'=0x25; 'RIGHT'=0x27
    'F1'=0x70;'F2'=0x71;'F3'=0x72;'F4'=0x73;'F5'=0x74;'F6'=0x75;'F7'=0x76;'F8'=0x77;'F9'=0x78;'F10'=0x79;'F11'=0x7A;'F12'=0x7B
}
function Resolve-VkCode([string]$key) {
    $k = $key.Trim().ToUpperInvariant()
    if ($vkMap.ContainsKey($k)) { return $vkMap[$k] }
    if ($k.Length -eq 1) { return [int][char]$k }
    throw "Unrecognized key name: '$key'"
}

switch ($Action) {
    'MouseMove' {
        if ($X -lt 0 -or $Y -lt 0) { throw "MouseMove requires -X and -Y." }
        [GladosInput]::SetCursorPos($X, $Y) | Out-Null
        [pscustomobject]@{ Action = 'MouseMove'; X = $X; Y = $Y }
    }
    'MouseClick' {
        if ($X -ge 0 -and $Y -ge 0) { [GladosInput]::SetCursorPos($X, $Y) | Out-Null; Start-Sleep -Milliseconds 30 }
        for ($i = 0; $i -lt $Clicks; $i++) {
            Send-MouseButton -btn $Button -down $true
            Start-Sleep -Milliseconds 30
            Send-MouseButton -btn $Button -down $false
            if ($i -lt $Clicks - 1) { Start-Sleep -Milliseconds 80 }
        }
        $pos = New-Object POINT
        [void][GladosInput]::GetCursorPos([ref]$pos)
        [pscustomobject]@{ Action = 'MouseClick'; Button = $Button; Clicks = $Clicks; X = $pos.X; Y = $pos.Y }
    }
    'MouseScroll' {
        $inp = New-MouseInput -flags ([GladosInput]::MOUSEEVENTF_WHEEL) -mouseData ([uint32]([int]$ScrollAmount * 120))
        $sent = [GladosInput]::SendInput(1, @($inp), $inputSize)
        if ($sent -ne 1) { throw "SendInput (scroll) failed, last error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        [pscustomobject]@{ Action = 'MouseScroll'; ScrollAmount = $ScrollAmount }
    }
    'KeyType' {
        if (-not $Text) { throw "KeyType requires -Text." }
        foreach ($c in $Text.ToCharArray()) { Send-UnicodeChar -c $c; Start-Sleep -Milliseconds 8 }
        [pscustomobject]@{ Action = 'KeyType'; Length = $Text.Length }
    }
    'KeyCombo' {
        if (-not $Keys) { throw "KeyCombo requires -Keys, e.g. 'CTRL+A' or 'ENTER'." }
        $parts = $Keys -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $vks = $parts | ForEach-Object { Resolve-VkCode $_ }
        foreach ($vk in $vks) { Send-KeyEvent -vk $vk -down $true; Start-Sleep -Milliseconds 15 }
        [array]::Reverse($vks)
        foreach ($vk in $vks) { Send-KeyEvent -vk $vk -down $false; Start-Sleep -Milliseconds 15 }
        [pscustomobject]@{ Action = 'KeyCombo'; Keys = $Keys }
    }
}
