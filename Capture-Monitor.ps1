# Captures one specific physical monitor to a PNG file, independent of the cua-computer
# driver (which can only ever see the primary display). Any monitor, including secondary
# ones, can be captured this way since it uses plain Windows Forms/GDI+ screen enumeration.
#
# Usage:
#   .\Capture-Monitor.ps1                       # lists all monitors, capturing none
#   .\Capture-Monitor.ps1 -Index 1               # captures the monitor at index 1 (0-based)
#   .\Capture-Monitor.ps1 -Index 1 -OutFile C:\path\to\shot.png
param(
    [int]$Index = -1,
    [string]$OutFile
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$screens = [System.Windows.Forms.Screen]::AllScreens

if ($Index -lt 0) {
    $screens | ForEach-Object -Begin { $i = 0 } -Process {
        [PSCustomObject]@{
            Index       = $i
            DeviceName  = $_.DeviceName
            Primary     = $_.Primary
            Bounds      = $_.Bounds
        }
        $i++
    }
    return
}

if ($Index -ge $screens.Count) {
    throw "Monitor index $Index does not exist; only $($screens.Count) monitor(s) detected (indices 0..$($screens.Count - 1))."
}

$screen = $screens[$Index]
$bounds = $screen.Bounds

if (-not $OutFile) {
    $OutFile = Join-Path $env:TEMP "monitor-$Index-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).png"
}

$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bitmap.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()

[PSCustomObject]@{
    Index      = $Index
    DeviceName = $screen.DeviceName
    Primary    = $screen.Primary
    Bounds     = $bounds
    SavedTo    = $OutFile
}
