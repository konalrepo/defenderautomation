# Defender Device-Tag Automation

Scheduled Azure Automation solution that applies **Microsoft Defender for Endpoint device tags**
from an Excel list. Every 2 hours a PowerShell 7.2 runbook downloads `Server_Tag_List.xlsx`
(columns `Server` | `Tag`) from blob storage, matches each hostname against onboarded MDE
devices, and adds the listed tag to every matching device that doesn't already have it.
Hostnames not yet visible in MDE are reported and retried automatically on later runs.
Tags are only added, never removed.

**No secrets anywhere**: the runbook authenticates with the Automation account's
system-assigned managed identity for both the MDE API and blob storage.

```
Server_Tag_List.xlsx ──▶ Blob Storage ──▶ Automation runbook (managed identity)
                                              │  GET  /api/machines
                                              │  POST /api/machines/{id}/tags
                                              ▼
                                    Microsoft Defender for Endpoint
```

## Repository structure

| Path | Purpose |
|---|---|
| `infra/main.bicep` | All Azure resources: storage + container, Automation account (system MI), PS 7.2 modules, 2-hour schedule, role assignment, optional runbook-from-URI |
| `infra/azuredeploy.json` | Compiled ARM template (`az bicep build`) for portal / one-click deployment |
| `runbook/Tag-DefenderServers.ps1` | The runbook (PowerShell 7.2) |
| `scripts/Deploy-Azure.ps1` | End-to-end deployment: RG → template → runbook import → schedule link → workbook upload |
| `scripts/Grant-ManagedIdentity-MDEPermission.ps1` | One-time Entra grant: WindowsDefenderATP `Machine.ReadWrite.All` to the managed identity |
| `samples/Sample_Server_Tag_List.xlsx` | Workbook format example (fake data) |
| `docs/SETUP-GUIDE.md` | Manual portal walkthrough + Microsoft Learn sources for every step |

## Prerequisites

- Az PowerShell modules on the deploying machine: `Az.Accounts`, `Az.Resources`, `Az.Automation`, `Az.Storage`
- Azure RBAC: rights to create resources **and role assignments** in the target scope (e.g. Owner)
- Entra: Global Administrator or Privileged Role Administrator for the one-time Graph app-role grant
- Microsoft Defender for Endpoint P1/P2 with devices onboarded

## Quick start

```powershell
Connect-AzAccount            # + Set-AzContext -Subscription <id> if needed

cd scripts
./Deploy-Azure.ps1 -ResourceGroupName rg-defender-tagging -Location westeurope `
    -ScheduleTimeZone 'Europe/Istanbul' -TagListPath 'C:\path\to\Server_Tag_List.xlsx'

# One-time, as Global Admin / Privileged Role Admin (principal ID is printed by the deploy):
./Grant-ManagedIdentity-MDEPermission.ps1 -ManagedIdentityObjectId <principal-id>
```

Then open the Automation account → **Runbooks → Tag-DefenderServers → Test pane** and run once
with `WHATIFMODE = true` to preview, once with `false` for the initial bulk tagging, and you're done —
the `Every-2-Hours` schedule takes over.

> **Important — wait for modules before the first run.** Automation module import is
> asynchronous, so the deployment finishes *before* `Az.Accounts`, `Az.Storage`, and
> `ImportExcel` are ready. On the **Modules** blade (filter runtime **7.2**) wait until all
> three show **Available** before running the Test pane — otherwise the runbook fails at the
> first `Az` call with *"module could not be loaded"*. A scheduled run that fires during
> import fails harmlessly and succeeds on the next cycle. Also allow a few minutes after the
> Graph grant — managed-identity tokens are cached, so an initial 403 just means "wait".

### Deploy script parameters

| Parameter | Default | Notes |
|---|---|---|
| `-ResourceGroupName` | *(required)* | Created if missing |
| `-Location` | `westeurope` | |
| `-AutomationAccountName` | `aa-defender-tagging` | |
| `-StorageAccountName` | auto (`stdeftags<hash>`) | Must be globally unique |
| `-ContainerName` | `defender-tags` | |
| `-ScheduleTimeZone` | `Europe/Istanbul` | IANA (e.g. `Europe/Istanbul`) or Windows (e.g. `Turkey Standard Time`) ID — not a UTC offset like `UTC+3` |
| `-RunbookContentUri` | *(empty)* | Raw URL of the runbook for template-based publish; empty = import the local file |
| `-TagListPath` | sample workbook | **Point this at your real list** |
| `-SkipTagListUpload` | off | |

## One-click deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fkonalrepo%2Fdefenderautomation%2Fdefendertag%2Finfra%2Fazuredeploy.json)

The button deploys `infra/azuredeploy.json` directly from this repository. The
`runbookContentUri` parameter is **prefilled** with this repo/branch's raw runbook URL, so
the template publishes the runbook and links the 2-hour schedule automatically — just set
the resource group, region, and time zone, then deploy. Two follow-ups the template can't
do: upload `Server_Tag_List.xlsx` to the container, and grant the managed identity the MDE
`Machine.ReadWrite.All` permission (both covered in the deploy walkthrough). Regenerate the
ARM file after editing the Bicep:

```bash
az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json
```

The Graph app-role grant still requires running `Grant-ManagedIdentity-MDEPermission.ps1` —
Entra app-role assignments cannot be expressed in ARM templates.

## Workbook format

First worksheet, headers on row 1 (names configurable via runbook parameters):

| Server | Tag |
|---|---|
| SRV-APP-P01 | contoso-prod-win-srv |
| SRV-APP-T01 | contoso-test-win-srv |

Hostnames are matched case-insensitively against the first DNS label of the MDE
`computerDnsName`; only devices with `onboardingStatus = Onboarded` are considered.

## Operational notes

- **API limits**: MDE allows 100 calls/min and 1,500 calls/hour. The runbook paces itself
  (~85/min), honors `Retry-After` on 429, and caps tag calls per run (`MaxTagCallsPerRun`,
  default 1300) — anything above rolls to the next run.
- **Idempotent**: already-tagged devices are skipped using `machineTags` from the inventory
  response (no extra API calls). Steady-state runs make 1–2 calls and take ~1 minute.
- **Job output** ends with a summary: tags added, skipped, failures, and the remaining
  not-found-in-MDE list.
- **Removals are out of scope**: deleting a row does not remove the tag from the device.

## Security

- Managed identity end to end; the repository contains **no credentials**.
- Least privilege: `Machine.ReadWrite.All` (MDE) + `Storage Blob Data Reader` (storage) only.
- `.gitignore` blocks `*.xlsx` — **never commit a real server inventory**; only the fake
  sample workbook is whitelisted.
- Optional hardening: deploy with `allowSharedKeyAccess=false` (template parameter); workbook
  uploads then require Entra auth with a Blob Data role.

Full manual setup instructions with the Microsoft Learn source for every step:
[`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md).
