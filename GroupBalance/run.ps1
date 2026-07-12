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
    if (:IsNullOrWhiteSpace(:GetEnvironmentVariable($r, 'Process'))) {
        throw "Missing required App Setting: $r"
    }
}

# =========================================================
# GRAPH AUTH
# =========================================================

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Groups

$secret = ConvertTo-SecureString $env:CLIENT_SECRET -AsPlainText -Force
$cred   = New-Object PSCredential($env:CLIENT_ID, $secret)

Connect-MgGraph `
    -TenantId $env:TENANT_ID `
    -ClientSecretCredential $cred `
    -NoWelcome

# =========================================================
# CONFIG
# =========================================================

$configs = $env:GROUP_CONFIG | ConvertFrom-Json

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

            $delay = :Min(60, :Pow(2, $i))

            Write-Warning "Retry $i failed. Waiting $delay seconds."

            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GroupUserIds {
    param(
        [string]$GroupId
    )

    (
        Invoke-WithRetry {
            Get-MgGroupMember -GroupId $GroupId -All
        } |
        Where-Object {
            $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user'
        }
    ).Id
}

function Get-UsersOrderedByCreation {
    param(
        [string]$GroupId
    )

    $ids = Invoke-WithRetry {
        Get-MgGroupMember -GroupId $GroupId -All
    } |
    Where-Object {
        $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user'
    } |
    Select-Object -ExpandProperty Id

    $users = foreach ($id in $ids) {

        Invoke-WithRetry {
            Get-MgUser `
                -UserId $id `
                -Property Id,UserPrincipalName,CreatedDateTime
        }
    }

    $users |
        Sort-Object CreatedDateTime -Descending
}

function Add-UserToGroup {
    param(
        [string]$GroupId,
        [string]$UserId
    )

    New-MgGroupMemberByRef `
        -GroupId $GroupId `
        -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$UserId"
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
# PROCESS EACH BU
# =========================================================

foreach ($config in $configs) {

    $Name            = $config.Name
    $PrimaryGroupId  = $config.PrimaryGroupId
    $OverflowGroupId = $config.OverflowGroupId
    $PrimaryCap      = [int]$config.PrimaryCap
    $OverflowCap     = [int]$config.OverflowCap

    Write-Host "================================================="
    Write-Host "Processing: $Name"
    Write-Host "================================================="

    $MovedThisRun = New-Object 'System.Collections.Generic.HashSet[string]'

    # =====================================================
    # PHASE 1
    # PRIMARY(E1) -> OVERFLOW(EOP1)
    # =====================================================

    $primaryUsers = Get-UsersOrderedByCreation $PrimaryGroupId

    $primaryCount = $primaryUsers.Count

    Write-Host "Primary Count : $primaryCount"
    Write-Host "Primary Cap   : $PrimaryCap"

    $excessPrimary = $primaryCount - $PrimaryCap

    if ($excessPrimary -gt 0) {

        Write-Host "$Name : Moving $excessPrimary users from E1 to EOP1"

        $toMove = $primaryUsers |
                  Select-Object -First $excessPrimary

        foreach ($user in $toMove) {

            $overflowIds = Get-GroupUserIds $OverflowGroupId

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

    # =====================================================
    # PHASE 2
    # OVERFLOW(EOP1) -> PRIMARY(E1)
    # =====================================================

    $primaryUsers = Get-UsersOrderedByCreation $PrimaryGroupId

    $room = $PrimaryCap - $primaryUsers.Count

    if ($room -gt 0) {

        Write-Host "$Name : E1 has room for $room users"

        $overflowUsers =
            Get-UsersOrderedByCreation $OverflowGroupId |
            Where-Object {
                -not $MovedThisRun.Contains($_.Id)
            } |
            Select-Object -First $room

        foreach ($user in $overflowUsers) {

            Add-UserToGroup `
                -GroupId $PrimaryGroupId `
                -UserId $user.Id

            Remove-UserFromGroup `
                -GroupId $OverflowGroupId `
                -UserId $user.Id

            Write-Host "Moved to E1 : $($user.UserPrincipalName)"
        }
    }

    # =====================================================
    # PHASE 3
    # OVERFLOW CAP ENFORCEMENT
    # =====================================================

    $overflowUsers = Get-UsersOrderedByCreation $OverflowGroupId

    $overflowCount = $overflowUsers.Count

    Write-Host "Overflow Count : $overflowCount"
    Write-Host "Overflow Cap   : $OverflowCap"

    $excessOverflow = $overflowCount - $OverflowCap

    if ($excessOverflow -gt 0) {

        Write-Warning "$Name : EOP1 exceeds cap by $excessOverflow"

        $toRemove =
            $overflowUsers |
            Select-Object -First $excessOverflow

        foreach ($user in $toRemove) {

            Remove-UserFromGroup `
                -GroupId $OverflowGroupId `
                -UserId $user.Id

            Write-Warning "Removed from EOP1 : $($user.UserPrincipalName)"
        }
    }

    # =====================================================
    # SUMMARY
    # =====================================================

    $finalPrimary  = (Get-GroupUserIds $PrimaryGroupId).Count
    $finalOverflow = (Get-GroupUserIds $OverflowGroupId).Count

    Write-Host ""
    Write-Host "Summary : $Name"
    Write-Host "E1 Count      : $finalPrimary"
    Write-Host "EOP1 Count    : $finalOverflow"
    Write-Host ""
}

Disconnect-MgGraph | Out-Null

Write-Host "All business units processed successfully."
