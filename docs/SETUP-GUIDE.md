# Defender Device-Tag Automation — Setup Guide

**Goal:** An Azure Automation runbook that runs every 2 hours, reads `Server_Tag_List.xlsx`
(columns `Server` | `Tag`, 1,225 rows, 19 distinct tags), and adds the listed tag to the
matching device in Microsoft Defender for Endpoint. Servers not yet visible in MDE are
reported and retried automatically on later runs. Tags are only added, never removed.

**Files in this repository**

| File | Purpose |
|---|---|
| `runbook/Tag-DefenderServers.ps1` | The runbook (PowerShell 7.4) |
| `scripts/Grant-ManagedIdentity-MDEPermission.ps1` | One-time grant of `Machine.ReadWrite.All` to the managed identity |
| `scripts/Deploy-Azure.ps1` | Scripted deployment (alternative to the manual steps below) |
| `infra/main.bicep` / `infra/azuredeploy.json` | Infrastructure as code (alternative to manual Steps 1, 2, 3b, 4, 7) |
| `samples/Sample_Server_Tag_List.xlsx` | Workbook format example (fake data) |
| `docs/SETUP-GUIDE.md` | This guide - the manual portal walkthrough |

> This guide describes the **manual portal setup**. For the scripted path, see the repo
> `README.md` - `Deploy-Azure.ps1` automates everything except the Graph app-role grant.

**Architecture:** Blob Storage (xlsx) → Automation runbook (system-assigned managed identity)
→ MDE API `GET /api/machines` + `POST /api/machines/{id}/tags` → 2-hour recurring schedule.

All facts below were verified against Microsoft Learn on 2026-09-18; source links per step.

---

## Step 1 — Storage account + upload the Excel file

1. Portal → **Create a resource → Storage account** (any Standard LRS account in your region is fine).
2. In the storage account → **Containers → + Container**, name it `defender-tags` (private access).
3. Open the container → **Upload** → select `Server_Tag_List.xlsx`.

When the tag list changes later, just re-upload the file — the next scheduled run picks it up.

## Step 2 — Create the Automation account

1. Portal → **Create a resource → IT & Management Tools → Automation**.
2. **Basics:** subscription, resource group, name (e.g. `aa-defender-tagging`), region.
3. **Advanced tab:** ensure **System assigned** identity is selected. Per Microsoft Learn,
   "By default, a system-assigned managed identity is enabled for the Automation account."
4. **Review + create** → **Create**.
5. After deployment: Automation account → **Account Settings → Identity** → copy the
   **Object (principal) ID** of the system-assigned identity. You need it in Step 3.

Sources:
- <https://learn.microsoft.com/en-us/azure/automation/quickstarts/create-azure-automation-account-portal>
- <https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation>

## Step 3 — Grant the managed identity its two permissions

### 3a. MDE API permission `Machine.ReadWrite.All` (application)

The tag API requires application permission `Machine.ReadWrite.All`
("Read and write all machine information"). Because a managed identity has no app-registration
UI, the app role is assigned via Microsoft Graph. Run **once** from your workstation as
Global Administrator or Privileged Role Administrator:

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser   # if not present
.\Grant-ManagedIdentity-MDEPermission.ps1 -ManagedIdentityObjectId '<Object ID from Step 2.5>'
```

The script finds the `WindowsDefenderATP` service principal (first-party app ID
`fc780465-2017-40d4-a0c5-307022471b92`), resolves the `Machine.ReadWrite.All` app role GUID
dynamically, and creates the app role assignment. Verify afterwards in Entra portal →
**Enterprise applications** → (filter *Managed identities*) → your Automation account →
**Permissions**.

> Managed-identity tokens are cached — Learn warns role changes "can take significant time
> to process." Grant this first; if the first test returns 403, wait and retry.

Sources:
- <https://learn.microsoft.com/en-us/defender-endpoint/api/add-or-remove-machine-tags> (permission table)
- <https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-assign-app-role-managed-identity> (assignment method + token-cache warning)
- <https://learn.microsoft.com/en-us/answers/questions/1394819/authenticate-to-microsoft-defender-for-endpoint-ap> (WindowsDefenderATP app ID for managed-identity scenarios)

### 3b. Storage RBAC

Storage account → **Access control (IAM) → Add role assignment** →
role **Storage Blob Data Reader** → **Managed identity** → select the Automation account.
Entra credentials + Blob Data Reader is the documented way to read blobs
(`New-AzStorageContext -UseConnectedAccount`); role assignments take a few minutes to propagate.

Source: <https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-data-operations-powershell>

## Step 4 — Create a PowerShell 7.4 Runtime environment (Az + ImportExcel)

PowerShell 7.1 and 7.2 retire on 2026-09-30, and modern Az doesn't load cleanly on the 7.2
runtime (you get *"module could not be loaded"*). Run the runbook on **PowerShell 7.4** via a
Runtime environment, where **Az is a built-in default package** and only **ImportExcel** (used
to parse `.xlsx`) is added as a custom package.

1. Automation account → **Overview** → **Try Runtime environment experience**.
2. **Process Automation → Runtime Environments → Create**:
   - **Name** e.g. `ps74-defendertag`; **Language** PowerShell; **Runtime version 7.4**.
   - **Packages** tab: the **Az** package is included by default. **Add from gallery** →
     `ImportExcel` → add.
   - **Review + Create**, then wait a few minutes for the ImportExcel package to provision.

Source: <https://learn.microsoft.com/en-us/azure/automation/manage-runtime-environment>

## Step 5 — Create the runbook

1. Automation account → **Process Automation → Runbooks → Create a runbook**.
2. Name `Tag-DefenderServers`, type **PowerShell**, and under **Runtime environment** select the `ps74-defendertag` environment from Step 4 → Create.
3. Paste the full content of `Tag-DefenderServers.ps1` into the editor → **Save**.

Runbook parameters (defaults are set in the script):

| Parameter | Default | Meaning |
|---|---|---|
| `StorageAccountName` | *(required)* | Storage account from Step 1 |
| `ContainerName` | `defender-tags` | Blob container |
| `BlobName` | `Server_Tag_List.xlsx` | Blob to download |
| `HostnameColumn` / `TagColumn` | `Server` / `Tag` | Worksheet headers |
| `ApiBaseUrl` | `https://api.security.microsoft.com` | Set `https://eu.api.security.microsoft.com` for the EU geo endpoint |
| `MaxTagCallsPerRun` | `1300` | Stay under the 1,500 calls/hour API cap |
| `WhatIfMode` | `false` | `true` = report only, change nothing |

