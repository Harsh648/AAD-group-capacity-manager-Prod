param($Timer)

$ErrorActionPreference = 'Stop'

# =========================================================
# ABFRL LICENSE BALANCER
#
# Reconciles two Entra ID assigned groups per business unit:
#   PrimaryGroupId  (E1)   capped at PrimaryCap
#   OverflowGroupId (EOP1) capped at OverflowCap
#
# BUSINESS RULES
#   1. E1 over cap       -> newest members (by CreatedDateTime) move to EOP1.
#   2. E1 has free seats -> newest EOP1 members are promoted into E1.
#   3. Population exceeds PrimaryCap + OverflowCap -> the newest users beyond
#      total capacity are trimmed out of both groups.
#
# The entire target state is computed in memory from a single read of each
# group, then applied. Nothing is re-read between planning and writing, so a
# user can never be removed from one group on the basis of a stale view of the
# other. Trimming is the only removal not paired with a placement, and it fires
# only when demand genuinely exceeds total capacity.
#
# Concurrency relies on the Azure Functions timer trigger singleton lease. Every
# log line carries a run id so overlapping executions remain distinguishable.
# =========================================================

# ---------------------------------------------------------
# BEHAVIOUR TOGGLES
# ---------------------------------------------------------

# Entra group-based licensing licenses DIRECT members only. A nested group
# inside E1/EOP1 makes every seat count computed here unreliable, and its
# members cannot be removed by id. Rather than reconcile against numbers that
# may be wrong, the business unit is skipped and reported. Set to $false to
# ignore nested groups and reconcile on direct members only.
$AbortOnNestedGroup = $true

# Adds, removes and trims are always logged in full. This additionally logs one
# line per user left where they are. Off by default: it is one line per licensed
# user per run.
$LogUnchangedUsers = $false

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
# RUN IDENTITY
# =========================================================

$RunId     = [guid]::NewGuid().ToString('N').Substring(0, 8)
$StartTime = Get-Date

Write-Host '========================================'
Write-Host 'ABFRL License Balancer Started'
Write-Host "Run Id         : $RunId"
Write-Host "Execution Time : $StartTime"
Write-Host '========================================'

# =========================================================
# LOGGING
# =========================================================

function Write-RunLog {
    param(
        [string]$Message,
        [string]$Unit = '-',
        [ValidateSet('Info', 'Warn')]
        [string]$Level = 'Info'
    )

    $line = "[$RunId][$Unit] $Message"

    if ($Level -eq 'Warn') {
        Write-Warning $line
    }
    else {
        Write-Host $line
    }
}

# One line per user decision, carrying everything needed to answer
# "who moved, from where, to where, and why".
function Write-UserLog {
    param(
        [string]$Unit,
        [string]$Action,
        [string]$From,
        [string]$To,
        [string]$Upn,
        [string]$UserId,
        $Created,
        [string]$Reason,
        [string]$Result,
        [string]$Detail = ''
    )

    $createdText = if ($null -eq $Created) {
        'unknown'
    }
    else {
        ([DateTimeOffset]$Created).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }

    $parts = @(
        ('action={0}'  -f $Action.PadRight(6)),
        ('route={0}'   -f ("$From->$To").PadRight(13)),
        ('upn={0}'     -f $Upn),
        ('userId={0}'  -f $UserId),
        ('created={0}' -f $createdText),
        ('reason={0}'  -f $Reason),
        ('result={0}'  -f $Result)
    )

    if ($Detail) {
        $parts += ('detail={0}' -f $Detail)
    }

    $level = if ($Result -eq 'FAILED') { 'Warn' } else { 'Info' }

    Write-RunLog -Unit $Unit -Level $level -Message ($parts -join ' | ')
}

# =========================================================
# VALUE HELPERS
# =========================================================

# Graph responses arrive as hashtables by default but as PSObjects under some
# module versions. Read either shape rather than guessing which is in play.
function Get-Prop {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }

    return $null
}

