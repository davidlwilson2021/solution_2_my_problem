#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or removes) a scheduled task that runs the spacedesk watcher automatically at
    logon, hidden, inside your interactive session — the "set it once and forget it" layer.

.DESCRIPTION
    Registers a Scheduled Task that launches Watch-Spacedesk.ps1 at every logon. The settings
    are chosen deliberately:

      * -LogonType Interactive   the watcher runs in YOUR desktop session, so the DisplayConfig
                                 and DPI APIs work (an S4U/service task runs in session 0 with no
                                 desktop and the calls would fail or hit the wrong session).
      * -RunLevel Limited        no elevation: rescaling a display you own needs no admin rights,
                                 and this avoids a UAC prompt at logon.
      * MultipleInstances IgnoreNew   only one watcher ever runs (process-level double-fire guard).
      * ExecutionTimeLimit 0     never kill the long-running watcher.

    Run with -Uninstall to remove the task cleanly.

.PARAMETER TaskName
    Scheduled task name. Default 'Spacedesk Auto-Snap'.

.PARAMETER Mode
    Watcher mode to bake into the task: 'Event' (default) or 'Poll'.

.PARAMETER Profile
    Optional config.json preset name to pass to the watcher (e.g. 'lan').

.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.

.EXAMPLE
    .\Register-AutoSnap.ps1
    Install the auto-snap watcher (event mode) to start at logon.

.EXAMPLE
    .\Register-AutoSnap.ps1 -Mode Poll -Profile lan
    Install using the polling watcher and the 'lan' preset.

.EXAMPLE
    .\Register-AutoSnap.ps1 -Uninstall
    Remove the scheduled task.

.NOTES
    No administrator rights are required for a per-user logon task in your own session.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TaskName = 'Spacedesk Auto-Snap',
    [ValidateSet('Event', 'Poll')]
    [string] $Mode = 'Event',
    [string] $Profile,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
        }
    }
    else {
        Write-Host "No scheduled task named '$TaskName' found; nothing to remove." -ForegroundColor DarkGray
    }
    return
}

$watcher = Join-Path $PSScriptRoot 'Watch-Spacedesk.ps1'
if (-not (Test-Path -LiteralPath $watcher)) {
    throw "Cannot find Watch-Spacedesk.ps1 next to this installer ($watcher)."
}

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Build the watcher argument list.
$watcherArgs = @('-Mode', $Mode)
if ($Profile) { $watcherArgs += @('-Profile', $Profile) }

$argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
           ('-File "{0}" {1}' -f $watcher, ($watcherArgs -join ' '))

$action  = New-ScheduledTaskAction -Execute $psExe -Argument $argLine
$trigger = New-ScheduledTaskTrigger -AtLogOn

$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
                -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                -StartWhenAvailable

if ($PSCmdlet.ShouldProcess($TaskName, "Register logon task -> $psExe $argLine")) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description 'Auto-snaps the spacedesk virtual display to native resolution + Retina DPI on connect.' | Out-Null

    Write-Host "Installed scheduled task '$TaskName'." -ForegroundColor Green
    Write-Host "  Runs at logon (interactive, hidden): Watch-Spacedesk.ps1 -Mode $Mode$(if($Profile){" -Profile $Profile"})"
    Write-Host "  It starts on your next logon. To start it now without logging off, run:" -ForegroundColor DarkGray
    Write-Host "    Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
    Write-Host "  To remove it later:  .\Register-AutoSnap.ps1 -Uninstall" -ForegroundColor DarkGray
}
