param($Timer)

$ErrorActionPreference = 'Stop'

# =========================================================
# REQUIRED APP SETTINGS
# =========================================================

$required = @(
    'TENANT_ID',
    'CLIENT_ID',
    'CLIENT_SECRET',
    'GROUP_CONFIG'
)

foreach ($r in $required) {
    if ([string]::IsNullOrWhiteSpace(
        [System.Environment]::GetEnvironmentVariable($r, 'Process')
    )) {
        throw "Missing required App Setting: $r"
    }
}

# =========================================================
# GRAPH AUTHENTICATION
# =========================================================

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Groups

Write-Host "========================================"
Write-Host "ABFRL License Balancer Started"
Write-Host "Execution Time : $(Get-Date)"
Write-Host "========================================"

$secret = ConvertTo-SecureString $env:CLIENT_SECRET -AsPlainText -Force
$cred   = New-Object PSCredential($env:CLIENT_ID, $secret)

Connect-MgGraph `
    -TenantId $env:TENANT_ID `
    -ClientSecretCredential $cred `
    -NoWelcome

Write-Host "Connected to Microsoft Graph."

# =========================================================
# CONFIG
# =========================================================

$configs = $env:GROUP_CONFIG | ConvertFrom-Json

Write-Host "Business Units Loaded : $($configs.Count)"

# =========================================================
# HELPERS
# =========================================================

function Invoke-WithRetry {
    param(
        [scriptblock]$Script,
        [int]$Retries = 5
    )

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            return & $Script
        }
        catch {
            if ($i -eq $Retries) {
                throw
            }

            $delay = [math]::Min(
                60,
                [int][math]::Pow(2, $i)
            )

            Write-Warning "Retry $i failed. Waiting $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GroupUserIds {
    param(
        [string]$GroupId
    )

    @(
        Invoke-WithRetry {
            Get-MgGroupMember `
                -GroupId $GroupId `
                -All
        } |
        Where-Object {
            $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user'
        } |
        Select-Object -ExpandProperty Id
    )
}

function Get-UsersOrderedByCreation {
    param(
        [string]$GroupId
    )

    $ids = @(
        Invoke-WithRetry {
            Get-MgGroupMember `
                -GroupId $GroupId `
                -All
        } |
        Where-Object {
            $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user'
        } |
        Select-Object -ExpandProperty Id
    )

    $users = foreach ($id in $ids) {
        Invoke-WithRetry {
            Get-MgUser `
                -UserId $id `
                -Property Id,UserPrincipalName,CreatedDateTime
        }
    }

    @($users) |
        Sort-Object CreatedDateTime -Descending
}

function Add-UserToGroup {
    param(
        [string]$GroupId,
        [string]$UserId
    )

    New-MgGroupMemberByRef `
        -GroupId $GroupId `
        -OdataId "[graph.microsoft.com](https://graph.microsoft.com/v1.0/directoryObjects/$UserId)"
}

function Remove-UserFromGroup {
    param(
        [string]$GroupId,
        [string]$UserId
    )

    Remove-MgGroupMemberByRef `
        -GroupId $GroupId `
        -DirectoryObjectId $UserId
}

# =========================================================
# PROCESS BUSINESS UNITS
# =========================================================

foreach ($config in $configs) {

    $Name            = $config.Name
    $PrimaryGroupId  = $config.PrimaryGroupId
    $OverflowGroupId = $config.OverflowGroupId
    $PrimaryCap      = [int]$config.PrimaryCap
    $OverflowCap     = [int]$config.OverflowCap

    Write-Host ""
    Write-Host "########################################################"
    Write-Host "PROCESSING BU : $Name"
    Write-Host "E1 Group      : $PrimaryGroupId"
    Write-Host "EOP1 Group    : $OverflowGroupId"
    Write-Host "E1 Cap        : $PrimaryCap"
    Write-Host "EOP1 Cap      : $OverflowCap"
    Write-Host "########################################################"

    $MovedThisRun = New-Object 'System.Collections.Generic.HashSet[string]'

    # =====================================================
    # E1 -> EOP1
    # =====================================================

    $primaryUsers = @(Get-UsersOrderedByCreation $PrimaryGroupId)
    $primaryCount = $primaryUsers.Count

    Write-Host "Current E1 User Count : $primaryCount"

    $excessPrimary = $primaryCount - $PrimaryCap

    if ($excessPrimary -gt 0) {

        Write-Host "Moving $excessPrimary users from E1 to EOP1"

        $toMove = $primaryUsers | Select-Object -First $excessPrimary

        foreach ($user in $toMove) {

            $overflowIds = @(Get-GroupUserIds $OverflowGroupId)

            if ($overflowIds -notcontains $user.Id) {
                Add-UserToGroup `
                    -GroupId $OverflowGroupId `
                    -UserId $user.Id
            }

            Remove-UserFromGroup `
                -GroupId $PrimaryGroupId `
                -UserId $user.Id

            [void]$MovedThisRun.Add($user.Id)

            Write-Host "Moved to EOP1 : $($user.UserPrincipalName)"
        }
    }
    else {
        Write-Host "No E1 overflow detected."
    }

    # =====================================================
    # EOP1 -> E1 BACKFILL
    # =====================================================

    $primaryUsers = @(Get-UsersOrderedByCreation $PrimaryGroupId)
    $room = $PrimaryCap - $primaryUsers.Count

    Write-Host "Available E1 Slots : $room"

    if ($room -gt 0) {

        $overflowUsers = @(
            Get-UsersOrderedByCreation $OverflowGroupId |
            Where-Object {
                -not $MovedThisRun.Contains($_.Id)
            } |
            Select-Object -First $room
        )

        foreach ($user in $overflowUsers) {

            Add-UserToGroup `
                -GroupId $PrimaryGroupId `
                -UserId $user.Id

            Remove-UserFromGroup `
                -GroupId $OverflowGroupId `
                -UserId $user.Id

            Write-Host "Moved back to E1 : $($user.UserPrincipalName)"
        }
    }

    # =====================================================
    # EOP1 CAP ENFORCEMENT
    # =====================================================

    $overflowUsers = @(Get-UsersOrderedByCreation $OverflowGroupId)
    $overflowCount = $overflowUsers.Count

    Write-Host "Current EOP1 Count : $overflowCount"

    $excessOverflow = $overflowCount - $OverflowCap

    if ($excessOverflow -gt 0) {

        Write-Warning "$Name EOP1 exceeds cap by $excessOverflow"

        $toRemove = $overflowUsers | Select-Object -First $excessOverflow

        foreach ($user in $toRemove) {

            Remove-UserFromGroup `
                -GroupId $OverflowGroupId `
                -UserId $user.Id

            Write-Warning "Removed from EOP1 : $($user.UserPrincipalName)"
        }
    }
    else {
        Write-Host "EOP1 capacity is healthy."
    }

    # =====================================================
    # SUMMARY
    # =====================================================

    $finalPrimary  = @(Get-GroupUserIds $PrimaryGroupId).Count
    $finalOverflow = @(Get-GroupUserIds $OverflowGroupId).Count

    Write-Host ""
    Write-Host "================ SUMMARY ================="
    Write-Host "Business Unit : $Name"
    Write-Host "Final E1      : $finalPrimary"
    Write-Host "Final EOP1    : $finalOverflow"
    Write-Host "==========================================="
}

Disconnect-MgGraph | Out-Null

Write-Host ""
Write-Host "ABFRL LICENSE BALANCER COMPLETED SUCCESSFULLY"
Write-Host "Business Units Processed : $($configs.Count)"
Write-Host "Execution Time : $(Get-Date)"