# Returns $null when the value is absent or unparseable. Callers treat $null as
# untrustworthy data and skip the business unit rather than guess an ordering.
function ConvertTo-Utc {
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime])       { return ([DateTimeOffset]$Value).ToUniversalTime() }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try {
        $parsed = [DateTimeOffset]::Parse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        return $parsed.ToUniversalTime()
    }
    catch {
        return $null
    }
}

# Returns $null unless the value is a whole number greater than zero. A missing
# or malformed cap must never be silently coerced to 0, which would read as
# "cap of nothing" and empty the group.
function ConvertTo-PositiveInt {
    param($Value)

    if ($null -eq $Value) { return $null }

    $text = ([string]$Value).Trim()
    if ($text -eq '') { return $null }

    $parsed = 0
    if (-not [int]::TryParse($text, [ref]$parsed)) { return $null }
    if ($parsed -le 0) { return $null }

    return $parsed
}

# =========================================================
# GRAPH ERROR INSPECTION
# =========================================================

# Returns 0 when the status cannot be determined. Unknown is deliberately
# treated as retryable: retrying a few times costs a delay, whereas wrongly
# classifying a transient failure as terminal aborts the business unit.
function Get-GraphStatusCode {
    param($ErrorRecord)

    $probes = @(
        { [int]$ErrorRecord.Exception.Response.StatusCode },
        { [int]$ErrorRecord.Exception.StatusCode },
        { [int]$ErrorRecord.Exception.HttpStatusCode }
    )

    foreach ($probe in $probes) {
        try {
            $code = & $probe
            if ($code -gt 0) { return $code }
        }
        catch {
            # This exception shape does not expose a status here; try the next.
        }
    }

    return 0
}

function Get-GraphRetryAfterSeconds {
    param($ErrorRecord)

    try {
        $delta = $ErrorRecord.Exception.Response.Headers.RetryAfter.Delta
        if ($delta) { return [int]$delta.TotalSeconds }
    }
    catch {
        # No typed Retry-After available.
    }

    try {
        $raw = $ErrorRecord.Exception.Response.Headers['Retry-After']
        $seconds = 0
        if ($raw -and [int]::TryParse(([string]$raw), [ref]$seconds)) { return $seconds }
    }
    catch {
        # No raw Retry-After header available.
    }

    return 0
}

# =========================================================
# RETRY
# =========================================================

# 400/401/403/404 are terminal for this workload: a malformed request, bad
# credentials, a missing permission or a deleted object will not start working
# on the next attempt. Retrying them only delays the failure and burns quota.
$NonRetryableStatusCodes = @(400, 401, 403, 404)

function Invoke-WithRetry {
    param(
        [scriptblock]$Script,
        [int]$Retries = 5,
        [string]$Unit = '-',
        [string]$What = 'Graph call'
    )

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            return & $Script
        }
        catch {
            $status = Get-GraphStatusCode $_

            # Rethrow without logging: the caller reports the failure with the
            # user and business unit context attached.
            if ($NonRetryableStatusCodes -contains $status) { throw }
            if ($attempt -eq $Retries) { throw }

            $retryAfter = Get-GraphRetryAfterSeconds $_

            if ($retryAfter -gt 0) {
                $delay  = [math]::Min(120, $retryAfter)
                $source = 'Retry-After'
            }
            else {
                $delay  = [math]::Min(60, [int][math]::Pow(2, $attempt))
                $source = 'backoff'
            }

            $waitMessage = "$What attempt $attempt failed (HTTP $status). Waiting $delay s ($source)."
            Write-RunLog -Unit $Unit -Level Warn -Message $waitMessage

            Start-Sleep -Seconds $delay
        }
    }
}

# =========================================================
# GRAPH READS
# =========================================================

