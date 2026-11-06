param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ProcessName,
    [string]$TitlePattern,
    [switch]$Capture
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('GladosWindowActivation' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public struct GladosRect { public int Left, Top, Right, Bottom; }
public static class GladosWindowActivation {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out GladosRect rect);
}
"@
}
function Get-GladosMonitorIndex([IntPtr]$Handle) {
    $rect = New-Object GladosRect
    if (-not [GladosWindowActivation]::GetWindowRect($Handle, [ref]$rect)) { return $null }
    $cx = [int](($rect.Left + $rect.Right) / 2)
    $cy = [int](($rect.Top + $rect.Bottom) / 2)
    $screens = [System.Windows.Forms.Screen]::AllScreens
    for ($i = 0; $i -lt $screens.Count; $i++) {
        $b = $screens[$i].Bounds
        if ($cx -ge $b.Left -and $cx -lt $b.Right -and $cy -ge $b.Top -and $cy -lt $b.Bottom) {
            return [pscustomobject]@{ Index = $i; DeviceName = $screens[$i].DeviceName; Primary = $screens[$i].Primary }
        }
    }
    return $null
}
$currentSession = (Get-Process -Id $PID).SessionId
$targets = @(Get-Process -Name $ProcessName -ErrorAction Stop | Where-Object {
    $_.SessionId -eq $currentSession -and $_.MainWindowHandle.ToInt64() -ne 0 -and
    (-not $TitlePattern -or $_.MainWindowTitle -like "*$TitlePattern*")
})
if ($targets.Count -eq 0) { throw "No visible $ProcessName window was found in the current interactive session." }
$target = $targets | Select-Object -First 1
$handle = [IntPtr]$target.MainWindowHandle
$currentThread = [GladosWindowActivation]::GetCurrentThreadId()
# Windows' foreground-lock restriction gates on the CALLING thread being attached to the
# CURRENTLY foreground thread's input queue -- attaching to the target window's own thread
# (a common mistake) does not satisfy it. Attach to whichever thread currently owns the
# foreground window, then SetForegroundWindow succeeds for any window, then detach.
$foregroundBefore = [GladosWindowActivation]::GetForegroundWindow()
[uint32]$foregroundThread = 0
[void][GladosWindowActivation]::GetWindowThreadProcessId($foregroundBefore, [ref]$foregroundThread)
$attached = $false
if ($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread) {
    $attached = [GladosWindowActivation]::AttachThreadInput($currentThread, $foregroundThread, $true)
}
# A harmless Alt tap satisfies Windows' "the calling thread generated the last input event"
# condition for SetForegroundWindow, on top of the thread-attach trick above.
[GladosWindowActivation]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[GladosWindowActivation]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
$restored = [GladosWindowActivation]::ShowWindowAsync($handle, 9)
[void][GladosWindowActivation]::BringWindowToTop($handle)
$requested = [GladosWindowActivation]::SetForegroundWindow($handle)
if ($attached) { [void][GladosWindowActivation]::AttachThreadInput($currentThread, $foregroundThread, $false) }
Start-Sleep -Milliseconds 300
$foreground = [GladosWindowActivation]::GetForegroundWindow()
[uint32]$foregroundPid = 0
[void][GladosWindowActivation]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
$foregroundProcess = Get-Process -Id $foregroundPid -ErrorAction SilentlyContinue
$monitor = Get-GladosMonitorIndex -Handle $handle
$screenshotPath = $null
if ($Capture -and $monitor) {
    # Capture the correct monitor immediately, in this same process, right after confirming
    # focus -- a separate later exec call (even moments later) leaves a real gap where another
    # window, or this one closing/renavigating, can change what's actually on screen by the
    # time a second script runs. Do not split focus-then-capture across two exec calls.
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $bounds = $screens[$monitor.Index].Bounds
    $screenshotPath = Join-Path $env:TEMP "focuswin-$($target.ProcessName)-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).png"
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($screenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}
$result = [pscustomobject]@{
    TargetProcess = $target.ProcessName
    TargetPid = $target.Id
    TargetWindow = $target.MainWindowTitle
    RestoreRequested = $restored
    ForegroundRequested = $requested
    ForegroundProcess = $foregroundProcess.ProcessName
    ForegroundWindow = $foregroundProcess.MainWindowTitle
    Focused = ($foregroundPid -eq $target.Id)
    MonitorIndex = if ($monitor) { $monitor.Index } else { $null }
    MonitorIsPrimary = if ($monitor) { $monitor.Primary } else { $null }
    ScreenshotPath = $screenshotPath
}
$result
if ($monitor -and -not $monitor.Primary -and -not $Capture) {
    Write-Output "Note: this window is on non-primary monitor index $($monitor.Index). The `computer`/screen.snapshot tool only captures the primary display -- use Capture-Monitor.ps1 -Index $($monitor.Index) to actually see it, not the primary-display screenshot tool. Or rerun this script with -Capture to get the screenshot in the same step."
}
if (-not $result.Focused) { exit 2 }