// Defender device-tag automation - infrastructure
// Deploys: storage account + container, Automation account (system-assigned MI),
// a PowerShell 7.4 Runtime environment (Az default package + ImportExcel), a 2-hour
// schedule, the runbook (optional, from URI) linked to that environment, and the
// Storage Blob Data Reader role assignment for the managed identity.
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

@description('Name of the PowerShell 7.4 Runtime environment created for the runbook.')
param runtimeEnvironmentName string = 'ps74-defendertag'

@description('Az PowerShell default-package version for the 7.4 Runtime environment. Bump if Azure changes the supported default set.')
param azPackageVersion string = '12.3.0'

@description('ImportExcel version added as a custom package to the Runtime environment.')
param importExcelVersion string = '7.8.10'

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

// PowerShell 7.4 Runtime environment. Az ships as a built-in default package (compatible
// with 7.4), so there's no manual Az.Accounts/Az.Storage import and no async-import race -
// only ImportExcel is added as a custom package. PowerShell 7.1/7.2 retire on 2026-09-30.
resource runtimeEnvironment 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automationAccount
  name: runtimeEnvironmentName
  location: location
  properties: {
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
    defaultPackages: {
      Az: azPackageVersion
    }
    description: 'PowerShell 7.4 with Az (default) + ImportExcel for the Defender tagging runbook.'
  }
}

resource importExcelPackage 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  parent: runtimeEnvironment
  name: 'ImportExcel'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/ImportExcel/${importExcelVersion}'
    }
  }
}

// Deployed only when a public raw URL is provided (e.g. after pushing to GitHub).
// For private repos / first deploy, Deploy-Azure.ps1 imports the local file instead.
// runbookType 'PowerShell' + runtimeEnvironment links the runbook to the 7.4 environment.
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = if (deployRunbookFromUri) {
  parent: automationAccount
  name: runbookName
  location: location
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtimeEnvironmentName
    logVerbose: false
    logProgress: false
    description: 'Applies Microsoft Defender for Endpoint device tags from Server_Tag_List.xlsx in blob storage.'
    publishContentLink: {
      uri: runbookContentUri
    }
  }
  dependsOn: [
    importExcelPackage
  ]
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
