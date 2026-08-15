#Requires -Version 5.1
<#
.SYNOPSIS
    Snaps the spacedesk virtual display to a sharp, readable configuration in one shot -
    native (pixel-perfect) resolution plus a per-monitor DPI scale - without ever touching
    your primary monitor and without opening Windows Settings.

.DESCRIPTION
    When an iPad (or any tablet) connects as a second display through the free spacedesk app,
    Windows brings the virtual display up at whatever mode it feels like. Two things then go
    wrong at once:

      * If the transmitted resolution is not an exact fit for the tablet's panel, the tablet
        has to resample every frame -> soft, blurry text that no compression setting can fix.
      * If you try to fix "everything is tiny" by lowering the resolution, you re-introduce
        the blur. Size and sharpness are governed by TWO different knobs:
            - resolution  -> sharpness (must match the panel exactly, or an integer fraction)
            - DPI scaling -> readability (independent of resolution)

    This script sets both correctly for ONLY the spacedesk display:
      1. sets the display's resolution (default 2752x2064, native for an iPad Pro 13" M4), and
      2. applies a per-monitor DPI scale (default 250%) using the same DisplayConfig API that
         the Windows "Scale" slider uses.

    It is idempotent (re-running does nothing if already correct) and it refuses to operate on
    the primary display, so it is safe to run on every connect.

.PARAMETER Width
    Target horizontal resolution in pixels. Default 2752.

.PARAMETER Height
    Target vertical resolution in pixels. Default 2064.

.PARAMETER Scale
    Target per-monitor DPI scale as a percentage. Must be one of the Windows scale steps:
    100,125,150,175,200,225,250,300,350,400,450,500. Default 250.

.PARAMETER Match
    Case-insensitive substring used to recognise the spacedesk display by its monitor
    friendly name (and, as a fallback, its GDI adapter name). Default 'spacedesk'.

.PARAMETER Profile
    Name of a preset in config.json (e.g. 'lan' or 'usb'). Values from the preset are used
    unless individually overridden by -Width/-Height/-Scale on the command line. If omitted,
    the config's "defaultProfile" is applied.

.PARAMETER ConfigPath
    Path to a JSON config file holding presets. Defaults to config.json next to this script.

.PARAMETER List
    Don't change anything - just list every active display with its GDI name, monitor friendly
    name, adapter string, primary flag and resolution, marking which one matches. Use this to
    confirm the spacedesk display is present and to discover the right -Match string.

.PARAMETER PassThru
    Emit an object describing what was found and changed, instead of only writing host text.

.EXAMPLE
    .\Set-SpacedeskDisplay.ps1
    Snap to the default 2752x2064 @ 250% (native + Retina scale for LAN use).

.EXAMPLE
    .\Set-SpacedeskDisplay.ps1 -Profile usb
    Use the 'usb' preset from config.json (half resolution, matched DPI, same logical desktop).

.EXAMPLE
    .\Set-SpacedeskDisplay.ps1 -Width 1376 -Height 1032 -Scale 125 -WhatIf
    Preview a manual configuration without applying it.

.NOTES
    Runs in the user's own interactive session (the DisplayConfig / DPI APIs need a real desktop).
    The per-monitor DPI mechanism is undocumented but stable; see docs/how-it-works.md.
    Dot-source this file to load its functions without running the snap:  . .\Set-SpacedeskDisplay.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [int]    $Width,
    [int]    $Height,
    [int]    $Scale,
    [string] $Match,
    [string] $Profile,
    [string] $ConfigPath,   # resolved at runtime; a Join-Path default here crashes on dot-source ($PSScriptRoot is empty then)
    [switch] $List,
    [switch] $PassThru
)

