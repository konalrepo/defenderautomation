<#
.SYNOPSIS
    Applies Microsoft Defender for Endpoint device tags from an Excel list (Server | Tag).

.DESCRIPTION
    Runs in Azure Automation (PowerShell 7.2 runbook) under the account's system-assigned
    managed identity. Downloads Server_Tag_List.xlsx from blob storage, matches each
    hostname against onboarded MDE devices, and adds the listed tag to every matching
    device that doesn't already have it. Hostnames not found in MDE are reported and
    retried automatically on the next scheduled run. Tags are only added, never removed.

    Required managed-identity permissions:
      - WindowsDefenderATP application permission: Machine.ReadWrite.All
        (grant with Grant-ManagedIdentity-MDEPermission.ps1)
      - Azure RBAC on the storage account: Storage Blob Data Reader

.NOTES
    MDE API limits: 100 calls/minute and 1,500 calls/hour. The tag loop paces itself
    (~85 calls/min) and stops at MaxTagCallsPerRun, leaving the rest for the next run.
    Tokens must be acquired for resource https://api.securitycenter.microsoft.com even
    though requests go to api.security.microsoft.com (documented MDE requirement;
    a mismatched audience returns 403).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [string]$ContainerName = 'defender-tags',
    [string]$BlobName = 'Server_Tag_List.xlsx',

    # Column headers in the first worksheet of the workbook
    [string]$HostnameColumn = 'Server',
    [string]$TagColumn = 'Tag',

    # Optionally use https://eu.api.security.microsoft.com (EU geo endpoint) for lower latency
    [string]$ApiBaseUrl = 'https://api.security.microsoft.com',

    # Safety margin under the 1,500 calls/hour API limit
    [int]$MaxTagCallsPerRun = 1300,

    # $true = report what would change without calling the tag API
    [bool]$WhatIfMode = $false
)

$ErrorActionPreference = 'Stop'

# Surface any terminating error in the Output stream - the Test pane and job view
# can hide the Error stream, which makes failures look silent
trap {
    Write-Output '===== SCRIPT FAILED ====='
    Write-Output ($_ | Out-String)
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Output "Details: $($_.ErrorDetails.Message)" }
    if ($_.InvocationInfo) { Write-Output "At: $($_.InvocationInfo.PositionMessage)" }
    throw
}

# --- 1. Authenticate with the system-assigned managed identity --------------
Disable-AzContextAutosave -Scope Process | Out-Null
$null = Connect-AzAccount -Identity
Write-Output 'Connected with the system-assigned managed identity.'

# MDE requires tokens issued for the legacy resource URI (audience), even though
# the requests below go to api.security.microsoft.com.
Write-Output 'Requesting MDE API token...'
$tokenObj = Get-AzAccessToken -ResourceUrl 'https://api.securitycenter.microsoft.com'
# Newer Az.Accounts returns Token as SecureString, older versions as String
$mdeToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
} else {
    $tokenObj.Token
}
$headers = @{ Authorization = "Bearer $mdeToken" }

