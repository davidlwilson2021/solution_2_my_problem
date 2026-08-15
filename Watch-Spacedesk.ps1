#Requires -Version 5.1
<#
.SYNOPSIS
    Watches for the spacedesk display to connect and automatically snaps it to the correct
    resolution + DPI scale, so you never touch Windows Settings when you plug in the iPad.

.DESCRIPTION
    spacedesk is an IddCx *indirect* display driver: the "spacedesk Graphics Adapter" is
    installed once and stays present forever, while a monitor child-node arrives on every
    connect and departs on every disconnect. There is therefore no single reliable "display
    connected" event, so this watcher offers two strategies:

      * Event  (default) - a CIM indication subscription on Monitor-class PnP node creation.
                            The event is only a cheap wake-up; the watcher then verifies the
                            spacedesk display is really present before acting.
      * Poll             - a 2-second rising-edge poll (absent -> present). Immune to every
                            event-schema quirk; the robust fallback.

    Either way, the actual work is done by Invoke-SpacedeskSnap from Set-SpacedeskDisplay.ps1,
    which is idempotent and refuses to touch the primary monitor. Three independent layers stop
    double-application: the installer's single-instance guard, a debounce here, and the snap's
    own idempotency.

.PARAMETER Mode
    'Event' (default) or 'Poll'.

.PARAMETER Profile
    Preset name from config.json passed through to the snap (e.g. 'lan'). Optional.

.PARAMETER Match
    spacedesk match substring. Defaults to the config's matchString, else 'spacedesk'.

.PARAMETER PollSeconds
    Poll interval for -Mode Poll. Default 2.

.PARAMETER DebounceSeconds
    Minimum gap between two snap attempts. Default 5.

.EXAMPLE
    .\Watch-Spacedesk.ps1
    Run the event-driven watcher in the foreground (Ctrl+C to stop).

.EXAMPLE
    .\Watch-Spacedesk.ps1 -Mode Poll -Profile lan
    Run the polling watcher using the 'lan' preset.

.NOTES
    Must run in the user's interactive session (the display APIs need a real desktop).
    Register-AutoSnap.ps1 sets this up to start automatically at logon.
#>
[CmdletBinding()]
param(
    [ValidateSet('Event', 'Poll')]
    [string] $Mode = 'Event',
    [string] $Profile,
    [string] $Match,
    [int]    $PollSeconds = 2,
    [int]    $DebounceSeconds = 5
)

$ErrorActionPreference = 'Stop'
$snapScript = Join-Path $PSScriptRoot 'Set-SpacedeskDisplay.ps1'
if (-not (Test-Path -LiteralPath $snapScript)) {
    throw "Cannot find Set-SpacedeskDisplay.ps1 next to this watcher ($snapScript)."
}

# Capture our OWN parameters before dot-sourcing. The snap script's param() block runs on
# dot-source and would otherwise reset $Profile/$Match to its own defaults in this shared scope.
$wProfile = $Profile
$wMatch   = $Match

# Dot-source the snap tool to load its functions WITHOUT running a snap.
. $snapScript

# Resolve the settings once so the watcher and the snap agree on match/resolution/scale.
$settings = Resolve-SnapSettings -Width $null -Height $null -Scale $null `
                                 -Match $wMatch -Profile $wProfile `
                                 -ConfigPath (Join-Path $PSScriptRoot 'config.json')

# Single-instance guard (per interactive session): stops a manually-launched watcher and the
# auto-start entry from both running at once. The OS releases the mutex when this process exits.
$script:__singleton = New-Object System.Threading.Mutex($false, 'Local\SpacedeskAutoSnapWatcher')
if (-not $script:__singleton.WaitOne(0)) {
    Write-Host "Another spacedesk watcher is already running in this session; exiting." -ForegroundColor DarkGray
    return
}

$script:LastFire = [datetime]::MinValue

function Test-SpacedeskPresent {
    # Authoritative presence check: is a display whose name matches actually active now?
    # Get-SpacedeskTarget can throw during a live topology transition (QueryDisplayConfig may
    # transiently fail exactly when a display connects). Swallow that and report "not present"
    # so a momentary hiccup can never terminate the long-running watcher.
    try { $null -ne (Get-SpacedeskTarget -Match $settings.Match) }
    catch { $false }
}

function Invoke-SnapIfPresent {
    param([string] $Reason)
    if (((Get-Date) - $script:LastFire).TotalSeconds -lt $DebounceSeconds) { return }
    if (-not (Test-SpacedeskPresent)) { return }
    $script:LastFire = Get-Date
    Start-Sleep -Milliseconds 800   # let the topology finalise before we change it
    try {
        $r = Invoke-SpacedeskSnap -Width $settings.Width -Height $settings.Height `
                                  -Scale $settings.Scale -Match $settings.Match
        Write-Host ("[{0}] snapped via {1}: {2}x{3} @ {4}% (res={5}, dpi={6})" -f `
            (Get-Date -Format 'HH:mm:ss'), $Reason, $r.Width, $r.Height, $r.Scale, $r.Resolution, $r.Dpi)
    }
    catch {
        Write-Warning ("[{0}] snap failed: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)
    }
}

Write-Host ("spacedesk watcher started (mode={0}, match='{1}', target={2}x{3} @ {4}%)." -f `
    $Mode, $settings.Match, $settings.Width, $settings.Height, $settings.Scale) -ForegroundColor Cyan

# If the display is already connected when the watcher starts, snap it right away.
Invoke-SnapIfPresent -Reason 'startup'

if ($Mode -eq 'Event') {
    $query = "SELECT * FROM __InstanceCreationEvent WITHIN 2 " +
             "WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.PNPClass = 'Monitor'"
    $sourceId = 'SpacedeskMonitorWatcher'

    # Register WITHOUT -Action: events land in the session queue and we handle them here, in the
    # script scope, where Invoke-SnapIfPresent and $settings are guaranteed visible. (An -Action
    # scriptblock runs in a separate scope that may not see dot-sourced functions.)
    Register-CimIndicationEvent -Query $query -SourceIdentifier $sourceId | Out-Null

    try {
        Write-Host "Listening for monitor connect events. Press Ctrl+C to stop." -ForegroundColor DarkGray
        while ($true) {
            try {
                Wait-Event -SourceIdentifier $sourceId | Out-Null      # block until a monitor node appears
                # Drain the whole burst a single connect produces, then act once (debounce backs this up).
                Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
                Invoke-SnapIfPresent -Reason 'event'
            }
            catch {
                Write-Warning ("[{0}] watcher loop error (continuing): {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)
                Start-Sleep -Seconds 2
            }
        }
    }
    finally {
        Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        Write-Host "Watcher stopped." -ForegroundColor DarkGray
    }
}
else {
    Write-Host "Polling every $PollSeconds s. Press Ctrl+C to stop." -ForegroundColor DarkGray
    $seen = Test-SpacedeskPresent
    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        try {
            $present = Test-SpacedeskPresent
            if ($present -and -not $seen) { Invoke-SnapIfPresent -Reason 'poll' }  # rising edge only
            $seen = $present
        }
        catch {
            Write-Warning ("[{0}] poll error (continuing): {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)
        }
    }
}
