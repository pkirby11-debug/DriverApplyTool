<#
.SYNOPSIS
	Emergency stop for the 'Driver Updates - *' / 'BIOS Update*' application deployments.

.DESCRIPTION
	Finds every APPLICATION deployment in the site whose application name matches the
	given patterns (default: 'Driver Updates - *' and 'BIOS Update*'), across ALL
	collections - not just the one collection you happen to be looking at in the console.
	A collection's Deployments tab only shows deployments targeted at THAT collection,
	so stale/duplicate deployments on other collections are easy to miss. This script
	sweeps the whole site.

	By default the script is REPORT-ONLY: it prints what it found, flags deployments with
	the maintenance-window override checkboxes set, and exports a CSV backup of every
	matched deployment (so you can recreate them later). It makes no changes.

	Run it again with -Remove to actually delete the matched deployments. Add
	-TriggerPolicyRefresh to also push a machine policy refresh to every collection that
	was targeted, so clients drop the enforcement policy within minutes instead of waiting
	for their next policy polling cycle (default 60 minutes).

	IMPORTANT things this script cannot do:
	  * It cannot stop an install that is already running on a client, and it cannot
	    un-ask a restart that is already pending. A client that already ran a BIOS DUP and
	    returned exit code 3010 (soft reboot) will keep prompting per your Computer Restart
	    client settings until it actually restarts.
	  * It cannot stop whatever automation created these deployments from re-creating
	    them. Note the stock MSEndpointMgr Driver Automation Tool does NOT create ConfigMgr
	    applications/collections/deployments - so if these keep coming back, find the
	    custom script / scheduled task / other product that makes them and disable it first.

.PARAMETER SiteCode
	Your ConfigMgr site code, e.g. 'CHM'.

.PARAMETER ProviderMachineName
	FQDN of the server hosting the SMS Provider (normally the primary site server),
	e.g. 'CHMCSCCM.methodistcol.corp'.

.PARAMETER ApplicationNamePattern
	One or more wildcard patterns matched against the application name of each deployment.
	Defaults to 'Driver Updates - *' and 'BIOS Update*'.

.PARAMETER Remove
	Actually remove the matched deployments. Without this switch the script only reports.
	Prompts per deployment unless you also pass -Confirm:$false.

.PARAMETER TriggerPolicyRefresh
	After removal, send a 'download machine policy' client notification to every device
	collection that had a matched deployment, so clients stop enforcing quickly.

.PARAMETER BackupPath
	Folder to write the CSV backup to. Defaults to the current user's Desktop.

.EXAMPLE
	.\Stop-DriverUpdateDeployments.ps1 -SiteCode CHM -ProviderMachineName CHMCSCCM.methodistcol.corp

	Report-only. Shows every matching application deployment in the site and writes the
	CSV backup. Nothing is changed.

.EXAMPLE
	.\Stop-DriverUpdateDeployments.ps1 -SiteCode CHM -ProviderMachineName CHMCSCCM.methodistcol.corp -Remove -TriggerPolicyRefresh

	Removes every matched deployment (prompting per deployment) and pushes a policy
	refresh to the targeted collections.

.EXAMPLE
	.\Stop-DriverUpdateDeployments.ps1 -SiteCode CHM -ProviderMachineName CHMCSCCM.methodistcol.corp -Remove -Confirm:$false -TriggerPolicyRefresh

	Removes everything matched with no prompts. Use after you have reviewed the report output.

.NOTES
	FileName:	Stop-DriverUpdateDeployments.ps1
	Requires:	ConfigMgr console installed on the machine you run this from (the
			ConfigurationManager module ships with the console) and an account with
			rights to delete deployments (Application Administrator or Full
			Administrator). Windows PowerShell 5.1 always works; PowerShell 7 works
			on console version 2111 or later.
	Tip:		Easiest launch: in the console, click the top-left menu > 'Connect via
			Windows PowerShell', which lands you on the site drive already connected.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
	[Parameter(Mandatory = $true, HelpMessage = "ConfigMgr site code, e.g. 'CHM'.")]
	[ValidateNotNullOrEmpty()]
	[string]$SiteCode,

	[Parameter(Mandatory = $true, HelpMessage = "FQDN of the SMS Provider / primary site server.")]
	[ValidateNotNullOrEmpty()]
	[string]$ProviderMachineName,

	[Parameter(Mandatory = $false)]
	[ValidateNotNullOrEmpty()]
	[string[]]$ApplicationNamePattern = @('Driver Updates - *', 'BIOS Update*'),

	[Parameter(Mandatory = $false)]
	[switch]$Remove,

	[Parameter(Mandatory = $false)]
	[switch]$TriggerPolicyRefresh,

	[Parameter(Mandatory = $false)]
	[ValidateNotNullOrEmpty()]
	[string]$BackupPath = [Environment]::GetFolderPath('Desktop')
)