# --- 2. Download the tag list from blob storage ------------------------------
Write-Output "Creating storage context for '$StorageAccountName'..."
$storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
$localPath  = Join-Path ([System.IO.Path]::GetTempPath()) $BlobName
Write-Output "Downloading blob '$BlobName' from container '$ContainerName'..."
$null = Get-AzStorageBlobContent -Container $ContainerName -Blob $BlobName `
        -Destination $localPath -Context $storageCtx -Force
Write-Output "Downloaded '$BlobName' from container '$ContainerName'."

# --- 3. Parse the Excel list --------------------------------------------------
Import-Module ImportExcel
$rows = @(Import-Excel -Path $localPath)
if ($rows.Count -eq 0) { throw "The first worksheet in '$BlobName' contains no data rows." }

$columns = $rows[0].psobject.Properties.Name
foreach ($col in @($HostnameColumn, $TagColumn)) {
    if ($columns -notcontains $col) {
        throw "Column '$col' not found. Worksheet columns: $($columns -join ', ')"
    }
}

# hostname -> tag, case-insensitive, first occurrence wins
$desired = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $rows) {
    $hostname = ([string]$row.$HostnameColumn).Trim()
    $tag      = ([string]$row.$TagColumn).Trim()
    if (-not $hostname) { continue }
    if (-not $tag) { Write-Warning "Row for '$hostname' has an empty tag - skipped."; continue }
    if ($desired.Contains($hostname)) {
        if ($desired[$hostname] -ne $tag) {
            Write-Warning "Duplicate hostname '$hostname' with different tags ('$($desired[$hostname])' vs '$tag') - keeping the first."
        }
        continue
    }
    $desired.Add($hostname, $tag)
}
Write-Output "Tag list parsed: $($desired.Count) unique hostnames."

# --- 4. Pull the MDE device inventory (paged, max 10,000 per page) -----------
$machines = [System.Collections.Generic.List[object]]::new()
$pageSize = 10000
$skip = 0
while ($true) {
    $uri = '{0}/api/machines?$top={1}&$skip={2}' -f $ApiBaseUrl, $pageSize, $skip
    try {
        $page = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    } catch {
        # The API returns 404 Not Found when there are no (more) machines
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { break }
        throw
    }
    if (-not $page.value -or @($page.value).Count -eq 0) { break }
    $machines.AddRange([object[]]@($page.value))
    if (@($page.value).Count -lt $pageSize) { break }
    $skip += $pageSize
}
Write-Output "MDE inventory: $($machines.Count) devices retrieved."

# Index onboarded devices by short hostname (computerDnsName is usually an FQDN)
$index = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($m in $machines) {
    if ($m.onboardingStatus -ne 'Onboarded') { continue }
    if ([string]::IsNullOrWhiteSpace($m.computerDnsName)) { continue }
    $short = ($m.computerDnsName -split '\.')[0]
    if (-not $index.ContainsKey($short)) {
        $index[$short] = [System.Collections.Generic.List[object]]::new()
    }
    $index[$short].Add($m)
}

# --- 5. Reconcile: add missing tags ------------------------------------------
function Invoke-MdeTagAdd {
    param([string]$MachineId, [string]$Tag)
    $uri  = '{0}/api/machines/{1}/tags' -f $script:ApiBaseUrl, $MachineId
    $body = @{ Value = $Tag; Action = 'Add' } | ConvertTo-Json
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Headers $script:headers `
                    -ContentType 'application/json' -Body $body
            return $true
        } catch {
            $status = 0
            if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ }
            if ($status -eq 429 -and $attempt -lt 4) {
                $retryAfter = 60
                try { $retryAfter = [int]@($_.Exception.Response.Headers.GetValues('Retry-After'))[0] } catch { }
                Write-Warning "Throttled (429). Waiting $retryAfter seconds."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            throw
        }
    }
    return $false
}

$tagged = 0; $alreadyTagged = 0; $tagCalls = 0; $budgetHit = $false
$notFound = [System.Collections.Generic.List[string]]::new()
$failed   = [System.Collections.Generic.List[string]]::new()

foreach ($entry in $desired.GetEnumerator()) {
    $hostname = $entry.Key
    $tag      = $entry.Value

    if (-not $index.ContainsKey($hostname)) {
        $notFound.Add($hostname)
        continue
    }

    foreach ($machine in $index[$hostname]) {
        if (@($machine.machineTags) -contains $tag) {
            $alreadyTagged++
            continue
        }
        if ($WhatIfMode) {
            Write-Output "[WhatIf] Would add '$tag' to $($machine.computerDnsName) ($($machine.id))"
            $tagged++
            continue
        }
        if ($tagCalls -ge $MaxTagCallsPerRun) { $budgetHit = $true; break }
        try {
            if (Invoke-MdeTagAdd -MachineId $machine.id -Tag $tag) {
                Write-Output "Added '$tag' to $($machine.computerDnsName)"
                $tagged++
            }
        } catch {
            $failed.Add("$hostname : $($_.Exception.Message)")
        }
        $tagCalls++
        # Pace ~85 calls/minute to stay under the 100 calls/minute API limit
        Start-Sleep -Milliseconds 700
    }
    if ($budgetHit) { break }
}

# --- 6. Summary ---------------------------------------------------------------
Write-Output ''
Write-Output '===== SUMMARY ====='
Write-Output ("Hostnames in list        : {0}" -f $desired.Count)
Write-Output ("Tags added this run      : {0}{1}" -f $tagged, $(if ($WhatIfMode) { ' (WhatIf - nothing was changed)' } else { '' }))
Write-Output ("Already tagged (skipped) : {0}" -f $alreadyTagged)
Write-Output ("Not found in MDE yet     : {0}" -f $notFound.Count)
Write-Output ("Failed tag operations    : {0}" -f $failed.Count)
if ($budgetHit) {
    Write-Warning "Per-run tag-call budget ($MaxTagCallsPerRun) reached - remaining devices will be tagged on the next scheduled run."
}
if ($notFound.Count -gt 0) {
    Write-Output ''
    Write-Output 'Not yet found among onboarded MDE devices (will retry next run):'
    $notFound | ForEach-Object { Write-Output "  $_" }
}
if ($failed.Count -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    $failed | ForEach-Object { Write-Output "  $_" }
    throw "$($failed.Count) tag operation(s) failed - see output above."
}