# ---------------------------------------------------------------------------
#  Native interop (Win32 DisplayConfig + legacy display-mode APIs)
#  DPI struct layouts and the -3/-4 device-info types are verified against
#  https://github.com/lihas/windows-DPI-scaling-sample
# ---------------------------------------------------------------------------
if (-not ('SpacedeskNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SpacedeskNative
{
    // ---- Constants ----
    public const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    public const int  ERROR_SUCCESS = 0;

    // DISPLAYCONFIG_DEVICE_INFO_TYPE values
    public const int GET_SOURCE_NAME = 1;   // documented
    public const int GET_TARGET_NAME = 2;   // documented
    public const int GET_DPI_SCALE   = -3;  // undocumented
    public const int SET_DPI_SCALE   = -4;  // undocumented

    // ChangeDisplaySettingsEx
    public const int  ENUM_CURRENT_SETTINGS = -1;
    public const uint CDS_UPDATEREGISTRY    = 0x00000001;
    public const uint DM_PELSWIDTH          = 0x00080000;
    public const uint DM_PELSHEIGHT         = 0x00100000;
    public const int  DISP_CHANGE_SUCCESSFUL = 0;

    // DISPLAY_DEVICE.StateFlags
    public const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001;
    public const int DISPLAY_DEVICE_PRIMARY_DEVICE      = 0x00000004;

    public static readonly int[] DpiVals =
        { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

    // ---- Core structs ----
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER
    {
        public int  type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_GET
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public int minScaleRel;
        public int curScaleRel;
        public int maxScaleRel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_SET
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public int scaleRel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO
    { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        public uint outputTechnology; public uint rotation; public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate; public uint scanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO
    {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    // 64-byte mode blob; we never read its contents, only pass the array through.
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO
    {
        public uint infoType; public uint id; public LUID adapterId;
        public ulong u0; public ulong u1; public ulong u2;
        public ulong u3; public ulong u4; public ulong u5;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint   dmFields;
        public int    dmPositionX;
        public int    dmPositionY;
        public uint   dmDisplayOrientation;
        public uint   dmDisplayFixedOutput;
        public short  dmColor;
        public short  dmDuplex;
        public short  dmYResolution;
        public short  dmTTOption;
        public short  dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint   dmBitsPerPel;
        public uint   dmPelsWidth;
        public uint   dmPelsHeight;
        public uint   dmDisplayFlags;
        public uint   dmDisplayFrequency;
        public uint   dmICMMethod;
        public uint   dmICMIntent;
        public uint   dmMediaType;
        public uint   dmDitherType;
        public uint   dmReserved1;
        public uint   dmReserved2;
        public uint   dmPanningWidth;
        public uint   dmPanningHeight;
    }

    // ---- DllImports ----
    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(
        uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(
        uint flags,
        ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
        ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
        IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_GET packet);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_SET packet);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME packet);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME packet);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevicesW(
        string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int EnumDisplaySettingsW(
        string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsExW(
        string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);
}
'@
}

# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------
$script:DpiVals = 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500

function Get-SpacedeskControllerRes {
    <#
        Resolutions (as "WxH" strings) of any video controller whose name matches $Match.
        WMI reliably reports "spacedesk Graphics Adapter" and its live resolution, which is the
        most dependable way to recognise the spacedesk display when its monitor has no EDID name.
    #>
    param([string] $Match = 'spacedesk')
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match [regex]::Escape($Match) -and $_.CurrentHorizontalResolution } |
        ForEach-Object { '{0}x{1}' -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution }
}

function Get-SpacedeskTarget {
    <#
        Locate the spacedesk display among the active displays. The primary (the display at
        position 0,0) is NEVER returned. Among the non-primary displays, pick the spacedesk one
        by, in priority order:
          1. monitor friendly name matches $Match,
          2. resolution equals a "spacedesk" video controller's resolution (reliable when the
             monitor has no EDID friendly name), then
          3. it is an indirect display (spacedesk is an IddCx indirect driver).
        Returns { GdiName, FriendlyName, AdapterId, SourceId } or $null.
    #>
    [CmdletBinding()]
    param([string] $Match = 'spacedesk')

    $controllerRes = @(Get-SpacedeskControllerRes -Match $Match)
    $candidates    = @(Get-ActiveDisplay | Where-Object { -not $_.IsPrimary })

    $pick =
        ($candidates | Where-Object { $_.FriendlyName -and $_.FriendlyName -match [regex]::Escape($Match) } | Select-Object -First 1)
    $reason = 'friendly-name'
    if (-not $pick) {
        $pick = $candidates | Where-Object { $_.Width -and ($controllerRes -contains ('{0}x{1}' -f $_.Width, $_.Height)) } | Select-Object -First 1
        $reason = 'controller-resolution'
    }
    if (-not $pick) {
        $pick = $candidates | Where-Object { $_.IsIndirect } | Select-Object -First 1
        $reason = 'indirect-display'
    }
    if (-not $pick) { return $null }

    Write-Verbose "Matched spacedesk display $($pick.GdiName) via $reason."
    [pscustomobject]@{
        GdiName      = $pick.GdiName
        FriendlyName = $pick.FriendlyName
        AdapterId    = $pick.AdapterId
        SourceId     = $pick.SourceId
    }
}

function Get-ActiveDisplay {
    <#
        Enumerate ALL active displays with GDI name, monitor friendly name, current resolution,
        primary flag (the primary is the display positioned at 0,0), whether it is an indirect
        display (spacedesk reports an INDIRECT output technology), and the (adapterId, sourceId)
        needed for the DPI packet. Read-only. Does not depend on EnumDisplayDevices.
    #>
    [uint32] $numPaths = 0
    [uint32] $numModes = 0
    if ([SpacedeskNative]::GetDisplayConfigBufferSizes(
            [SpacedeskNative]::QDC_ONLY_ACTIVE_PATHS, [ref]$numPaths, [ref]$numModes) -ne 0) {
        throw "GetDisplayConfigBufferSizes failed."
    }
    $paths = New-Object 'SpacedeskNative+DISPLAYCONFIG_PATH_INFO[]' $numPaths
    $modes = New-Object 'SpacedeskNative+DISPLAYCONFIG_MODE_INFO[]' $numModes
    if ([SpacedeskNative]::QueryDisplayConfig(
            [SpacedeskNative]::QDC_ONLY_ACTIVE_PATHS,
            [ref]$numPaths, $paths, [ref]$numModes, $modes, [IntPtr]::Zero) -ne 0) {
        throw "QueryDisplayConfig failed."
    }

    # DISPLAYCONFIG_OUTPUT_TECHNOLOGY indirect-display values (spacedesk reports INDIRECT_WIRED).
    $INDIRECT_WIRED   = 16L   # 0x10  DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_WIRED
    $INDIRECT_VIRTUAL = 17L   # 0x11  DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_VIRTUAL

    for ($p = 0; $p -lt $numPaths; $p++) {
        $path = $paths[$p]

        $src = New-Object SpacedeskNative+DISPLAYCONFIG_SOURCE_DEVICE_NAME
        $h = $src.header
        $h.type = [SpacedeskNative]::GET_SOURCE_NAME
        $h.size = [System.Runtime.InteropServices.Marshal]::SizeOf($src)
        $h.adapterId = $path.sourceInfo.adapterId
        $h.id = $path.sourceInfo.id
        $src.header = $h
        if ([SpacedeskNative]::DisplayConfigGetDeviceInfo([ref]$src) -ne 0) { continue }
        $gdiName = $src.viewGdiDeviceName

        $tgt = New-Object SpacedeskNative+DISPLAYCONFIG_TARGET_DEVICE_NAME
        $h = $tgt.header
        $h.type = [SpacedeskNative]::GET_TARGET_NAME
        $h.size = [System.Runtime.InteropServices.Marshal]::SizeOf($tgt)
        $h.adapterId = $path.targetInfo.adapterId
        $h.id = $path.targetInfo.id
        $tgt.header = $h
        $friendly = ''
        if ([SpacedeskNative]::DisplayConfigGetDeviceInfo([ref]$tgt) -eq 0) {
            $friendly = $tgt.monitorFriendlyDeviceName
        }

        # Normalise to the low 32 bits: the field can surface as a negative Int32 for values
        # whose high bit is set (indirect/internal technologies).
        $tech = ([int64]$path.targetInfo.outputTechnology) -band 0xFFFFFFFFL
        $mode = Get-DisplayResolution -GdiName $gdiName

        [pscustomobject]@{
            GdiName      = $gdiName
            FriendlyName = $friendly
            Width        = if ($mode) { $mode.Width }  else { $null }
            Height       = if ($mode) { $mode.Height } else { $null }
            IsPrimary    = if ($mode) { ($mode.PositionX -eq 0 -and $mode.PositionY -eq 0) } else { $false }
            IsIndirect   = ($tech -eq $INDIRECT_WIRED -or $tech -eq $INDIRECT_VIRTUAL)
            OutputTech   = ('0x{0:X8}' -f $tech)
            AdapterId    = $path.sourceInfo.adapterId
            SourceId     = $path.sourceInfo.id
        }
    }
}

function Get-DisplayResolution {
    param([Parameter(Mandatory)][string] $GdiName)
    $dm = New-Object SpacedeskNative+DEVMODE
    $dm.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf($dm)
    if ([SpacedeskNative]::EnumDisplaySettingsW($GdiName, [SpacedeskNative]::ENUM_CURRENT_SETTINGS, [ref]$dm) -eq 0) {
        return $null
    }
    [pscustomobject]@{
        Width     = [int]$dm.dmPelsWidth
        Height    = [int]$dm.dmPelsHeight
        PositionX = [int]$dm.dmPositionX
        PositionY = [int]$dm.dmPositionY
    }
}

function Set-DisplayResolution {
    <# Returns: 'AlreadySet' | 'Changed' | throws on failure. #>
    param(
        [Parameter(Mandatory)][string] $GdiName,
        [Parameter(Mandatory)][int]    $Width,
        [Parameter(Mandatory)][int]    $Height
    )
    $dm = New-Object SpacedeskNative+DEVMODE
    $dm.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf($dm)
    if ([SpacedeskNative]::EnumDisplaySettingsW($GdiName, [SpacedeskNative]::ENUM_CURRENT_SETTINGS, [ref]$dm) -eq 0) {
        throw "Could not read current settings for $GdiName."
    }
    if ($dm.dmPelsWidth -eq $Width -and $dm.dmPelsHeight -eq $Height) { return 'AlreadySet' }

    $dm.dmPelsWidth  = [uint32]$Width
    $dm.dmPelsHeight = [uint32]$Height
    $dm.dmFields     = [SpacedeskNative]::DM_PELSWIDTH -bor [SpacedeskNative]::DM_PELSHEIGHT

    $rc = [SpacedeskNative]::ChangeDisplaySettingsExW(
        $GdiName, [ref]$dm, [IntPtr]::Zero, [SpacedeskNative]::CDS_UPDATEREGISTRY, [IntPtr]::Zero)
    if ($rc -ne [SpacedeskNative]::DISP_CHANGE_SUCCESSFUL) {
        throw "ChangeDisplaySettingsEx failed for $GdiName at ${Width}x${Height} (code $rc)."
    }
    return 'Changed'
}

function Get-DisplayDpi {
    <# Returns min/cur/max absolute percentages + the raw relative values. #>
    param(
        [Parameter(Mandatory)] $AdapterId,
        [Parameter(Mandatory)][uint32] $SourceId
    )
    $get = New-Object SpacedeskNative+DISPLAYCONFIG_SOURCE_DPI_SCALE_GET
    $h = $get.header
    $h.type      = [SpacedeskNative]::GET_DPI_SCALE
    $h.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($get)
    $h.adapterId = $AdapterId
    $h.id        = $SourceId
    $get.header  = $h
    if ([SpacedeskNative]::DisplayConfigGetDeviceInfo([ref]$get) -ne 0) {
        throw "DisplayConfigGetDeviceInfo(GET_DPI) failed for source $SourceId."
    }

    $idxRecommended = [math]::Abs($get.minScaleRel)   # recommended step's index in DpiVals
    $cur = $get.curScaleRel
    if ($cur -lt $get.minScaleRel) { $cur = $get.minScaleRel }
    elseif ($cur -gt $get.maxScaleRel) { $cur = $get.maxScaleRel }

    # Clamp every lookup into the 12-value table so a device reporting a wider range than the
    # standard Windows ladder can never yield an out-of-range ($null) percentage - which would
    # silently break the AlreadySet idempotency check.
    $last = $script:DpiVals.Count - 1
    $iRec = [math]::Min([math]::Max($idxRecommended, 0), $last)
    $iCur = [math]::Min([math]::Max($idxRecommended + $cur, 0), $last)
    $iMax = [math]::Min([math]::Max($idxRecommended + $get.maxScaleRel, 0), $last)

    [pscustomobject]@{
        Recommended    = $script:DpiVals[$iRec]
        Current        = $script:DpiVals[$iCur]
        Maximum        = $script:DpiVals[$iMax]
        IdxRecommended = $idxRecommended
        MinScaleRel    = $get.minScaleRel
        MaxScaleRel    = $get.maxScaleRel
    }
}

function Set-DisplayDpi {
    <# Returns: 'AlreadySet' | 'Changed' | 'Clamped' ; throws on failure. #>
    param(
        [Parameter(Mandatory)] $AdapterId,
        [Parameter(Mandatory)][uint32] $SourceId,
        [Parameter(Mandatory)][int]    $Scale
    )
    $idxTarget = [array]::IndexOf($script:DpiVals, $Scale)
    if ($idxTarget -lt 0) {
        throw "Scale $Scale% is not a valid Windows scale step. Valid: $($script:DpiVals -join ', ')."
    }

    $info = Get-DisplayDpi -AdapterId $AdapterId -SourceId $SourceId
    if ($info.Current -eq $Scale) { return 'AlreadySet' }

    $scaleRel = $idxTarget - $info.IdxRecommended
    $result   = 'Changed'
    if ($scaleRel -lt $info.MinScaleRel) { $scaleRel = $info.MinScaleRel; $result = 'Clamped' }
    elseif ($scaleRel -gt $info.MaxScaleRel) { $scaleRel = $info.MaxScaleRel; $result = 'Clamped' }

    $set = New-Object SpacedeskNative+DISPLAYCONFIG_SOURCE_DPI_SCALE_SET
    $h = $set.header
    $h.type      = [SpacedeskNative]::SET_DPI_SCALE
    $h.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($set)
    $h.adapterId = $AdapterId
    $h.id        = $SourceId
    $set.header  = $h
    $set.scaleRel = $scaleRel
    if ([SpacedeskNative]::DisplayConfigSetDeviceInfo([ref]$set) -ne 0) {
        throw "DisplayConfigSetDeviceInfo(SET_DPI) failed for source $SourceId."
    }
    return $result
}

function Resolve-SnapSettings {
    <# Merge order: built-in defaults <- config (matchString + profile) <- explicit parameters.
       The config is always consulted when present: matchString is honored unconditionally, and
       when no -Profile is given the config's defaultProfile is applied. #>
    param($Width, $Height, $Scale, $Match, $Profile, $ConfigPath)

    $settings = @{ Width = 2752; Height = 2064; Scale = 250; Match = 'spacedesk' }

    $cfg = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        # Force UTF-8: Windows PowerShell 5.1 would otherwise read a no-BOM file as ANSI.
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    elseif ($Profile) {
        throw "Profile '$Profile' requested but config file not found: $ConfigPath"
    }

    if ($cfg) {
        # matchString applies whether or not a profile is selected.
        if ($cfg.matchString) { $settings.Match = $cfg.matchString }

        # Explicit -Profile wins; otherwise fall back to the config's defaultProfile.
        $useProfile = if ($Profile) { $Profile } elseif ($cfg.defaultProfile) { $cfg.defaultProfile } else { $null }
        if ($useProfile) {
            $preset = $cfg.profiles.$useProfile
            if (-not $preset) {
                $available = ($cfg.profiles.PSObject.Properties.Name) -join ', '
                throw "Profile '$useProfile' not found in $ConfigPath. Available: $available"
            }
            $settings.Width  = [int]$preset.width
            $settings.Height = [int]$preset.height
            $settings.Scale  = [int]$preset.scale
        }
    }

    # Explicit command-line values always win over config and defaults.
    if ($Width)  { $settings.Width  = $Width }
    if ($Height) { $settings.Height = $Height }
    if ($Scale)  { $settings.Scale  = $Scale }
    if ($Match)  { $settings.Match  = $Match }

    [pscustomobject]$settings
}

function Invoke-SpacedeskSnap {
    <#
        Orchestrator: find the spacedesk display, set its resolution, then its DPI scale.
        Idempotent and safe to call repeatedly. Honors -WhatIf / -Confirm via the caller.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$Width = 2752, [int]$Height = 2064, [int]$Scale = 250, [string]$Match = 'spacedesk'
    )

    $target = Get-SpacedeskTarget -Match $Match
    if (-not $target) {
        Write-Warning "No spacedesk display found (looking for '$Match'). Is the iPad connected?"
        return $null
    }

    $label = if ($target.FriendlyName) { "$($target.FriendlyName) [$($target.GdiName)]" } else { $target.GdiName }
    Write-Host "Found spacedesk display: $label" -ForegroundColor Cyan

    $resResult = 'Skipped'; $dpiResult = 'Skipped'

    if ($PSCmdlet.ShouldProcess($label, "Set resolution to ${Width}x${Height}")) {
        $resResult = Set-DisplayResolution -GdiName $target.GdiName -Width $Width -Height $Height
        Write-Host ("  Resolution -> {0}x{1}  [{2}]" -f $Width, $Height, $resResult) -ForegroundColor Green
        if ($resResult -eq 'Changed') { Start-Sleep -Milliseconds 600 }  # let the mode settle before DPI
    }

    # Re-resolve after a resolution change: the recommended DPI depends on the new mode.
    $target2 = Get-SpacedeskTarget -Match $Match
    if (-not $target2) { $target2 = $target }

    if ($PSCmdlet.ShouldProcess($label, "Set DPI scale to $Scale%")) {
        $dpiResult = Set-DisplayDpi -AdapterId $target2.AdapterId -SourceId $target2.SourceId -Scale $Scale
        Write-Host ("  DPI scale             -> {0}%  [{1}]" -f $Scale, $dpiResult) -ForegroundColor Green
        if ($dpiResult -eq 'Clamped') {
            $info = Get-DisplayDpi -AdapterId $target2.AdapterId -SourceId $target2.SourceId
            Write-Warning "  $Scale% is outside this display's range ($($info.Recommended)%..$($info.Maximum)%); applied the nearest allowed."
        }
    }

    [pscustomobject]@{
        Display    = $label
        Width      = $Width
        Height     = $Height
        Scale      = $Scale
        Resolution = $resResult
        Dpi        = $dpiResult
    }
}

# ---------------------------------------------------------------------------
#  Entry point (skipped when the file is dot-sourced)
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ConfigPath) {
        $base = if ($PSScriptRoot) { $PSScriptRoot }
                elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
                else { (Get-Location).Path }
        $ConfigPath = Join-Path $base 'config.json'
    }

    $s = Resolve-SnapSettings -Width $Width -Height $Height -Scale $Scale `
                              -Match $Match -Profile $Profile -ConfigPath $ConfigPath

    if ($List) {
        $ctlRes = @(Get-SpacedeskControllerRes -Match $s.Match)
        $isSpacedesk = {
            param($d)
            (-not $d.IsPrimary) -and (
                ($d.FriendlyName -and $d.FriendlyName -match [regex]::Escape($s.Match)) -or
                ($d.Width -and ($ctlRes -contains ('{0}x{1}' -f $d.Width, $d.Height))) -or
                $d.IsIndirect)
        }
        $rows = @(Get-ActiveDisplay)
        Write-Host ("Active displays (spacedesk match marked with *):") -ForegroundColor Cyan
        $rows | ForEach-Object {
            [pscustomobject]@{
                ' '        = if (& $isSpacedesk $_) { '*' } else { '' }
                Gdi        = $_.GdiName
                Friendly   = $_.FriendlyName
                Resolution = if ($_.Width) { '{0}x{1}' -f $_.Width, $_.Height } else { '' }
                Primary    = $_.IsPrimary
                Indirect   = $_.IsIndirect
            }
        } | Format-Table -AutoSize
        if (-not ($rows | Where-Object { & $isSpacedesk $_ })) {
            Write-Warning ("No spacedesk display detected. If a non-primary display is listed above that is the iPad, re-run with -Match '<its Friendly name>'. If nothing extra is listed, Windows doesn't see it yet - connect/stream the iPad in the spacedesk viewer first." -f $s.Match)
        }
        return
    }

    $result = Invoke-SpacedeskSnap -Width $s.Width -Height $s.Height -Scale $s.Scale -Match $s.Match
    if ($PassThru) { $result }
}