# --- Resolve the backup path BEFORE moving onto the CMSite drive ------------------------
# GetFolderPath('Desktop') returns '' for identities with no provisioned profile (SYSTEM,
# service accounts), and validation attributes don't run against default values.
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
	$BackupPath = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:TEMP }
}
if (-not [System.IO.Path]::IsPathRooted($BackupPath)) {
	$CurrentLocation = Get-Location
	if ($CurrentLocation.Provider.Name -eq 'FileSystem') {
		$BackupPath = Join-Path -Path $CurrentLocation.ProviderPath -ChildPath $BackupPath
	}
	else {
		throw "-BackupPath must be an absolute filesystem path when the current location is not a filesystem drive (got '$BackupPath')."
	}
}

# --- Connect to the site ---------------------------------------------------------------
$InitialLocation = Get-Location

try {
	if (-not (Get-Module -Name ConfigurationManager)) {
		# Console 2111+ puts the module on PSModulePath; fall back to the classic path.
		Import-Module -Name ConfigurationManager -ErrorAction SilentlyContinue
	}
	if (-not (Get-Module -Name ConfigurationManager)) {
		if ([string]::IsNullOrEmpty($env:SMS_ADMIN_UI_PATH)) {
			throw "ConfigurationManager module not found and SMS_ADMIN_UI_PATH is not set. Run this from a machine with the ConfigMgr console installed."
		}
		# SMS_ADMIN_UI_PATH ends in \bin\i386; the module manifest lives one level up in \bin.
		Import-Module (Join-Path -Path (Split-Path -Path $env:SMS_ADMIN_UI_PATH) -ChildPath 'ConfigurationManager.psd1') -ErrorAction Stop
	}
	if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
		# -WhatIf:$false: mounting the site drive is connection plumbing, not the guarded
		# change - a '-Remove -WhatIf' dry run still needs to connect and report.
		New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName -ErrorAction Stop -WhatIf:$false | Out-Null
	}
	Set-Location -Path ("{0}:" -f $SiteCode) -ErrorAction Stop
}
catch {
	Set-Location -Path $InitialLocation
	throw "Failed to connect to site '$SiteCode' on '$ProviderMachineName'. $($_.Exception.Message)"
}

