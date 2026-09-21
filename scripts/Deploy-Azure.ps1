<#
.SYNOPSIS
    Deploys the Defender device-tag automation solution end to end.

.DESCRIPTION
    Creates the resource group (if needed), deploys infra/main.bicep (falls back to the
    compiled infra/azuredeploy.json when the Bicep CLI isn't installed), imports and
    publishes the runbook from the local file when no public content URI is given,
    links it to the 2-hour schedule, and uploads the tag list workbook to blob storage.

    Requires Az PowerShell modules (Az.Accounts, Az.Resources, Az.Automation, Az.Storage)
    and an authenticated session: Connect-AzAccount [+ Set-AzContext for the subscription].

    NOT covered here (one-time, needs Entra admin rights):
      scripts/Grant-ManagedIdentity-MDEPermission.ps1  -> WindowsDefenderATP Machine.ReadWrite.All

.EXAMPLE
    ./Deploy-Azure.ps1 -ResourceGroupName rg-defender-tagging -Location westeurope `
        -ScheduleTimeZone 'Europe/Istanbul' -TagListPath ~/Server_Tag_List.xlsx
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$Location = 'westeurope',
    [string]$AutomationAccountName = 'aa-defender-tagging',

    # Empty = template default: stdeftags<unique hash> (globally unique)
    [string]$StorageAccountName = '',

    [string]$ContainerName = 'defender-tags',
    [string]$ScheduleTimeZone = 'Europe/Istanbul',

    # Raw URL of runbook/Tag-DefenderServers.ps1 (public repo). Empty = import the local file.
    [string]$RunbookContentUri = '',

    # Workbook to upload as Server_Tag_List.xlsx. Defaults to the sample - replace with your real list.
    [string]$TagListPath = (Join-Path $PSScriptRoot '..' 'samples' 'Sample_Server_Tag_List.xlsx'),

    [switch]$SkipTagListUpload
)

$ErrorActionPreference = 'Stop'
$runbookName = 'Tag-DefenderServers'
$scheduleName = 'Every-2-Hours'
$blobName = 'Server_Tag_List.xlsx'

if (-not (Get-AzContext)) {
    throw "No Azure context. Run Connect-AzAccount (and Set-AzContext -Subscription <id>) first."
}
Write-Host "Deploying to subscription: $((Get-AzContext).Subscription.Name)"

# --- 1. Resource group -------------------------------------------------------
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    $null = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
    Write-Host "Created resource group '$ResourceGroupName' in $Location."
} else {
    Write-Host "Resource group '$ResourceGroupName' already exists."
}

# --- 2. Infrastructure template ---------------------------------------------
$infraDir = Join-Path $PSScriptRoot '..' 'infra'
$bicepFile = Join-Path $infraDir 'main.bicep'
$armFile   = Join-Path $infraDir 'azuredeploy.json'
$haveBicep = [bool](Get-Command bicep -ErrorAction SilentlyContinue)
$templateFile = if ($haveBicep) { $bicepFile } elseif (Test-Path $armFile) { $armFile } else { $bicepFile }
Write-Host "Using template: $templateFile"

$templateParams = @{
    automationAccountName = $AutomationAccountName
    containerName         = $ContainerName
    scheduleTimeZone      = $ScheduleTimeZone
    runbookContentUri     = $RunbookContentUri
}
if ($StorageAccountName) { $templateParams.storageAccountName = $StorageAccountName }

$deployment = New-AzResourceGroupDeployment -Name "defender-tagging-$(Get-Date -Format yyyyMMddHHmmss)" `
    -ResourceGroupName $ResourceGroupName -TemplateFile $templateFile -TemplateParameterObject $templateParams

$storageAccount = $deployment.Outputs.storageAccountName.Value
$principalId    = $deployment.Outputs.managedIdentityPrincipalId.Value
Write-Host "Infrastructure deployed. Storage: $storageAccount | MI principal: $principalId"

# --- 3. Runbook (local import path) ------------------------------------------
if (-not $RunbookContentUri) {
    $runbookPath = Join-Path $PSScriptRoot '..' 'runbook' 'Tag-DefenderServers.ps1'
    Write-Host "Importing runbook from local file: $runbookPath"
    $null = Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Name $runbookName `
        -Path $runbookPath -Type PowerShell72 -Published -Force

    $linked = Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -RunbookName $runbookName `
        -ScheduleName $scheduleName -ErrorAction SilentlyContinue
    if (-not $linked) {
        $null = Register-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName -RunbookName $runbookName `
            -ScheduleName $scheduleName `
            -Parameters @{ StorageAccountName = $storageAccount; ContainerName = $ContainerName }
        Write-Host "Linked runbook to schedule '$scheduleName'."
    } else {
        Write-Host "Runbook is already linked to schedule '$scheduleName'."
    }
}

# --- 4. Upload the tag list ---------------------------------------------------
if (-not $SkipTagListUpload) {
    $TagListPath = (Resolve-Path $TagListPath).Path
    Write-Host "Uploading '$TagListPath' as blob '$blobName'..."
    $ctx = $null
    try {
        $key = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $storageAccount)[0].Value
        $ctx = New-AzStorageContext -StorageAccountName $storageAccount -StorageAccountKey $key
    } catch {
        Write-Host 'Key access unavailable - falling back to Entra auth (needs a Blob Data role on your account).'
        $ctx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
    }
    $null = Set-AzStorageBlobContent -File $TagListPath -Container $ContainerName `
        -Blob $blobName -Context $ctx -Force
    Write-Host 'Tag list uploaded.'
    if ($TagListPath -like '*Sample_Server_Tag_List.xlsx') {
        Write-Warning 'You uploaded the SAMPLE workbook. Re-run with -TagListPath <your real list> (or upload it in the portal) before relying on the schedule.'
    }
}

# --- 5. Next steps ------------------------------------------------------------
Write-Host ''
Write-Host '===== DEPLOYMENT COMPLETE ====='
Write-Host "Managed identity principal ID : $principalId"
Write-Host ''
Write-Host 'Remaining one-time step (needs Global Admin / Privileged Role Admin):'
Write-Host "  ./Grant-ManagedIdentity-MDEPermission.ps1 -ManagedIdentityObjectId $principalId"
Write-Host ''
Write-Host 'Then test: Automation account > Runbooks > Tag-DefenderServers > Test pane (WHATIFMODE = true).'
Write-Host 'Note: wait for the Az.Accounts/Az.Storage/ImportExcel module imports to finish (Modules blade) before testing.'