# One paged call per group. The microsoft.graph.user cast filters to users
# server side and $select returns createdDateTime in the same response, so there
# is no per-user lookup. A page that cannot be fetched throws, which skips the
# business unit rather than reconciling against a truncated membership list.
function Get-GroupUsers {
    param(
        [string]$GroupId,
        [string]$Unit,
        [string]$Label
    )

    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members/microsoft.graph.user" +
           '?$select=id,userPrincipalName,createdDateTime&$top=999'

    $users = New-Object 'System.Collections.Generic.List[object]'
    $pages = 0

    while ($uri) {
        $pageUri = $uri
        $pages++

        $page = Invoke-WithRetry -Unit $Unit -What "$Label membership page $pages" -Script {
            Invoke-MgGraphRequest -Method GET -Uri $pageUri
        }

        foreach ($entry in @(Get-Prop $page 'value')) {
            $users.Add([pscustomobject]@{
                Id      = [string](Get-Prop $entry 'id')
                Upn     = [string](Get-Prop $entry 'userPrincipalName')
                Created = ConvertTo-Utc (Get-Prop $entry 'createdDateTime')
            })
        }

        $uri = Get-Prop $page '@odata.nextLink'
    }

    $readMessage = "$Label read complete. Users: $($users.Count). Pages: $pages."
    Write-RunLog -Unit $Unit -Message $readMessage

    return $users
}

function Test-GroupHasNestedGroup {
    param(
        [string]$GroupId,
        [string]$Unit,
        [string]$Label
    )

    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members/microsoft.graph.group" +
           '?$select=id,displayName&$top=1'

    $page = Invoke-WithRetry -Unit $Unit -What "$Label nested group probe" -Script {
        Invoke-MgGraphRequest -Method GET -Uri $uri
    }

    $nested = @(Get-Prop $page 'value')

    if ($nested.Count -gt 0) {
        $nestedName = [string](Get-Prop $nested[0] 'displayName')
        $nestedMessage = "$Label contains nested group '$nestedName'. Direct-member seat counts are unreliable."
        Write-RunLog -Unit $Unit -Level Warn -Message $nestedMessage
        return $true
    }

    return $false
}

# =========================================================
# GRAPH WRITES
# =========================================================

# Adding an existing member and removing a non-member both count as success:
# they mean the desired end state already holds, which is exactly what a
# half-completed previous attempt leaves behind.
function Add-UserToGroup {
    param(
        [string]$GroupId,
        [string]$UserId,
        [string]$Unit,
        [string]$Label
    )

    $odataId = "https://graph.microsoft.com/v1.0/directoryObjects/$UserId"

    try {
        Invoke-WithRetry -Unit $Unit -What "add $UserId to $Label" -Script {
            New-MgGroupMemberByRef -GroupId $GroupId -OdataId $odataId
        } | Out-Null

        return 'OK'
    }
    catch {
        if ($_.Exception.Message -match 'already exist') { return 'ALREADY_MEMBER' }
        throw
    }
}

function Remove-UserFromGroup {
    param(
        [string]$GroupId,
        [string]$UserId,
        [string]$Unit,
        [string]$Label
    )

    try {
        Invoke-WithRetry -Unit $Unit -What "remove $UserId from $Label" -Script {
            Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $UserId
        } | Out-Null

        return 'OK'
    }
    catch {
        $status = Get-GraphStatusCode $_

        if ($status -eq 404 -or $_.Exception.Message -match 'does not exist') {
            return 'NOT_MEMBER'
        }
        throw
    }
}

# =========================================================
# ORDERING
# =========================================================