try {
	# --- Find matching application deployments across the WHOLE site ------------------
	Write-Host "Searching all application deployments in site $SiteCode matching: $($ApplicationNamePattern -join ', ')" -ForegroundColor Cyan
	$Matched = New-Object System.Collections.Generic.List[object]
	$SeenAssignments = New-Object 'System.Collections.Generic.HashSet[string]'
	foreach ($Pattern in $ApplicationNamePattern) {
		# -Name supports wildcards natively; returns SMS_ApplicationAssignment objects.
		foreach ($Deployment in @(Get-CMApplicationDeployment -Name $Pattern)) {
			if ($SeenAssignments.Add([string]$Deployment.AssignmentUniqueID)) {
				$Matched.Add($Deployment)
			}
		}
	}

	if ($Matched.Count -eq 0) {
		Write-Host "No application deployments matched. Nothing to do." -ForegroundColor Yellow
		return
	}

	# --- Build the report / backup ----------------------------------------------------
	$Report = foreach ($Deployment in $Matched) {
		[PSCustomObject]@{
			ApplicationName    = $Deployment.ApplicationName
			CollectionName     = $Deployment.CollectionName
			TargetCollectionID = $Deployment.TargetCollectionID
			# SMS_ApplicationAssignment.OfferTypeID: 0 = Required, 2 = Available
			Purpose            = switch ($Deployment.OfferTypeID) { 0 { 'Required' } 2 { 'Available' } default { "Other($($Deployment.OfferTypeID))" } }
			# DesiredConfigType: 1 = Install, 2 = Uninstall
			Action             = switch ($Deployment.DesiredConfigType) { 1 { 'Install' } 2 { 'Uninstall' } default { "Other($($Deployment.DesiredConfigType))" } }
			# StartTime/EnforcementDeadline are UTC only when the deployment was created
			# with 'Time based on: UTC'; otherwise they are client-local wall time.
			TimeBase           = if ([bool]$Deployment.UseGMTTimes) { 'UTC' } else { 'ClientLocal' }
			AvailableTime      = $Deployment.StartTime
			Deadline           = $Deployment.EnforcementDeadline
			InstallOutsideMW   = [bool]$Deployment.OverrideServiceWindows
			RebootOutsideMW    = [bool]$Deployment.RebootOutsideOfServiceWindows
			DeploymentCreated  = $Deployment.CreationTime
			AssignmentID       = $Deployment.AssignmentID
			AssignmentUniqueID = $Deployment.AssignmentUniqueID
		}
	}

	Write-Host ""
	Write-Host ("Matched {0} application deployment(s) across {1} collection(s):" -f `
		@($Report).Count, @($Report | Select-Object -ExpandProperty CollectionName -Unique).Count) -ForegroundColor Cyan
	$Report | Sort-Object CollectionName, ApplicationName |
		Format-Table ApplicationName, CollectionName, Purpose, Deadline, TimeBase, InstallOutsideMW, RebootOutsideMW -AutoSize |
		Out-String -Width 300 | Write-Host

	# These two flags are the User Experience tab overrides that let a Required deployment
	# install and/or reboot OUTSIDE any maintenance window once the deadline passes - the
	# usual culprit for "it installed in the middle of the day despite our window".
	$MWBypass = @($Report | Where-Object { $_.InstallOutsideMW -or $_.RebootOutsideMW })
	if ($MWBypass.Count -gt 0) {
		Write-Host ("WARNING: {0} deployment(s) are set to install and/or reboot OUTSIDE maintenance windows." -f $MWBypass.Count) -ForegroundColor Yellow
	}

	# --- CSV backup so the deployments can be recreated later -------------------------
	# -ErrorAction Stop: if the backup cannot be written, the enclosing try has no catch,
	# so the whole run aborts BEFORE any -Remove deletions happen. -WhatIf:$false: the
	# backup/report artifact is intentionally written even during a -WhatIf dry run.
	$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
	$BackupFile = Join-Path -Path $BackupPath -ChildPath ("DriverUpdateDeployments-Backup-{0}.csv" -f $Timestamp)
	$Report | Sort-Object CollectionName, ApplicationName | Export-Csv -Path $BackupFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
	Write-Host "Backup of matched deployments written to: $BackupFile" -ForegroundColor Green

	if (-not $Remove) {
		Write-Host ""
		Write-Host "REPORT-ONLY mode. No changes were made. Re-run with -Remove to delete these deployments." -ForegroundColor Cyan
		return
	}

	# --- Remove the deployments --------------------------------------------------------
	$RemovedCollections = New-Object 'System.Collections.Generic.HashSet[string]'
	$RemovedCount = 0
	$FailedCount = 0

	foreach ($Deployment in $Matched) {
		$Target = "'$($Deployment.ApplicationName)' -> '$($Deployment.CollectionName)'"
		if ($PSCmdlet.ShouldProcess($Target, 'Remove application deployment')) {
			try {
				Remove-CMApplicationDeployment -InputObject $Deployment -Force -ErrorAction Stop
				Write-Host "Removed: $Target" -ForegroundColor Green
				$RemovedCount++
				[void]$RemovedCollections.Add([string]$Deployment.TargetCollectionID)
			}
			catch {
				Write-Warning "FAILED to remove $Target : $($_.Exception.Message)"
				$FailedCount++
			}
		}
	}

	Write-Host ""
	Write-Host ("Done. Removed {0} deployment(s), {1} failure(s)." -f $RemovedCount, $FailedCount) -ForegroundColor Cyan

	# --- Optionally push a machine policy refresh so clients let go quickly ------------
	if ($TriggerPolicyRefresh -and $RemovedCollections.Count -gt 0) {
		Write-Host "Triggering machine policy refresh on targeted collections..." -ForegroundColor Cyan
		# Invoke-CMClientNotification is the pre-2111 cmdlet name and survives as an alias
		# of Invoke-CMClientAction on current builds; -DeviceCollectionId binds on both.
		foreach ($CollectionID in $RemovedCollections) {
			try {
				Invoke-CMClientNotification -DeviceCollectionId $CollectionID -NotificationType RequestMachinePolicyNow -ErrorAction Stop | Out-Null
				Write-Host "Policy refresh sent to collection $CollectionID" -ForegroundColor Green
			}
			catch {
				Write-Warning "Could not send policy refresh to collection $CollectionID : $($_.Exception.Message)"
			}
		}
	}

	if ($RemovedCount -gt 0) {
		Write-Host ""
		Write-Host "REMINDERS:" -ForegroundColor Yellow
		Write-Host " * Clients already mid-install or pending a restart WILL keep prompting until they reboot. That drains off on its own." -ForegroundColor Yellow
		Write-Host " * If some automation created these deployments, disable it or they will come back. (The stock Driver Automation Tool does not create deployments.)" -ForegroundColor Yellow
	}
}
finally {
	Set-Location -Path $InitialLocation
}
