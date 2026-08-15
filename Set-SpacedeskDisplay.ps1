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
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
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

function Get-GdiAdapter {
    <#
        Enumerate GDI display adapters (\\.\DISPLAYn) with their friendly adapter string
        and state flags. Used both to recognise the spacedesk adapter and to guarantee we
        never touch the primary display.
    #>
    $adapters = @()
    $i = 0
    while ($true) {
        $dd = New-Object SpacedeskNative+DISPLAY_DEVICE
        $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd)
        if (-not [SpacedeskNative]::EnumDisplayDevicesW($null, [uint32]$i, [ref]$dd, 0)) { break }
        $adapters += [pscustomobject]@{
            DeviceName   = $dd.DeviceName        # \\.\DISPLAYn
            DeviceString = $dd.DeviceString      # e.g. "spacedesk Graphics Adapter"
            IsPrimary    = [bool]($dd.StateFlags -band [SpacedeskNative]::DISPLAY_DEVICE_PRIMARY_DEVICE)
            IsAttached   = [bool]($dd.StateFlags -band [SpacedeskNative]::DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)
        }
        $i++
    }
    $adapters
}

function Get-SpacedeskTarget {
    <#
        Locate the spacedesk display among the active DisplayConfig paths.
        Returns the (adapterId, sourceId) needed for the DPI packet and the GDI name
        needed for the resolution change, or $null if not found.
    #>
    [CmdletBinding()]
    param([string] $Match = 'spacedesk')

    [uint32] $numPaths = 0
    [uint32] $numModes = 0
    $rc = [SpacedeskNative]::GetDisplayConfigBufferSizes(
        [SpacedeskNative]::QDC_ONLY_ACTIVE_PATHS, [ref]$numPaths, [ref]$numModes)
    if ($rc -ne [SpacedeskNative]::ERROR_SUCCESS) {
        throw "GetDisplayConfigBufferSizes failed (error $rc)."
    }

    $paths = New-Object 'SpacedeskNative+DISPLAYCONFIG_PATH_INFO[]' $numPaths
    $modes = New-Object 'SpacedeskNative+DISPLAYCONFIG_MODE_INFO[]' $numModes
    $rc = [SpacedeskNative]::QueryDisplayConfig(
        [SpacedeskNative]::QDC_ONLY_ACTIVE_PATHS,
        [ref]$numPaths, $paths, [ref]$numModes, $modes, [IntPtr]::Zero)
    if ($rc -ne [SpacedeskNative]::ERROR_SUCCESS) {
        throw "QueryDisplayConfig failed (error $rc)."
    }

    $adapters = Get-GdiAdapter

    for ($p = 0; $p -lt $numPaths; $p++) {
        $path = $paths[$p]

        # Resolve the GDI source name (\\.\DISPLAYn) for this path.
        $src = New-Object SpacedeskNative+DISPLAYCONFIG_SOURCE_DEVICE_NAME
        $h = $src.header
        $h.type      = [SpacedeskNative]::GET_SOURCE_NAME
        $h.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($src)
        $h.adapterId = $path.sourceInfo.adapterId
        $h.id        = $path.sourceInfo.id
        $src.header  = $h
        if ([SpacedeskNative]::DisplayConfigGetDeviceInfo([ref]$src) -ne 0) { continue }
        $gdiName = $src.viewGdiDeviceName

        # Resolve the monitor friendly name for this path's target.
        $tgt = New-Object SpacedeskNative+DISPLAYCONFIG_TARGET_DEVICE_NAME
        $h = $tgt.header
        $h.type      = [SpacedeskNative]::GET_TARGET_NAME
        $h.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($tgt)
        $h.adapterId = $path.targetInfo.adapterId
        $h.id        = $path.targetInfo.id
        $tgt.header  = $h
        $friendly = ''
        if ([SpacedeskNative]::DisplayConfigGetDeviceInfo([ref]$tgt) -eq 0) {
            $friendly = $tgt.monitorFriendlyDeviceName
        }

        $adapter = $adapters | Where-Object { $_.DeviceName -eq $gdiName } | Select-Object -First 1

        # Match on the monitor friendly name OR the GDI adapter string.
        $isMatch = ($friendly -and $friendly -match [regex]::Escape($Match)) -or
                   ($adapter  -and $adapter.DeviceString -match [regex]::Escape($Match))
        if (-not $isMatch) { continue }

        # Fail-safe: never act on a display we cannot positively confirm is NOT the primary.
        if (-not $adapter) {
            Write-Verbose "Matched '$Match' on $gdiName but could not map it to a GDI adapter; skipping (cannot confirm it is not the primary)."
            continue
        }
        if ($adapter.IsPrimary) {
            throw "Refusing to act: the display matching '$Match' is the PRIMARY monitor ($gdiName)."
        }

        return [pscustomobject]@{
            GdiName      = $gdiName
            FriendlyName = $friendly
            AdapterId    = $path.sourceInfo.adapterId
            SourceId     = $path.sourceInfo.id
        }
    }
    return $null
}

function Get-ActiveDisplay {
    <#
        Enumerate ALL active displays with their GDI name, monitor friendly name, adapter string,
        primary flag and current resolution. Read-only; used by -List for diagnostics.
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
    $adapters = Get-GdiAdapter

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

        $adapter = $adapters | Where-Object { $_.DeviceName -eq $gdiName } | Select-Object -First 1
        $res = Get-DisplayResolution -GdiName $gdiName

        [pscustomobject]@{
            GdiName       = $gdiName
            FriendlyName  = $friendly
            AdapterString = if ($adapter) { $adapter.DeviceString } else { $null }
            IsPrimary     = if ($adapter) { $adapter.IsPrimary } else { $null }
            Width         = if ($res) { $res.Width } else { $null }
            Height        = if ($res) { $res.Height } else { $null }
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
    [pscustomobject]@{ Width = [int]$dm.dmPelsWidth; Height = [int]$dm.dmPelsHeight }
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
    $s = Resolve-SnapSettings -Width $Width -Height $Height -Scale $Scale `
                              -Match $Match -Profile $Profile -ConfigPath $ConfigPath

    if ($List) {
        $rows = @(Get-ActiveDisplay)
        Write-Host ("Active displays ('{0}' match marked with *):" -f $s.Match) -ForegroundColor Cyan
        $rows | ForEach-Object {
            $isMatch = ($_.FriendlyName  -and $_.FriendlyName  -match [regex]::Escape($s.Match)) -or
                       ($_.AdapterString -and $_.AdapterString -match [regex]::Escape($s.Match))
            [pscustomobject]@{
                ' '        = if ($isMatch) { '*' } else { '' }
                Gdi        = $_.GdiName
                Friendly   = $_.FriendlyName
                Adapter    = $_.AdapterString
                Primary    = $_.IsPrimary
                Resolution = if ($_.Width) { "$($_.Width)x$($_.Height)" } else { '' }
            }
        } | Format-Table -AutoSize
        if (-not ($rows | Where-Object {
                ($_.FriendlyName  -and $_.FriendlyName  -match [regex]::Escape($s.Match)) -or
                ($_.AdapterString -and $_.AdapterString -match [regex]::Escape($s.Match)) })) {
            Write-Warning ("Nothing matches '{0}'. If the spacedesk display is in the list above under a different name, re-run the snap with -Match '<that name>'. If it isn't listed at all, Windows doesn't see it yet - connect/stream the iPad in the spacedesk viewer first." -f $s.Match)
        }
        return
    }

    $result = Invoke-SpacedeskSnap -Width $s.Width -Height $s.Height -Scale $s.Scale -Match $s.Match
    if ($PassThru) { $result }
}