# Newest first, with user id as a tiebreaker so two accounts sharing a
# CreatedDateTime resolve identically on every run instead of arbitrarily.
function Sort-NewestFirst {
    param($Users)

    return @($Users | Sort-Object -Property `
        @{ Expression = { $_.Created }; Descending = $true },
        @{ Expression = { $_.Id };      Descending = $false })
}

# =========================================================
# BUSINESS UNIT RECONCILIATION
# =========================================================

function Invoke-BusinessUnitReconcile {
    param(
        $Config,
        $Result
    )

    $Name            = $Result.Name
    $PrimaryGroupId  = ([string]$Config.PrimaryGroupId).Trim()
    $OverflowGroupId = ([string]$Config.OverflowGroupId).Trim()
    $PrimaryCap      = ConvertTo-PositiveInt $Config.PrimaryCap
    $OverflowCap     = ConvertTo-PositiveInt $Config.OverflowCap

    Write-Host ''
    Write-Host '########################################################'
    Write-RunLog -Unit $Name -Message 'PROCESSING BUSINESS UNIT'
    Write-RunLog -Unit $Name -Message "E1 Group   : $PrimaryGroupId"
    Write-RunLog -Unit $Name -Message "EOP1 Group : $OverflowGroupId"
    Write-RunLog -Unit $Name -Message "E1 Cap     : $PrimaryCap"
    Write-RunLog -Unit $Name -Message "EOP1 Cap   : $OverflowCap"
    Write-Host '########################################################'

    # -- Gate: caps must be usable numbers -----------------------------

    if ($null -eq $PrimaryCap -or $null -eq $OverflowCap) {
        $Result.Status = 'SKIPPED'
        $Result.Reason = 'PrimaryCap and OverflowCap must both be whole numbers greater than zero.'

        $capMessage = "SKIPPED. $($Result.Reason) " +
                      "Got PrimaryCap='$($Config.PrimaryCap)' OverflowCap='$($Config.OverflowCap)'."
        Write-RunLog -Unit $Name -Level Warn -Message $capMessage
        return
    }

    # -- Gate: nested groups -------------------------------------------

    if ($AbortOnNestedGroup) {
        $primaryNested  = Test-GroupHasNestedGroup -GroupId $PrimaryGroupId  -Unit $Name -Label 'E1'
        $overflowNested = Test-GroupHasNestedGroup -GroupId $OverflowGroupId -Unit $Name -Label 'EOP1'

        if ($primaryNested -or $overflowNested) {
            $Result.Status = 'SKIPPED'
            $Result.Reason = 'Nested group present. Seat counts cannot be trusted.'
            Write-RunLog -Unit $Name -Level Warn -Message "SKIPPED. $($Result.Reason)"
            return
        }
    }

    # -- Read both groups exactly once ---------------------------------

    $primaryUsers  = @(Get-GroupUsers -GroupId $PrimaryGroupId  -Unit $Name -Label 'E1')
    $overflowUsers = @(Get-GroupUsers -GroupId $OverflowGroupId -Unit $Name -Label 'EOP1')

    $Result.PrimaryBefore  = $primaryUsers.Count
    $Result.OverflowBefore = $overflowUsers.Count

    if ($primaryUsers.Count -eq 0) {
        $emptyMessage = 'E1 returned zero users. Confirm this is expected before trusting the plan below.'
        Write-RunLog -Unit $Name -Level Warn -Message $emptyMessage
    }

    # -- Build the population ------------------------------------------
    # A user present in both groups holds two licenses. They are treated as an
    # E1 incumbent and the duplicate EOP1 membership is removed.

    $population = @{}

    foreach ($user in $primaryUsers) {
        if (-not $population.ContainsKey($user.Id)) {
            $population[$user.Id] = [pscustomobject]@{
                Id         = $user.Id
                Upn        = $user.Upn
                Created    = $user.Created
                InPrimary  = $true
                InOverflow = $false
            }
        }
    }

    foreach ($user in $overflowUsers) {
        if ($population.ContainsKey($user.Id)) {
            $population[$user.Id].InOverflow = $true
        }
        else {
            $population[$user.Id] = [pscustomobject]@{
                Id         = $user.Id
                Upn        = $user.Upn
                Created    = $user.Created
                InPrimary  = $false
                InOverflow = $true
            }
        }
    }

    $allUsers = @($population.Values)

    # -- Gate: every user needs a usable CreatedDateTime ---------------
    # Ordering decides who gets trimmed. An unknown date must not be allowed to
    # place someone at either end of that order.

    $undated = @($allUsers | Where-Object { $null -eq $_.Created })

    if ($undated.Count -gt 0) {
        $Result.Status = 'SKIPPED'
        $Result.Reason = "$($undated.Count) user(s) have a missing or unparseable CreatedDateTime."
        Write-RunLog -Unit $Name -Level Warn -Message "SKIPPED. $($Result.Reason)"

        foreach ($user in $undated) {
            $undatedMessage = "  no CreatedDateTime: upn=$($user.Upn) userId=$($user.Id)"
            Write-RunLog -Unit $Name -Level Warn -Message $undatedMessage
        }
        return
    }

    # =================================================================
    # PLAN
    # =================================================================

    $capTotal = $PrimaryCap + $OverflowCap

    $populationMessage = "Population $($allUsers.Count) " +
                         "(E1 $($primaryUsers.Count), EOP1 $($overflowUsers.Count)). " +
                         "Total capacity $capTotal."
    Write-RunLog -Unit $Name -Message $populationMessage

    # Rule 3: trim the newest users beyond total capacity.
    $excess  = $allUsers.Count - $capTotal
    $trimSet = @()

    if ($excess -gt 0) {
        $trimSet = @((Sort-NewestFirst $allUsers) | Select-Object -First $excess)

        $trimMessage = "Population exceeds total capacity by $excess. " +
                       "Trimming the $excess newest user(s) out of both groups."
        Write-RunLog -Unit $Name -Level Warn -Message $trimMessage
    }

    $trimIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($user in $trimSet) { [void]$trimIds.Add($user.Id) }

    $remaining    = @($allUsers | Where-Object { -not $trimIds.Contains($_.Id) })
    $primaryHeld  = @($remaining | Where-Object { $_.InPrimary })
    $overflowHeld = @($remaining | Where-Object { -not $_.InPrimary -and $_.InOverflow })

    $demoteSet  = @()
    $promoteSet = @()

    if ($primaryHeld.Count -gt $PrimaryCap) {
        # Rule 1: newest E1 members spill down to EOP1.
        $demoteCount = $primaryHeld.Count - $PrimaryCap
        $demoteSet   = @((Sort-NewestFirst $primaryHeld) | Select-Object -First $demoteCount)

        $demoteMessage = "E1 holds $($primaryHeld.Count) against a cap of $PrimaryCap. " +
                         "Demoting the $demoteCount newest to EOP1."
        Write-RunLog -Unit $Name -Message $demoteMessage
    }
    elseif ($primaryHeld.Count -lt $PrimaryCap) {
        # Rule 2: newest EOP1 members are promoted into free E1 seats.
        $room         = $PrimaryCap - $primaryHeld.Count
        $promoteCount = [math]::Min($room, $overflowHeld.Count)

        if ($promoteCount -gt 0) {
            $promoteSet = @((Sort-NewestFirst $overflowHeld) | Select-Object -First $promoteCount)

            $promoteMessage = "E1 has $room free seat(s). Promoting the $promoteCount newest EOP1 user(s)."
            Write-RunLog -Unit $Name -Message $promoteMessage
        }
        else {
            $idleMessage = "E1 has $room free seat(s) and EOP1 has nobody to promote."
            Write-RunLog -Unit $Name -Message $idleMessage
        }
    }
    else {
        Write-RunLog -Unit $Name -Message "E1 is exactly at its cap of $PrimaryCap. No movement required."
    }

    # Duplicates staying put still need the extra membership stripped so they
    # stop consuming two licenses.
    $movingIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($user in $demoteSet)  { [void]$movingIds.Add($user.Id) }
    foreach ($user in $promoteSet) { [void]$movingIds.Add($user.Id) }

    $dedupeSet = @($remaining | Where-Object {
        $_.InPrimary -and $_.InOverflow -and -not $movingIds.Contains($_.Id)
    })

    if ($dedupeSet.Count -gt 0) {
        $dedupeMessage = "$($dedupeSet.Count) user(s) are in both groups. " +
                         'Keeping E1, removing the EOP1 membership.'
        Write-RunLog -Unit $Name -Level Warn -Message $dedupeMessage
    }

    $Result.PrimaryTarget  = $primaryHeld.Count - $demoteSet.Count + $promoteSet.Count
    $Result.OverflowTarget = $overflowHeld.Count + $demoteSet.Count - $promoteSet.Count

    # =================================================================
    # APPLY
    # =================================================================
    # Trims run first so EOP1 seats are free before a demotion adds anyone to
    # it. Every move adds to the destination before removing from the source,
    # and a failed add cancels its own removal, so no user is ever left holding
    # neither license. The plan is keyed by user id, so a user cannot appear in
    # more than one of these sets and cannot be processed twice.

    foreach ($user in $trimSet) {
        $from = @()
        if ($user.InPrimary)  { $from += 'E1' }
        if ($user.InOverflow) { $from += 'EOP1' }

        $reason = "population $($allUsers.Count) exceeds total capacity $capTotal by $excess; " +
                  'newest CreatedDateTime trimmed first'

        try {
            $detail = @()

            if ($user.InPrimary) {
                $outcome = Remove-UserFromGroup -GroupId $PrimaryGroupId -UserId $user.Id -Unit $Name -Label 'E1'
                $detail += "E1=$outcome"
            }
            if ($user.InOverflow) {
                $outcome = Remove-UserFromGroup -GroupId $OverflowGroupId -UserId $user.Id -Unit $Name -Label 'EOP1'
                $detail += "EOP1=$outcome"
            }

            $Result.Trimmed++

            Write-UserLog -Unit $Name -Action 'TRIM' -From ($from -join '+') -To 'none' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'OK' -Detail ($detail -join ',')
        }
        catch {
            $Result.Failures++

            Write-UserLog -Unit $Name -Action 'TRIM' -From ($from -join '+') -To 'none' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'FAILED' -Detail $_.Exception.Message
        }
    }

    foreach ($user in $demoteSet) {
        $reason = "E1 over cap $PrimaryCap; newest E1 member spills to EOP1"

        try {
            $addOutcome    = Add-UserToGroup -GroupId $OverflowGroupId -UserId $user.Id -Unit $Name -Label 'EOP1'
            $removeOutcome = Remove-UserFromGroup -GroupId $PrimaryGroupId -UserId $user.Id -Unit $Name -Label 'E1'

            $Result.Demoted++

            Write-UserLog -Unit $Name -Action 'MOVE' -From 'E1' -To 'EOP1' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'OK' -Detail "add=$addOutcome,remove=$removeOutcome"
        }
        catch {
            $Result.Failures++

            Write-UserLog -Unit $Name -Action 'MOVE' -From 'E1' -To 'EOP1' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'FAILED' -Detail $_.Exception.Message
        }
    }

    foreach ($user in $promoteSet) {
        $reason = "E1 below cap $PrimaryCap; newest EOP1 member promoted"

        try {
            $addOutcome    = Add-UserToGroup -GroupId $PrimaryGroupId -UserId $user.Id -Unit $Name -Label 'E1'
            $removeOutcome = Remove-UserFromGroup -GroupId $OverflowGroupId -UserId $user.Id -Unit $Name -Label 'EOP1'

            $Result.Promoted++

            Write-UserLog -Unit $Name -Action 'MOVE' -From 'EOP1' -To 'E1' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'OK' -Detail "add=$addOutcome,remove=$removeOutcome"
        }
        catch {
            $Result.Failures++

            Write-UserLog -Unit $Name -Action 'MOVE' -From 'EOP1' -To 'E1' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'FAILED' -Detail $_.Exception.Message
        }
    }

    foreach ($user in $dedupeSet) {
        $reason = 'user was a member of both groups; E1 retained as the higher license'

        try {
            $removeOutcome = Remove-UserFromGroup -GroupId $OverflowGroupId -UserId $user.Id -Unit $Name -Label 'EOP1'

            $Result.Deduped++

            Write-UserLog -Unit $Name -Action 'DEDUPE' -From 'E1+EOP1' -To 'E1' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'OK' -Detail "remove=$removeOutcome"
        }
        catch {
            $Result.Failures++

            Write-UserLog -Unit $Name -Action 'DEDUPE' -From 'E1+EOP1' -To 'E1' `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason $reason -Result 'FAILED' -Detail $_.Exception.Message
        }
    }

    if ($LogUnchangedUsers) {
        $touched = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($set in @($trimSet, $demoteSet, $promoteSet, $dedupeSet)) {
            foreach ($user in $set) { [void]$touched.Add($user.Id) }
        }

        foreach ($user in $allUsers) {
            if ($touched.Contains($user.Id)) { continue }

            $where = if ($user.InPrimary) { 'E1' } else { 'EOP1' }

            Write-UserLog -Unit $Name -Action 'STAY' -From $where -To $where `
                -Upn $user.Upn -UserId $user.Id -Created $user.Created `
                -Reason 'within cap; no rule applies' -Result 'OK'
        }
    }

    $Result.Status = if ($Result.Failures -gt 0) { 'COMPLETED_WITH_ERRORS' } else { 'OK' }

    Write-Host ''
    Write-RunLog -Unit $Name -Message '================ UNIT SUMMARY ================'
    Write-RunLog -Unit $Name -Message "E1      : $($Result.PrimaryBefore) -> $($Result.PrimaryTarget) (cap $PrimaryCap)"
    Write-RunLog -Unit $Name -Message "EOP1    : $($Result.OverflowBefore) -> $($Result.OverflowTarget) (cap $OverflowCap)"
    Write-RunLog -Unit $Name -Message "Promoted: $($Result.Promoted) into E1"
    Write-RunLog -Unit $Name -Message "Demoted : $($Result.Demoted) into EOP1"
    Write-RunLog -Unit $Name -Message "Trimmed : $($Result.Trimmed) removed from both groups"
    Write-RunLog -Unit $Name -Message "Deduped : $($Result.Deduped) duplicate membership(s) cleared"
    Write-RunLog -Unit $Name -Message "Failed  : $($Result.Failures)"

    if ($Result.Failures -gt 0) {
        $partialMessage = 'Target counts above are the plan, not the outcome. ' +
                          'Users whose move failed are still in their original group.'
        Write-RunLog -Unit $Name -Level Warn -Message $partialMessage
    }

    Write-RunLog -Unit $Name -Message '=============================================='
}