## Step 6 — Test (WhatIf first)

1. In the runbook editor → **Test pane**.
2. Set `STORAGEACCOUNTNAME`, set `WHATIFMODE` = `true` → **Start**.
3. Expected output: identity connect, blob downloaded, `Tag list parsed: 1225 unique hostnames`,
   device count, `[WhatIf] Would add ...` lines, and a summary with the not-found list.
4. If it looks right, run once more with `WHATIFMODE` = `false` for the initial bulk tagging.
   First run tags up to ~1,225 devices at ~85 calls/min → allow **~15–20 minutes**.
   (Cloud jobs may run up to 3 hours, so this is safely within limits.)
5. **Publish** the runbook.

Troubleshooting:
- **403 Forbidden** on the machines call → Step 3a not effective yet (token cache) or the
  token audience is wrong. The script already requests the token for
  `https://api.securitycenter.microsoft.com` — Learn explicitly requires this legacy resource
  as audience even though requests go to `api.security.microsoft.com`.
- **Blob download fails** → Step 3b role missing or not yet propagated.

Sources:
- <https://learn.microsoft.com/en-us/defender-endpoint/api/exposed-apis-create-app-webapp> (token audience note)
- <https://learn.microsoft.com/en-us/defender-endpoint/api/exposed-apis-list> (base + geo endpoints)

## Step 7 — Schedule every 2 hours

Portal:
1. Automation account → **Shared Resources → Schedules → Add a schedule**.
2. Name `Every-2-Hours`, **Recurring**, start time a few minutes in the future,
   **Recur every: 2 Hour**, no expiry → **Create**.
3. Runbook `Tag-DefenderServers` → **Schedules → Add a schedule** → link `Every-2-Hours` →
   under **Parameters** fill `STORAGEACCOUNTNAME` (leave `WHATIFMODE` = false) → **OK**.

PowerShell alternative:

```powershell
$start = (Get-Date).AddMinutes(10)
New-AzAutomationSchedule -ResourceGroupName '<rg>' -AutomationAccountName 'aa-defender-tagging' `
  -Name 'Every-2-Hours' -StartTime $start -HourInterval 2 -TimeZone 'Europe/Istanbul'

Register-AzAutomationScheduledRunbook -ResourceGroupName '<rg>' -AutomationAccountName 'aa-defender-tagging' `
  -RunbookName 'Tag-DefenderServers' -ScheduleName 'Every-2-Hours' `
  -Parameters @{ StorageAccountName = '<storage>' }
```

Notes from Learn: the most frequent supported interval is 1 hour (2 hours is fine);
schedule names don't support special characters; start time must be at least ~5 minutes ahead.

Sources:
- <https://learn.microsoft.com/en-us/azure/automation/shared-resources/schedules>
- <https://learn.microsoft.com/en-us/powershell/module/az.automation/new-azautomationschedule> (`-HourInterval`, `-TimeZone`)

## Step 8 — Ongoing operation

- **Idempotent:** every run skips devices that already carry their tag (checked via
  `machineTags` from the list response — no extra API calls), tags newly onboarded servers,
  and prints the remaining not-found list. Steady-state runs make only 1–2 API calls.
- **Job history:** runbook → **Jobs** — each job's Output shows the summary + not-found list.
  Failed tag calls make the job fail so it's visible at a glance.
- **Matching rule:** case-insensitive short hostname = first DNS label of MDE
  `computerDnsName`; only devices with `onboardingStatus = Onboarded` are considered; if
  several onboarded records share a hostname, all of them get the tag.
- **Removals are out of scope by design:** deleting a row does not remove the tag from the
  device. Remove manually in the portal or ask for a reconcile-mode extension.
- **API budget:** worst case (first run) ≈ 1,225 tag calls + 1–2 list calls, under the
  1,500/hour cap; the `MaxTagCallsPerRun` guard splits anything larger across runs.
- **Cost:** job minutes are billed past the monthly free grant of the Automation account —
  steady-state runs are 1–2 min each, so this stays negligible; see Azure Automation pricing.

### API reference used by the runbook

| Call | Purpose | Source |
|---|---|---|
| `GET {base}/api/machines?$top=10000&$skip=N` | Inventory paging (max page 10,000) | <https://learn.microsoft.com/en-us/defender-endpoint/api/get-machines> |
| `POST {base}/api/machines/{id}/tags` body `{"Value":"<tag>","Action":"Add"}` | Add tag | <https://learn.microsoft.com/en-us/defender-endpoint/api/add-or-remove-machine-tags> |
| Machine properties (`computerDnsName`, `machineTags`, `onboardingStatus`: `onboarded` / `CanBeOnboarded` / `Unsupported` / `InsufficientInfo`) | Matching + skip logic | <https://learn.microsoft.com/en-us/defender-endpoint/api/machine> |
