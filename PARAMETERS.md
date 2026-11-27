# Invoke-CMApplyDriverPackage.ps1 — Parameter Reference

Reference guide for `Invoke-CMApplyDriverPackage.ps1` (v5.7.0). Covers every parameter, what it does, and when to use it.

> **Devices imaged with v5.6.x builds, including the August 2026 build that logs itself as 5.5.0, are missing drivers (no audio is the usual symptom).** See [Known Issue: Devices Imaged With v5.6.x](#known-issue-devices-imaged-with-v56x) for how to find and fix them without reimaging.

---

## 1. Deployment Type (pick exactly ONE — required)

These are mutually exclusive switches that tell the script what context it's running in. Every command line **must** start with one of these.

| Switch | When to Use |
|---|---|
| `-BareMetal` | New OS deployment in WinPE during a Task Sequence. **This is the one we use for new builds.** |
| `-DriverUpdate` | Updating drivers on an already-deployed OS via a TS. Uses CCMCache via OSDDownloadContent. |
| `-OSUpgrade` | In-place OS upgrade scenario (e.g., Win10 → Win11). |
| `-PreCache` | Pre-stages driver content into CCMCache before a deployment runs. |
| `-XMLPackage` | Reads driver package details from a local XML file instead of AdminService. Rarely used. |
| `-DebugMode` | Local testing on a workstation. Allows running outside a TS and lets you mock device data. Requires `-UserName` and `-Password` directly. |

---

## 2. AdminService Connection (required for all modes except XMLPackage)

| Parameter | Required | Description |
|---|---|---|
| `-Endpoint <FQDN>` | Yes | FQDN of the SCCM server hosting the AdminService. Example: `CHMCSCCM.methodistcol.corp` or `CARLESCCM.carle.com`. |
| `-UserName <user>` | Debug only | Service account in `DOMAIN\user` or `user@domain` format. In TS modes, this comes from the `MDMUserName` TS variable instead. |
| `-Password <pass>` | Debug only | Plain text password. In TS modes, this comes from the `MDMPassword` TS variable. |

> **Important:** For BareMetal/DriverUpdate/OSUpgrade/PreCache, the credentials are read automatically from `MDMUserName` and `MDMPassword` task sequence variables. Set these as TS variables on the TS itself, **never** put them on the command line.

---

## 3. Target OS Selection (required)

These tell the script what driver package to look for.

| Parameter | Required | Allowed Values | Description |
|---|---|---|---|
| `-TargetOSName <name>` | Yes | `Windows 11`, `Windows 10` | Which OS family this build is for. |
| `-TargetOSVersion <ver>` | Yes (most modes) | `25H2`, `24H2`, `23H2`, `22H2`, `2004`, etc. | Feature update version. Pattern enforced: must be `##H#` or 4 digits. |
| `-TargetOSArchitecture <arch>` | No (default `x64`) | `x64`, `x86` | Architecture. Always `x64` for us. |

---

## 4. Package Filtering and Matching

| Parameter | Default | Description |
|---|---|---|
| `-Filter <text>` | `Drivers` | Substring filter applied to package names in the AdminService query. Only packages with this in their name are considered. Change this only if your driver package naming convention differs. |
| `-OperationalMode <mode>` | `Production` | `Production` or `Pilot`. Filters packages by their operational tag so you can test new drivers in pilot before promoting them. |
| `-UseDriverFallback` | off | If no model-specific package matches, use a generic "Driver Fallback Package" instead of failing. Useful for unknown/uncommon hardware. |
| `-OSVersionFallback` | off | If no package matches the exact `-TargetOSVersion`, look for packages targeting an older Windows version. Useful right after a Win11 release when driver packages haven't been built yet. |

---

## 5. Driver Installation Behavior

| Parameter | Default | Description |
|---|---|---|
| `-DriverInstallMode <mode>` | `Recurse` | `Recurse` runs one DISM command across the whole driver folder (faster). `Single` spawns one DISM call per `.inf` (more verbose, slower, useful for debugging individual driver failures). |
| `-PreCachePath <path>` | CCMCache | **PreCache mode only.** Override the cache path used to stage drivers. |
| `-ForceUpdate` | off | **DriverUpdate/Debug only.** Bypass the "is this version already installed" check and reinstall anyway. Use when a previous install was incomplete. |
| `-FailOnDriverInjectionError` | off | Fail the step when any driver INF fails to inject, instead of logging a warning and continuing. As of v5.7.0 this includes Extension and SoftwareComponent INFs (audio, camera, graphics and chipset customisations). Excluded firmware INFs never count. |
| `-InjectFromMount` | off | Inject straight from the mounted WIM instead of copying it to local disk first. Measured slower on 3–4 GB Dell packages, and firmware INFs can't be excluded from a read-only mount. Leave it off. |
| `-DownloadTimeoutMinutes <n>` | `45` | Stop waiting for the package download after this many minutes and fail the step. Range 5–1440. |
| `-MaxRuntimeMinutes <n>` | `60` | Time budget for the whole step. When it runs out, the step fails and the log names the phase it was stuck in. `0` disables the budget. |

---

## 6. Logging

| Parameter | Description |
|---|---|
| `-NetworkLogPath <UNC>` | Writes a duplicate of `ApplyDriverPackage.log` to a UNC path for remote troubleshooting. Example: `\\fileserver\share\OSDLogs`. The script appends the computer name to the file. **Highly recommended for any TS step you might need to debug remotely.** |
| `OSDApplyDriverPackageNetworkLog` (TS variable) | Same as `-NetworkLogPath`, but set once in a Set Task Sequence Variable step so every driver step mirrors its log without editing each command line. `-NetworkLogPath` on the command line wins when both are set. In WinPE the computer name in the file name is the temporary `MININT-...` name. |

---

## 7. Debug Mode Overrides (only valid with `-DebugMode`)

For interactive testing on a regular workstation outside a TS.

| Parameter | Allowed Values | Description |
|---|---|---|
| `-Manufacturer` | `Dell`, `Lenovo`, `Microsoft` | Pretend to be this manufacturer instead of detecting. |
| `-ComputerModel` | any string | Pretend to be this model. |
| `-SystemSKU` | any string | Pretend to be this SKU. |

---

## 8. Validation Mode (NEW in v5.4.0 — for VM testing in TS)

For dry-run testing the script during a TS on a Hyper-V VM **without** downloading or applying any drivers. Exits with code 0 on success so the TS step succeeds.

| Parameter | Description |
|---|---|
| `-ValidationMode` | Run prerequisite checks, AdminService connectivity, package retrieval, and matching — then exit cleanly. Allows execution on VMs (which would normally be blocked). **BareMetal mode only.** |
| `-MockManufacturer` | `Dell`, `Lenovo`, or `Microsoft`. Simulates a real device manufacturer. |
| `-MockModel` | Pretend to be this model (e.g., `"Dell Pro 14 Plus PB14250"`). **Watch quoting in TS command lines.** |
| `-MockSystemSKU` | Pretend to be this SKU. This is what actually drives matching, so this is the most useful mock parameter. |

---

# Common Usage Examples

### Real bare-metal Win11 build (production TS step)
```
-BareMetal -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -TargetOSVersion 24H2 -NetworkLogPath \\fileserver\share\OSDLogs
```

### Same as above, but with fallback safety nets
```
-BareMetal -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -TargetOSVersion 24H2 -UseDriverFallback -OSVersionFallback -NetworkLogPath \\fileserver\share\OSDLogs
```

### Pilot driver testing
```
-BareMetal -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -TargetOSVersion 24H2 -OperationalMode Pilot
```

### VM validation step (connectivity test only — no mock device)
```
-BareMetal -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -TargetOSVersion 24H2 -ValidationMode
```

### VM validation with mock device matching (use SKU only to avoid quoting issues)
```
-BareMetal -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -TargetOSVersion 24H2 -ValidationMode -MockManufacturer Dell -MockSystemSKU 0CDC
```

### Driver update on a deployed device
```
-DriverUpdate -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -NetworkLogPath \\fileserver\share\OSDLogs
```

### Force a driver reinstall (DriverUpdate)
```
-DriverUpdate -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -ForceUpdate
```

### Local Debug test on a tech workstation
```powershell
.\Invoke-CMApplyDriverPackage.ps1 -DebugMode -Endpoint CHMCSCCM.methodistcol.corp -UserName "METHODISTCOL\svc.MECM.ReadOnlyAna" -Password "P@ssw0rd" -TargetOSName "Windows 11" -TargetOSVersion 24H2 -Manufacturer Dell -ComputerModel "Dell Pro 14 Plus PB14250" -SystemSKU 0CDC
```

---

# Microsoft Surface Pro 12th Edition with Intel

Added in v5.5.0. The device is matched by **SystemSKU** (read from `MS_SystemInformation`). Driver content is the Microsoft Surface MSI, which the script extracts automatically during apply.

> **Firmware files are skipped automatically.** The Surface MSI contains firmware update components (INFs with `Class=Firmware`) alongside the real device drivers. Those firmware INFs previously caused the apply step to error out. As of v5.5.0 the script detects them and excludes them from injection in every apply mode (BareMetal DISM and DriverUpdate pnputil), so only the actual hardware drivers are applied. The exclusions are logged to `ApplyDriverPackage.log` as `Excluding firmware INF from driver injection: ...`. Firmware is the only thing the script excludes; see [What Gets Injected](#what-gets-injected).

| Identifier | Value |
|---|---|
| Manufacturer | `Microsoft` |
| System Model | `Surface Pro for Business 13in 12th Ed Intel` |
| SystemSKU (outside Korea) | `Surface_Pro_for_Business_13in_12th_Ed_Intel_2103` |
| SystemSKU (Korea) | `Surface_Pro_for_Business_13in_12th_Ed_Intel_2134` |
| SystemSKU (5G, outside Japan/Korea) | `Surface_Pro_5G_for_Business_13in_12th_Ed_Intel_2077` |
| SystemSKU (5G, Korea) | `Surface_Pro_5G_for_Business_13in_12th_Ed_Intel_2132` |
| Architecture | `x64` |

> **Package setup — the most common mistake:** the package's **Comment** field (this is `SMS_Package.Description`, which the script reads) must contain the **SystemSKU**, not the model name. The script matches on SystemSKU. Use this exact format:
>
> ```
> (Models included:Surface_Pro_for_Business_13in_12th_Ed_Intel_2103)
> ```
>
> or, to cover every regional/5G variant in one package:
>
> ```
> (Models included:Surface_Pro_for_Business_13in_12th_Ed_Intel_2103,Surface_Pro_for_Business_13in_12th_Ed_Intel_2134,Surface_Pro_5G_for_Business_13in_12th_Ed_Intel_2077,Surface_Pro_5G_for_Business_13in_12th_Ed_Intel_2132)
> ```
>
> ❌ `(Models included:Surface Pro 12th Edition Intel)` — this is the friendly **model name**, not a SystemSKU. It will **not** match, because the device reports the SKU `Surface_Pro_for_Business_13in_12th_Ed_Intel_2103`, and the Pro 12's WMI model (`Surface Pro for Business 13in 12th Ed Intel`) doesn't equal the friendly name either, so model fallback also fails. Editing the Comment is a metadata change — **no content redistribution needed**, just re-run.
>
> **Why the full SKU matters:** some numeric suffixes are shared across devices (e.g. `2077` and `2103` also appear on Surface Pro 10/11 SKUs), so the script matches the **entire** SystemSKU string, not just the number. Keep the full `Surface_Pro_..._Intel_####` value in the package Comment.
>
> **Applies to all Surface packages:** older Surfaces happen to work with a model name in the Comment only because their WMI model equals the package's friendly name. That assumption breaks for newer devices (like the Pro 12) whose WMI model is verbose. Put the **SystemSKU** in the Comment for every Surface package — the SKU is the stable key.
>
> This is the **Surface Pro 12th Edition with Intel** (13-inch, x64). It is a different device from the **Surface Pro 12-inch 1st Edition**, which is Snapdragon/ARM64 only and is not covered here.

### Validate the match on a VM (no download or apply)
```
-BareMetal -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -TargetOSVersion 24H2 -ValidationMode -MockManufacturer Microsoft -MockSystemSKU Surface_Pro_for_Business_13in_12th_Ed_Intel_2103
```

### Local Debug test on a tech workstation (Surface Pro 12th Ed Intel)
```powershell
.\Invoke-CMApplyDriverPackage.ps1 -DebugMode -Endpoint CHMCSCCM.methodistcol.corp -UserName "METHODISTCOL\svc.MECM.ReadOnlyAna" -Password "P@ssw0rd" -TargetOSName "Windows 11" -TargetOSVersion 24H2 -Manufacturer Microsoft -ComputerModel "Surface Pro for Business 13in 12th Ed Intel" -SystemSKU Surface_Pro_for_Business_13in_12th_Ed_Intel_2103
```

---

# What Gets Injected

Every INF in the driver package goes to DISM (BareMetal) or pnputil (DriverUpdate), **except firmware update INFs** (`Class=Firmware`). Those are renamed to `*.inf.firmware.skipped` and logged as `Excluding firmware INF from driver injection: ...`.

That includes the **Extension** and **SoftwareComponent** INFs. They are the manufacturer's layer on top of the base drivers. On a current Dell that means the Intel Smart Sound and Realtek SDCA audio extensions, the Waves and Dolby audio effects, the Realtek audio service, the camera sensor extensions, the Intel graphics extension and Intel Graphics Software, Intel DTT and the Intel ME services. Without them the hardware doesn't work as shipped, and audio is usually the first thing users notice.

After injection, `ApplyDriverPackage.log` shows two lines like these (Dell Pro Max 16 MC16250 package). On a clean build the two numbers match:

```
 - 301 INF(s) will be passed to driver injection, including 63 Extension and 27 SoftwareComponent INF(s)
 - DISM staged 301 of 301 INF(s) found under the injection source
```

If DISM staged fewer INFs than it was given, the missing ones are listed under `driver INF(s) failed to inject`, each with its setup class and error code.

---

# Known Issue: Devices Imaged With v5.6.x

**Symptom:** no sound after imaging. The camera, Intel Graphics Software, Intel DTT or Intel ME (LMS) components are often missing as well. Device Manager can look mostly clean, because what's missing is the extension and software component packages rather than the base drivers.

**Cause:** these builds removed driver INFs from the package before DISM ran, because they wrongly treated Extension and SoftwareComponent INFs as impossible to inject offline. On a Dell Pro Max 16 MC16250, v5.6.3 withheld 90 of 301 INFs, 36 of them audio. DISM still reported success because it was never given those INFs. Fixed in v5.7.0.

| Build | What its log shows | What it withheld |
|---|---|---|
| v5.6.x (Oct–Nov 2026) | `Script version: 5.6.x` and `Excluding non-injectable Extension INF ...` | Extension and SoftwareComponent INFs, BareMetal only |
| August 2026 build (commit `656367f`) | `Script version: 5.5.0` (not bumped) and `offline-incompatible INF file(s) safely skipped` | Extension and SoftwareComponent INFs **and every `*_dch.inf`** (which includes the Intel graphics base driver), in every mode, DriverUpdate included. Each one is logged as `Skipping firmware INF`. |

**Check a device:** this returns `True` when the device's `ApplyDriverPackage.log` (kept under `C:\Windows\CCM\Logs`) shows either build's exclusions. It works as a ConfigMgr **Run Script** against a collection. Run it *before* remediating, because the log keeps the old lines afterwards.

```powershell
[bool](Get-ChildItem -Path "$env:windir\CCM\Logs" -Filter "ApplyDriverPackage*.log" -Recurse -ErrorAction SilentlyContinue |
    Select-String -Pattern 'Excluding non-injectable (Extension|SoftwareComponent) INF|offline-incompatible INF file' -List |
    Select-Object -First 1)
```

**Fix without reimaging:** run the DriverUpdate step with v5.7.0 and `-ForceUpdate`, then restart:

```
-DriverUpdate -Endpoint CHMCSCCM.methodistcol.corp -TargetOSName "Windows 11" -ForceUpdate
```

`-ForceUpdate` is required. The build wrote a registry stamp (`HKLM\SOFTWARE\MSEndpointMgr\DriverPackage`) that otherwise makes DriverUpdate skip the device as already up to date. From v5.7.0 the stamp also records `ScriptVersion`, so a future problem like this can be targeted by version.

---

# Required TS Variables

These must be set on the Task Sequence (Properties > Variables) for any non-Debug mode:

| Variable | Value |
|---|---|
| `MDMUserName` | Service account, e.g. `METHODISTCOL\svc.MECM.ReadOnlyAna` |
| `MDMPassword` | Service account password (mark as "Do not display this value") |

The service account needs the **Read-Only Analyst** RBAC role in MECM with security scope set to **"All instances of the objects that are related to the assigned security roles."**

---

# Quoting Tips for TS Command Lines

When passing values with spaces in a "Run PowerShell Script" step, the TS parser is finicky. A few rules:

- Values without spaces: no quotes needed (`-MockSystemSKU 0CDC`)
- Values with spaces: wrap in **double quotes** (`-TargetOSName "Windows 11"`)
- Values with spaces inside a Run PowerShell Script step: may need escaped or single-wrapped quotes (`-MockModel '"Dell Pro 14 Plus PB14250"'`)
- **Best practice:** prefer SystemSKU over ComputerModel for matching tests since SKUs never have spaces.

---

# Splitting Real vs. Validation Steps in a TS

To run the real driver step on physical hardware and the validation step on VMs only, use a WMI condition on each step's **Options** tab.

**Physical-only condition (apply to real driver steps):**
```sql
SELECT * FROM Win32_ComputerSystem WHERE Model != "Virtual Machine" AND Model != "VMware Virtual Platform" AND Model != "VirtualBox" AND Model != "VMWare7,1"
```

**VM-only condition (apply to validation step):**
```sql
SELECT * FROM Win32_ComputerSystem WHERE Model = "Virtual Machine" OR Model = "VMware Virtual Platform" OR Model = "VirtualBox" OR Model = "VMWare7,1"
```

Set both conditions with **WMI namespace:** `root\cimv2`.