# =========================================================
# AUTHENTICATION
# =========================================================

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Groups

$secret = ConvertTo-SecureString $env:CLIENT_SECRET -AsPlainText -Force
$cred   = New-Object PSCredential($env:CLIENT_ID, $secret)

Connect-MgGraph `
    -TenantId $env:TENANT_ID `
    -ClientSecretCredential $cred `
    -NoWelcome

Write-RunLog -Message 'Connected to Microsoft Graph.'

$unitResults = New-Object 'System.Collections.Generic.List[object]'

try {

    # =====================================================
    # CONFIG VALIDATION (whole config, before any write)
    # =====================================================

    # @() normalises a single JSON object and a JSON array to the same shape.
    $configs = @($env:GROUP_CONFIG | ConvertFrom-Json)

    Write-RunLog -Message "Business Units Loaded : $($configs.Count)"

    if ($configs.Count -eq 0) {
        throw 'GROUP_CONFIG contained no business units.'
    }

    # A group id reused across business units would put two reconcilers in
    # charge of the same membership, each undoing the other. Fail the run before
    # touching anything rather than discover it halfway through.
    $seenGroupIds = @{}

    for ($i = 0; $i -lt $configs.Count; $i++) {
        $entry = $configs[$i]

        $entryLabel = [string](Get-Prop $entry 'Name')
        if ([string]::IsNullOrWhiteSpace($entryLabel)) { $entryLabel = "index $i" }

        foreach ($role in @('PrimaryGroupId', 'OverflowGroupId')) {
            $groupId = [string](Get-Prop $entry $role)

            if ([string]::IsNullOrWhiteSpace($groupId)) {
                throw "GROUP_CONFIG entry '$entryLabel' is missing $role."
            }

            $key = $groupId.Trim().ToLowerInvariant()

            if ($seenGroupIds.ContainsKey($key)) {
                throw ("GROUP_CONFIG reuses group id $groupId ('$entryLabel'.$role and " +
                       "$($seenGroupIds[$key])). Each group must belong to exactly one business unit.")
            }

            $seenGroupIds[$key] = "'$entryLabel'.$role"
        }
    }

    Write-RunLog -Message 'Config validated. No group id is shared between business units.'

    # =====================================================
    # PROCESS BUSINESS UNITS
    # =====================================================

    foreach ($config in $configs) {

        $unitName = [string](Get-Prop $config 'Name')
        if ([string]::IsNullOrWhiteSpace($unitName)) { $unitName = 'UNNAMED' }

        $result = [pscustomobject]@{
            Name           = $unitName
            Status         = 'PENDING'
            Reason         = ''
            PrimaryBefore  = 0
            OverflowBefore = 0
            PrimaryTarget  = 0
            OverflowTarget = 0
            Promoted       = 0
            Demoted        = 0
            Trimmed        = 0
            Deduped        = 0
            Failures       = 0
        }
        $unitResults.Add($result)

        try {
            Invoke-BusinessUnitReconcile -Config $config -Result $result | Out-Null
        }
        catch {
            # One business unit failing must not stop the others.
            $result.Status = 'FAILED'
            $result.Reason = $_.Exception.Message

            Write-RunLog -Unit $unitName -Level Warn -Message "FAILED. $($_.Exception.Message)"
            Write-RunLog -Unit $unitName -Level Warn -Message 'Remaining business units will still be processed.'
        }
    }
}
finally {
    try {
        Disconnect-MgGraph | Out-Null
    }
    catch {
        # Nothing useful to do if the disconnect itself fails.
    }
}

# =========================================================
# RUN SUMMARY
# =========================================================

$countOk      = @($unitResults | Where-Object { $_.Status -eq 'OK' }).Count
$countPartial = @($unitResults | Where-Object { $_.Status -eq 'COMPLETED_WITH_ERRORS' }).Count
$countSkipped = @($unitResults | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$countFailed  = @($unitResults | Where-Object { $_.Status -eq 'FAILED' }).Count

Write-Host ''
Write-Host '=========================================================='
Write-RunLog -Message 'ABFRL LICENSE BALANCER RUN SUMMARY'
Write-RunLog -Message "Business Units : $($unitResults.Count)"
Write-RunLog -Message "OK             : $countOk"
Write-RunLog -Message "With Errors    : $countPartial"
Write-RunLog -Message "Skipped        : $countSkipped"
Write-RunLog -Message "Failed         : $countFailed"

foreach ($unit in $unitResults) {
    $summaryLine = "  $($unit.Name.PadRight(20)) $($unit.Status.PadRight(22)) " +
                   "E1 $($unit.PrimaryBefore)->$($unit.PrimaryTarget)  " +
                   "EOP1 $($unit.OverflowBefore)->$($unit.OverflowTarget)  " +
                   "promoted=$($unit.Promoted) demoted=$($unit.Demoted) " +
                   "trimmed=$($unit.Trimmed) deduped=$($unit.Deduped) failures=$($unit.Failures)"

    Write-Host $summaryLine

    if ($unit.Reason) {
        Write-Host "      reason: $($unit.Reason)"
    }
}

Write-RunLog -Message "Started  : $StartTime"
Write-RunLog -Message "Finished : $(Get-Date)"
Write-Host '=========================================================='

# Surfacing a non-zero exit to the Functions host so failures are visible in
# invocation history instead of being buried in log text.
if ($countFailed -gt 0 -or $countPartial -gt 0) {
    throw "Run $RunId finished with $countFailed failed and $countPartial partially completed business unit(s). See the log above."
}