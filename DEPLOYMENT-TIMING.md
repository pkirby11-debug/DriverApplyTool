# Why Driver/BIOS Updates Install at Random Times (and How to Stop It)

This doc covers the "Driver Updates - Dell &lt;model&gt; - Windows 11 x64" / BIOS DUP
**application** deployments — why they ignore maintenance windows, why users get restart
prompts at random times of day, and how to deploy them correctly. Everything below is
verified against current Microsoft Learn documentation (links at the bottom).

---

## TL;DR — the three things that bite people

1. **Maintenance windows belong to the DEVICE, not the deployment.** A device's effective
   maintenance windows are the union of the windows on *every collection it is a member of*.
   When the old collections (the ones that carried the MW) were deleted, the devices lost the
   window. The new collections have no MW, so unless a device is in *some other* collection
   with an applicable window, a Required deployment with an "As soon as possible" deadline is
   enforced **as soon as each client next picks up policy** — Microsoft documents that
   past-deadline deployments are "activated and enforced immediately" when policy arrives, and
   policy polling (default: every 60 minutes) is staggered per machine. Add the 7-day staggered
   re-evaluation retry cycle (below) for machines that failed detection, and you get exactly
   the "random times throughout the day" symptom.

2. **Maintenance window TYPE matters.** When you create a MW you pick what it applies to:
   `All deployments`, `Software updates`, or `Task sequences`. These driver/BIOS updates are
   **Applications**, so they only honor an **"All deployments"** window. A window created as
   "Software updates" (an easy mistake — they're called *updates* after all) does **nothing**
   for these deployments. This is the most common reason "the maintenance window didn't work."

3. **The User Experience tab can bypass the window entirely.** Every app deployment has two
   checkboxes under *"When the installation deadline is reached, allow these activities to be
   performed outside the maintenance window"* — **Software Installation** and **System
   restart**. If either is checked, that activity ignores maintenance windows once the
   deadline passes. The collection's Deployments tab won't show this; you have to open each
   deployment (or run the report script below, which flags both columns).

## Why the prompts keep coming back even after you removed deployments

- **A collection's Deployments tab only shows deployments targeted at THAT collection.** The
  same applications can have older/duplicate Required deployments on other collections you
  aren't looking at. Sweep the whole site (the script below does this) instead of checking
  collection by collection.
- **Purpose (Required vs. Available) cannot be changed on an existing deployment.** It's
  greyed out in the console and even `Set-CMApplicationDeployment` has no parameter for it.
  "Re-adding without Required" only works if the old deployment is deleted and a brand-new
  one is created with purpose **Available** — and the screenshots show the current deployments
  are all still **Required** with past deadlines, so they are still being enforced.
- **Something is (re)creating these deployments — and it is not the stock Driver Automation
  Tool.** The MSEndpointMgr Driver Automation Tool only creates *packages* ("Drivers - …",
  "BIOS Update - …") for task-sequence use; it has never contained code that creates ConfigMgr
  applications, collections, or deployments. So the "Driver Updates - …" applications, the
  "Driver Automation Tool Dell Driver Updates" collection, and any deployments that reappear
  after you delete them came from something else — a custom script, a scheduled task, or
  another product. **Find and disable that automation before cleaning up**, or the cleanup
  won't stick.
- **Application re-evaluation retries failed installs forever.** Clients re-run detection for
  every deployed application on the *Application Deployment Evaluation Cycle* (client setting
  "Schedule re-evaluation for deployments", default: every 7 days, staggered per client). A
  BIOS DUP that ran but hasn't taken effect yet (machine never rebooted) fails detection with
  `0x87D00324` ("the application was not detected after installation completed"); one that
  silently failed (BitLocker not suspended, laptop not on AC power) stays non-compliant. Either
  way the client **re-attempts the install on the next cycle** and the user gets prompted
  again. Different machines hit their cycle on different days → reports trickle in randomly
  for weeks.
- **Deleting a deployment does not cancel a pending restart.** A client that already ran the
  DUP and returned exit code 3010 (soft reboot) keeps prompting per your *Computer Restart*
  client settings — by default ConfigMgr force-restarts 90 minutes after the deadline, shows
  a reminder every 240 minutes, and a final 15-minute countdown — until the device actually
  restarts. No server-side change can un-ask that; it drains as machines reboot.

## Emergency stop

Use [`Stop-DriverUpdateDeployments.ps1`](Stop-DriverUpdateDeployments.ps1) from a machine with
the ConfigMgr console installed:

```powershell
# 1. Report only - see EVERY matching deployment in the site + CSV backup, change nothing
.\Stop-DriverUpdateDeployments.ps1 -SiteCode CHM -ProviderMachineName CHMCSCCM.methodistcol.corp

# 2. Review the output, then actually remove them and push a policy refresh to clients
.\Stop-DriverUpdateDeployments.ps1 -SiteCode CHM -ProviderMachineName CHMCSCCM.methodistcol.corp -Remove -TriggerPolicyRefresh
```

Order of operations that actually stops the bleeding:

1. **Find and disable whatever creates these deployments first** (custom script, scheduled
   task, or product — the stock Driver Automation Tool doesn't do this), or they come back.
2. Run the script in report mode; review; run again with `-Remove -TriggerPolicyRefresh`.
   The policy refresh makes clients drop the enforcement policy in minutes instead of up to
   an hour. Microsoft documents that this still can't stop a client that has already begun
   enforcing.
3. Accept that machines already pending a reboot will prompt until they restart — that drains
   over a few days.

## Deploying these correctly next time

1. Put the target devices in a collection with a maintenance window whose type is
   **All deployments** (not "Software updates"). Verify a sample device actually has the
   window: check `ServiceWindowManager.log` on the client ("Refreshing Service Windows" lists
   every window the device has), or `Get-CMMaintenanceWindow -CollectionId <id>` server-side.
2. Deploy **Required** with a **scheduled deadline** (a specific date/time), not "As soon as
   possible". Enforcement then waits for the first *All deployments* window after the deadline.
3. On the **User Experience** tab: leave *Software Installation* and *System restart* outside
   the maintenance window **unchecked**, and set the restart behavior you want ("ConfigMgr can
   force a device restart" only if you want it to reboot inside the window).
4. Make sure each deployment type's **Maximum allowed run time** is *shorter* than the
   maintenance window. Documented behavior: if the max run time exceeds the window, the client
   never starts the install and just waits for a big-enough window (the opposite failure:
   nothing ever installs and compliance sits at 0%).
5. Pilot on a small collection first and watch `AppEnforce.log`, `AppDiscovery.log`, and
   `ServiceWindowManager.log` on one client through a full window before scaling out.

## Sources (Microsoft Learn)

- [How to use maintenance windows](https://learn.microsoft.com/intune/configmgr/core/clients/manage/collections/use-maintenance-windows) — device-level windows, window types, max-run-time rule
- [Deploy applications — User Experience / Scheduling settings](https://learn.microsoft.com/intune/configmgr/apps/deploy-use/deploy-applications)
- [Device deployment technical reference](https://learn.microsoft.com/troubleshoot/mem/configmgr/app-management/understand/device-deployment-technical-reference) — policy polling, past-deadline enforcement
- [About client settings](https://learn.microsoft.com/intune/configmgr/core/clients/deploy/about-client-settings) — policy polling interval, re-evaluation schedule, Computer Restart
- [Device restart notifications](https://learn.microsoft.com/intune/configmgr/core/clients/deploy/device-restart-notifications)
- [Disable or delete deployments](https://learn.microsoft.com/intune/configmgr/apps/deploy-use/disable-delete-deployments) — delete + policy-refresh workflow and its limits
- [Remove-CMApplicationDeployment](https://learn.microsoft.com/powershell/module/configurationmanager/remove-cmapplicationdeployment) / [Invoke-CMClientAction](https://learn.microsoft.com/powershell/module/configurationmanager/invoke-cmclientaction)
