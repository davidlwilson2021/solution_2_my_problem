# How it works

This tool is small, but it touches three Windows display subsystems that are each a little
sharp-edged. This page explains what it does and why, so the code reads clearly.

## The core idea: two orthogonal knobs

The whole project exists because *sharpness* and *size* are controlled by two different settings,
and the obvious-but-wrong instinct is to fix size by changing resolution.

| Knob | Windows setting | What it controls | Rule for a tablet panel |
|------|-----------------|------------------|-------------------------|
| **Resolution** | Display resolution | Sharpness / crispness | Must equal the panel's native pixel grid, or an exact integer fraction of it. Anything else forces the tablet to resample every frame → blur. |
| **DPI scaling** | Scale (%) | Physical size of text and UI | Independent of resolution. This is the knob that should make things "bigger", not resolution. |

For an iPad Pro 13" (M4) the native grid is **2752 × 2064** (exactly 4:3). The only two resolutions
that map without resampling are `2752×2064` (1:1) and `1376×1032` (exact 2× — a clean pixel-doubling).
No standard 4:3 preset (1024×768, 1280×960, 1600×1200, 2048×1536) divides 2752×2064 evenly, which is
why "pick a lower resolution to make things bigger" always ends in a soft picture.

So the tool sets resolution for sharpness and DPI scale for size — separately, and only on the
spacedesk display.

## Step 1 — Find the spacedesk display (and never the primary)

`Get-SpacedeskTarget` calls `QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, …)` to enumerate active
display paths. For each path it resolves two names:

- **GDI source name** (`\\.\DISPLAYn`) via `DisplayConfigGetDeviceInfo` with
  `DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME` — needed for the resolution change.
- **Monitor friendly name** via `…GET_TARGET_NAME` — used to recognise the spacedesk monitor.

A path matches if the friendly name (or, as a fallback, the GDI adapter string from
`EnumDisplayDevices`) contains the match word (`spacedesk` by default). The `(adapterId, sourceId)`
pair from `path.sourceInfo` is exactly what the DPI packet needs.

**Safety:** if the matched display turns out to carry the *primary* flag, the function throws
instead of acting. The primary monitor is never rescaled.

## Step 2 — Set the resolution

`Set-DisplayResolution` reads the current mode with `EnumDisplaySettings(ENUM_CURRENT_SETTINGS)`,
and if it already matches the target it returns `AlreadySet` (idempotent). Otherwise it fills a
`DEVMODE` with `dmPelsWidth`/`dmPelsHeight` (fields flagged `DM_PELSWIDTH | DM_PELSHEIGHT`) and calls
`ChangeDisplaySettingsEx(…, CDS_UPDATEREGISTRY)` so the change persists.

## Step 3 — Set the per-monitor DPI scale (the interesting part)

Windows has **no documented API** to set a specific monitor's scale percentage. The Settings
"Scale" slider uses an *undocumented* `DisplayConfig` device-info call. This tool uses the same one,
with the layout verified against the community reference implementation
[`lihas/windows-DPI-scaling-sample`](https://github.com/lihas/windows-DPI-scaling-sample).

Two hidden `DISPLAYCONFIG_DEVICE_INFO_TYPE` values:

```
GET_DPI_SCALE = -3   // returns { minScaleRel, curScaleRel, maxScaleRel }
SET_DPI_SCALE = -4   // sets   { scaleRel }
```

The packet values are **relative to the display's "recommended" scale**, not absolute percentages.
Windows exposes a fixed ladder of steps:

```
100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500
```

The trick to converting an absolute target (say **250%**) into the relative index the API wants:

```
idxTarget      = indexOf(250 in DpiVals)      # = 6
idxRecommended = abs(minScaleRel)             # recommended step's absolute index, from a live GET
scaleRel       = idxTarget - idxRecommended   # then clamp to [minScaleRel, maxScaleRel]
```

`abs(minScaleRel)` works because the minimum scale is always 100% (index 0), so the number of steps
from "recommended" down to 100% *is* the recommended step's absolute index. The recommended step
depends on the current resolution — which is exactly why the tool sets resolution **first**, then
re-reads the DPI info, then sets the scale. DPI changes take effect immediately; no reboot.

`Set-DisplayDpi` is idempotent (it GETs first and returns `AlreadySet` if the current absolute
percentage already equals the target) and returns `Clamped` if the requested percentage is outside
what the display allows, applying the nearest valid step.

## Step 4 — Fire it automatically on connect

spacedesk is an **IddCx indirect display driver**. The consequence that shapes the auto-trigger:
the *adapter* ("spacedesk Graphics Adapter") is installed once and stays present forever, while a
*monitor child node* arrives on each connect and departs on each disconnect. There is therefore
**no single reliable per-connect event**, and `Win32_VideoController` instance-creation does *not*
fire on reconnect (the adapter object is never recreated).

`Watch-Spacedesk.ps1` handles this with two strategies:

- **Event mode (default):** a `Register-CimIndicationEvent` subscription on
  `__InstanceCreationEvent … Win32_PnPEntity … PNPClass = 'Monitor'`. The event is only a cheap
  wake-up; the watcher then *verifies* the spacedesk display is actually present before acting.
- **Poll mode:** a 2-second rising-edge poll (absent → present). Immune to event-schema quirks.

Three independent layers prevent double-application:

1. **Process level** — the scheduled task uses `MultipleInstances IgnoreNew`, so only one watcher runs.
2. **Event-burst level** — a debounce (default 5 s) absorbs the flurry of PnP nodes a single connect emits.
3. **Idempotency level** — the snap itself no-ops when the display is already correct, so even a
   double-fire is harmless.

The watcher is launched by an **At-Log-On** scheduled task with `-LogonType Interactive` and
`-RunLevel Limited`, because the DisplayConfig/DPI APIs must run in the real user desktop session
(a session-0 service task would fail), and rescaling a display you own needs no elevation.

## Sources

- [lihas/windows-DPI-scaling-sample](https://github.com/lihas/windows-DPI-scaling-sample) — the verified reference for the undocumented `-3`/`-4` DPI device-info types, the `DpiVals` ladder, and the relative-index math.
- [QueryDisplayConfig — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig)
- [DISPLAYCONFIG_DEVICE_INFO_HEADER — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_device_info_header)
- [ChangeDisplaySettingsEx — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsexw)
- [Indirect Display Driver Model overview (IddCx) — Microsoft Learn](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview)
- [Register-CimIndicationEvent — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/register-cimindicationevent)
