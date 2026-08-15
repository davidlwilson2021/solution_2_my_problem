#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or removes) a scheduled task that runs the spacedesk watcher automatically at
    logon, hidden, inside your interactive session - the "set it once and forget it" layer.

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
    Registering a scheduled task requires an elevated PowerShell. If this is run without admin,
    it automatically falls back to a per-user HKCU "Run" logon entry, which needs no admin and
    runs the watcher in your interactive session at sign-in. Either way the watcher runs un-elevated.
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

$watcher = Join-Path $PSScriptRoot 'Watch-Spacedesk.ps1'
if (-not (Test-Path -LiteralPath $watcher)) {
    throw "Cannot find Watch-Spacedesk.ps1 next to this installer ($watcher)."
}

$psExe  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# Full command line, shared by both install methods.
$watcherArgs = @('-Mode', $Mode)
if ($Profile) { $watcherArgs += @('-Profile', $Profile) }
$argLine  = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
            ('-File "{0}" {1}' -f $watcher, ($watcherArgs -join ' '))
$runValue = '"{0}" {1}' -f $psExe, $argLine

if ($Uninstall) {
    $removed = @()
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
            try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; $removed += 'scheduled task' }
            catch { Write-Warning "Could not remove the scheduled task ($($_.Exception.Message.Trim())); it may need an elevated PowerShell." }
        }
    }
    if (Get-ItemProperty -Path $runKey -Name $TaskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess("$runKey\$TaskName", 'Remove logon Run entry')) {
            Remove-ItemProperty -Path $runKey -Name $TaskName -ErrorAction SilentlyContinue
            $removed += 'logon Run entry'
        }
    }
    if ($removed) { Write-Host ("Removed: {0}." -f ($removed -join ' and ')) -ForegroundColor Green }
    else { Write-Host "Nothing named '$TaskName' was installed; nothing to remove." -ForegroundColor DarkGray }
    return
}

# Install: prefer a scheduled task (sturdier); fall back to a no-admin HKCU Run entry.
$method = $null
if ($PSCmdlet.ShouldProcess($TaskName, 'Register auto-snap at logon')) {
    try {
        $action    = New-ScheduledTaskAction -Execute $psExe -Argument $argLine
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
                        -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description 'Auto-snaps the spacedesk virtual display to native resolution + Retina DPI on connect.' `
            -ErrorAction Stop | Out-Null
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { $method = 'task' }
    }
    catch {
        Write-Warning ("Scheduled-task registration needs admin here ({0}). Falling back to a no-admin logon entry." -f $_.Exception.Message.Trim())
    }

    if (-not $method) {
        # HKCU Run: no admin required, runs in your interactive session at sign-in.
        Set-ItemProperty -Path $runKey -Name $TaskName -Value $runValue
        $method = 'run'
    }
}

switch ($method) {
    'task' {
        Write-Host "Installed as a scheduled task '$TaskName' (hidden, at logon)." -ForegroundColor Green
        Write-Host "  Start it now without signing out:  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
    }
    'run' {
        Write-Host "Installed as a no-admin logon entry (HKCU Run: '$TaskName')." -ForegroundColor Green
        Write-Host "  It starts automatically at your next sign-in." -ForegroundColor DarkGray
        Write-Host "  To start it now in this window (Ctrl+C to stop):" -ForegroundColor DarkGray
        Write-Host ("    .\Watch-Spacedesk.ps1 -Mode {0}{1}" -f $Mode, $(if($Profile){" -Profile $Profile"})) -ForegroundColor DarkGray
        Write-Host "  (Want the sturdier scheduled-task version? Re-run this installer from an elevated PowerShell.)" -ForegroundColor DarkGray
    }
    default { Write-Host "No changes made (WhatIf or cancelled)." -ForegroundColor DarkGray }
}
if ($method) { Write-Host "  To remove it later:  .\Register-AutoSnap.ps1 -Uninstall" -ForegroundColor DarkGray }
