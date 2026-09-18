<#
.SYNOPSIS
    One-time setup: grants the Automation account's system-assigned managed identity
    the WindowsDefenderATP application permission Machine.ReadWrite.All.

.DESCRIPTION
    Run this ONCE from your workstation (not in the runbook), signed in with an account
    that can create app role assignments (Global Administrator or Privileged Role
    Administrator). Requires the Microsoft.Graph.Applications module:
        Install-Module Microsoft.Graph.Applications -Scope CurrentUser

    Find the managed identity Object ID in the portal:
    Automation account > Account Settings > Identity > Object (principal) ID

.EXAMPLE
    .\Grant-ManagedIdentity-MDEPermission.ps1 -ManagedIdentityObjectId '00000000-0000-0000-0000-000000000000'
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ManagedIdentityObjectId
)

$ErrorActionPreference = 'Stop'

Connect-MgGraph -Scopes 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All' -NoWelcome

# WindowsDefenderATP first-party application - same app ID in every tenant
$mdeAppId = 'fc780465-2017-40d4-a0c5-307022471b92'
$mdeSp = Get-MgServicePrincipal -Filter "appId eq '$mdeAppId'"
if (-not $mdeSp) { throw 'WindowsDefenderATP service principal was not found in this tenant.' }
Write-Host "Found service principal: $($mdeSp.DisplayName) (object id $($mdeSp.Id))"

# Resolve the app role GUID dynamically instead of hardcoding it
$appRole = $mdeSp.AppRoles | Where-Object {
    $_.Value -eq 'Machine.ReadWrite.All' -and $_.AllowedMemberTypes -contains 'Application'
}
if (-not $appRole) { throw "App role 'Machine.ReadWrite.All' was not found on the WindowsDefenderATP service principal." }

$existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId -All |
    Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $mdeSp.Id }

if ($existing) {
    Write-Host 'Machine.ReadWrite.All is already assigned to this managed identity - nothing to do.'
} else {
    $null = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId `
        -PrincipalId $ManagedIdentityObjectId -ResourceId $mdeSp.Id -AppRoleId $appRole.Id
    Write-Host 'Assigned Machine.ReadWrite.All (WindowsDefenderATP) to the managed identity.'
    Write-Host 'Note: managed-identity tokens are cached, so the new permission can take a while to become effective.'
}

Write-Host ''
Write-Host 'Current app role assignments for the managed identity:'
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId -All |
    Format-Table PrincipalDisplayName, ResourceDisplayName, AppRoleId -AutoSize
