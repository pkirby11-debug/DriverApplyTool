# Invoke-CMApplyDriverPackage.ps1 — Parameter Reference

Reference guide for `Invoke-CMApplyDriverPackage.ps1` (v5.4.0). Covers every parameter, what it does, and when to use it.

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

---

## 6. Logging

| Parameter | Description |
|---|---|
| `-NetworkLogPath <UNC>` | Writes a duplicate of `ApplyDriverPackage.log` to a UNC path for remote troubleshooting. Example: `\\fileserver\share\OSDLogs`. The script appends the computer name to the file. **Highly recommended for any TS step you might need to debug remotely.** |

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
