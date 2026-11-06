# Find and interact with UI elements by name/role instead of guessed pixel coordinates,
# using Windows' own UI Automation (UIA) tree -- independent of OpenClaw entirely.
# Works in any UIA-exposed app (native Win32/WinForms/WPF/UWP apps always expose it;
# Chromium-based browsers expose page content too, once something has queried
# accessibility at least once -- the first query in a browser session may see less
# than the second, since that query itself is what turns full accessibility on).
#
# Usage:
#   Find-UIElement.ps1 -ProcessName opera -Action List
#       Lists clickable/readable elements in the target window: Name, ControlType,
#       AutomationId, and click-center coordinates for each.
#   Find-UIElement.ps1 -ProcessName opera -Action List -Filter "Domino"
#       Same, but only elements whose Name contains this text (case-insensitive).
#   Find-UIElement.ps1 -ProcessName opera -Action Click -Name "Add to Cart"
#       Finds the element by exact/contains Name match and clicks it: tries the UIA
#       Invoke pattern first (works even if the window isn't foreground), falls back
#       to a real mouse click at the element's center via Send-Input.ps1 if the
#       control doesn't support Invoke.
#   Find-UIElement.ps1 -ProcessName opera -Action GetText -Name "Total"
#       Reads the Name/Value of a matched element without clicking it.
#
# TitleContains narrows to one window when a process has several (e.g. multiple
# browser windows); omit it to use whichever window is currently foreground for
# that process.
param(
    [Parameter(Mandatory=$true)]
    [string]$ProcessName,
    [string]$TitleContains,
    [Parameter(Mandatory=$true)]
    [ValidateSet('List','Click','GetText')]
    [string]$Action,
    [string]$Name,
    [string]$Filter,
    [int]$MaxResults = 60,
    [int]$TimeoutSeconds = 10
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

function Get-TargetWindowElement {
    $procs = @(Get-Process -Name $ProcessName -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($TitleContains) { $procs = @($procs | Where-Object { $_.MainWindowTitle -like "*$TitleContains*" }) }
    if ($procs.Count -eq 0) { throw "No visible $ProcessName window found$(if ($TitleContains) { " matching title '*$TitleContains*'" })." }
    $proc = $procs | Select-Object -First 1
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
    if (-not $element) { throw "Could not attach UI Automation to $ProcessName window (handle $($proc.MainWindowHandle))." }
    return $element
}

# Do NOT filter by ControlType up front: different UI frameworks report it wildly
# inconsistently (classic Win32 reports real Button/MenuItem types; WinUI3 apps like
# modern Notepad collapse almost everything -- including real buttons -- into generic
# "Pane"; Chromium's bridge has its own mapping). The one thing that reliably signals
# "this is a real, meaningful element" across all of them is having a non-empty Name.
function Get-CandidateElements([System.Windows.Automation.AutomationElement]$root) {
    $condition = New-Object System.Windows.Automation.NotCondition(
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, ""))
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ([DateTime]::UtcNow -gt $deadline) { Write-Warning "UI Automation search took longer than ${TimeoutSeconds}s; results may be incomplete." }
    return $found
}

function Test-ElementMatch([System.Windows.Automation.AutomationElement]$el, [string]$text) {
    if (-not $text) { return $true }
    $n = $el.Current.Name
    return ($n -and $n.ToLowerInvariant().Contains($text.ToLowerInvariant()))
}

function Get-ElementCenter([System.Windows.Automation.AutomationElement]$el) {
    $r = $el.Current.BoundingRectangle
    if ($r.IsEmpty) { return $null }
    return [pscustomobject]@{ X = [int]($r.X + $r.Width / 2); Y = [int]($r.Y + $r.Height / 2) }
}

switch ($Action) {
    'List' {
        $root = Get-TargetWindowElement
        $candidates = Get-CandidateElements -root $root
        $rows = @()
        foreach ($el in $candidates) {
            if ($rows.Count -ge $MaxResults) { break }
            if (-not (Test-ElementMatch -el $el -text $Filter)) { continue }
            $c = $el.Current
            $center = Get-ElementCenter -el $el
            $rows += [pscustomobject]@{
                Name          = $c.Name
                ControlType   = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
                AutomationId  = $c.AutomationId
                IsEnabled     = $c.IsEnabled
                ClickX        = if ($center) { $center.X } else { $null }
                ClickY        = if ($center) { $center.Y } else { $null }
            }
        }
        if ($rows.Count -eq 0) { Write-Output "No matching elements found$(if ($Filter) { " for filter '$Filter'" })." }
        else { $rows }
    }
    'Click' {
        if (-not $Name) { throw "Click requires -Name." }
        $root = Get-TargetWindowElement
        $candidates = Get-CandidateElements -root $root
        $match = $candidates | Where-Object { Test-ElementMatch -el $_ -text $Name } | Select-Object -First 1
        if (-not $match) { throw "No element found with Name containing '$Name'. Run -Action List first to see what's actually available." }
        # Capture these as plain strings before invoking/clicking: the click itself can
        # destroy the element (e.g. dismissing a banner), and reading .Current afterward
        # on a dead element silently returns blanks instead of throwing.
        $matchedName = [string]$match.Current.Name
        $matchedType = [string]$match.Current.ControlType.ProgrammaticName
        $invokePattern = $null
        if ($match.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
            $invokePattern.Invoke()
            [pscustomobject]@{ Action = 'Click'; Method = 'UIA Invoke'; Name = $matchedName; ControlType = $matchedType }
        } else {
            $center = Get-ElementCenter -el $match
            if (-not $center) { throw "Element '$matchedName' has no on-screen bounds and does not support Invoke; cannot click it." }
            & (Join-Path $PSScriptRoot 'Send-Input.ps1') -Action MouseClick -X $center.X -Y $center.Y | Out-Null
            [pscustomobject]@{ Action = 'Click'; Method = 'mouse click (no Invoke pattern)'; Name = $matchedName; ControlType = $matchedType; X = $center.X; Y = $center.Y }
        }
    }
    'GetText' {
        if (-not $Name) { throw "GetText requires -Name." }
        $root = Get-TargetWindowElement
        $candidates = Get-CandidateElements -root $root
        $match = $candidates | Where-Object { Test-ElementMatch -el $_ -text $Name } | Select-Object -First 1
        if (-not $match) { throw "No element found with Name containing '$Name'." }
        $info = $match.Current
        $valuePattern = $null
        $value = if ($match.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) { $valuePattern.Current.Value } else { $null }
        [pscustomobject]@{ Name = $info.Name; ControlType = $info.ControlType.ProgrammaticName; Value = $value }
    }
}
