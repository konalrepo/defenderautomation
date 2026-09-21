// Defender device-tag automation - infrastructure
// Deploys: storage account + container, Automation account (system-assigned MI),
// PowerShell 7.2 modules, 2-hour schedule, runbook (optional, from URI),
// and the Storage Blob Data Reader role assignment for the managed identity.
//
// The Entra app-role grant (WindowsDefenderATP / Machine.ReadWrite.All) cannot be
// expressed in ARM - run scripts/Grant-ManagedIdentity-MDEPermission.ps1 once after deploy.

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Automation account.')
param automationAccountName string = 'aa-defender-tagging'

@description('Globally unique storage account name (3-24 lowercase letters/digits).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stdeftags${uniqueString(resourceGroup().id)}'

@description('Blob container that holds the tag list workbook.')
param containerName string = 'defender-tags'

@description('Name of the recurring schedule.')
param scheduleName string = 'Every-2-Hours'

@description('Schedule time zone ID - an IANA ID (e.g. Europe/Istanbul) or a Windows ID (e.g. Turkey Standard Time), NOT a UTC offset like "UTC+3".')
param scheduleTimeZone string = 'Europe/Istanbul'

@description('Deployment timestamp - do not set; used to compute the schedule start time.')
param baseTime string = utcNow('u')

@description('Raw URL of Tag-DefenderServers.ps1. Prefilled with this repo/branch so the Deploy to Azure button publishes the runbook automatically. Deploy-Azure.ps1 passes an empty string to import the local file instead.')
param runbookContentUri string = 'https://raw.githubusercontent.com/konalrepo/defenderautomation/defendertag/runbook/Tag-DefenderServers.ps1'

@description('Allow storage account key access. Set false to harden; uploads then require Entra auth + a Blob Data role.')
param allowSharedKeyAccess bool = true

var runbookName = 'Tag-DefenderServers'
var scheduleStartTime = dateTimeAdd(baseTime, 'PT15M')
var deployRunbookFromUri = !empty(runbookContentUri)
// Built-in role: Storage Blob Data Reader
var storageBlobDataReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowSharedKeyAccess
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
  }
}

// PowerShell 7.2 runtime modules, pinned to specific versions for deterministic deploys.
// Az.Storage depends on Az.Accounts; imports are serialized to avoid a race.
// NOTE: Automation module import is ASYNCHRONOUS - the ARM deployment returns before the
// import finishes. After deploying, wait until all three modules show 'Available' on the
// Modules blade (runtime 7.2) before the first runbook run. Bump versions intentionally.
resource azAccountsModule 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Accounts'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.5.3'
    }
  }
}

resource azStorageModule 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Storage'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Storage/9.7.2'
    }
  }
  dependsOn: [
    azAccountsModule
  ]
}

resource importExcelModule 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'ImportExcel'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/ImportExcel/7.8.10'
    }
  }
  dependsOn: [
    azStorageModule
  ]
}

// Deployed only when a public raw URL is provided (e.g. after pushing to GitHub).
// For private repos / first deploy, Deploy-Azure.ps1 imports the local file instead.
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (deployRunbookFromUri) {
  parent: automationAccount
  name: runbookName
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: false
    logProgress: false
    description: 'Applies Microsoft Defender for Endpoint device tags from Server_Tag_List.xlsx in blob storage.'
    publishContentLink: {
      uri: runbookContentUri
    }
  }
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: scheduleName
  properties: {
    frequency: 'Hour'
    interval: 2
    startTime: scheduleStartTime
    timeZone: scheduleTimeZone
    description: 'Runs the Defender tagging runbook every 2 hours.'
  }
}

// Job schedules are named by GUID. The deterministic guid() keeps redeploys idempotent;
// if you ever delete the link manually, redeploy with a changed seed string.
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (deployRunbookFromUri) {
  parent: automationAccount
  name: guid(resourceGroup().id, automationAccountName, runbookName, scheduleName)
  properties: {
    runbook: {
      name: runbookName
    }
    schedule: {
      name: scheduleName
    }
    parameters: {
      StorageAccountName: storageAccountName
      ContainerName: containerName
    }
  }
  dependsOn: [
    runbook
    schedule
  ]
}

resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, automationAccount.id, storageBlobDataReaderRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataReaderRoleId
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output automationAccountName string = automationAccount.name
output managedIdentityPrincipalId string = automationAccount.identity.principalId
output storageAccountName string = storageAccount.name
output containerName string = containerName
output scheduleName string = schedule.name
output runbookDeployedFromUri bool = deployRunbookFromUri
