#Requires -Version 5.1
<#
.SYNOPSIS
    Controleert de identity-voorwaarden voor Azure Local small form factor (preview).

.DESCRIPTION
    Checkt voor het account waarmee je via 'az login' bent ingelogd:
      1. Azure RBAC     - Owner, of Contributor + Role Based Access Control Administrator,
                          actief EN permanent op de subscription (of opgegeven resource group).
                          PIM-eligible rollen worden gemeld, maar tellen niet als actief.
      2. Entra-rol      - minimaal Directory Readers (of een rol met meer rechten).
      3. Operator-groep - de Entra security group bestaat, is security-enabled en heeft leden.

    az CLI wordt alleen gebruikt voor de login-context en tokens; de checks zelf zijn
    REST-calls naar ARM en Microsoft Graph. Werkt in Windows PowerShell 5.1 en PowerShell 7.
    Exit code 1 als er een FAIL is, anders 0.

.PARAMETER SubscriptionId
    Subscription waarin je gaat provisionen.

.PARAMETER ResourceGroup
    Optioneel. Resource group waarin je de provisioned machines aanmaakt. Zonder deze
    parameter (of als de RG nog niet bestaat) wordt op subscription-niveau gecontroleerd.

.PARAMETER OperatorGroup
    Naam of object-ID van de Entra security group voor operators.

.PARAMETER AcceptedDirectoryRoles
    Entra-rollen die gelden als "minimaal Directory Readers". Pas aan naar wens.

.EXAMPLE
    .\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -OperatorGroup 'sg-azlocal-sff-operators'

.EXAMPLE
    .\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup 'rg-sff-lab' -OperatorGroup '11111111-2222-3333-4444-555555555555'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$OperatorGroup,
    [string[]]$AcceptedDirectoryRoles = @(
        'Directory Readers', 'Global Reader', 'Global Administrator', 'Directory Writers',
        'Cloud Application Administrator', 'Application Administrator', 'Privileged Role Administrator'
    )
)

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

#region Helpers
$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Detail
    )
    $script:Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Cyan' }[$Status]
    Write-Host ('[{0}] {1}: {2}' -f $Status, $Check, $Detail) -ForegroundColor $color
}

function Get-AzCliToken {
    param([string]$Resource)
    $token = az account get-access-token --subscription $SubscriptionId --resource $Resource --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "Geen token voor $Resource. Log in met 'az login' (eventueel met --tenant <tenant-id>) en probeer opnieuw."
    }
    return $token
}

function Invoke-Paged {
    param([string]$Uri, [string]$Token)
    $headers = @{ Authorization = "Bearer $Token" }
    $items = @()
    while ($Uri) {
        $response = Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -ErrorAction Stop
        if ($null -ne $response.value) { $items += @($response.value) }
        $Uri = if ($response.'@odata.nextLink') { $response.'@odata.nextLink' }
               elseif ($response.nextLink)      { $response.nextLink }
               else                             { $null }
    }
    return $items
}

function Get-RoleGuid {
    param([string]$RoleDefinitionId)
    return ([string]$RoleDefinitionId -split '/')[-1].ToLower()
}

function Test-ScopeApplies {
    # True als een assignment op $AssignmentScope doorwerkt naar $TargetScope (zelfde scope of erboven).
    param([string]$AssignmentScope, [string]$TargetScope)
    if (-not $AssignmentScope) { return $false }
    $s = $AssignmentScope.TrimEnd('/')
    if (-not $s) { return $true }                                                         # root '/'
    if ($s -like '/providers/Microsoft.Management/managementGroups/*') { return $true }  # erft door
    return ($TargetScope -eq $s) -or $TargetScope.StartsWith("$s/", [StringComparison]::OrdinalIgnoreCase)
}
#endregion

#region Context
Write-Host "`nAzure Local SFF - prerequisite check`n" -ForegroundColor White

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) niet gevonden.' }

$accountJson = az account show --subscription $SubscriptionId -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
    throw "Subscription $SubscriptionId niet gevonden in je az-context. Draai 'az login' (eventueel met --tenant <tenant-id>)."
}
$account = ($accountJson -join "`n") | ConvertFrom-Json

$armToken     = Get-AzCliToken 'https://management.azure.com/'
$graphToken   = Get-AzCliToken 'https://graph.microsoft.com'
$armHeaders   = @{ Authorization = "Bearer $armToken" }
$graphHeaders = @{ Authorization = "Bearer $graphToken" }
$arm = 'https://management.azure.com'
$g   = 'https://graph.microsoft.com/v1.0'

try {
    if ($account.user.type -eq 'servicePrincipal') {
        $principal = Invoke-RestMethod -ErrorAction Stop -Headers $graphHeaders `
            -Uri "$g/servicePrincipals(appId='$($account.user.name)')?`$select=id,displayName"
        $principalPath = "servicePrincipals/$($principal.id)"
        $principalName = $principal.displayName
    } else {
        $principal = Invoke-RestMethod -ErrorAction Stop -Headers $graphHeaders `
            -Uri "$g/me?`$select=id,displayName,userPrincipalName"
        $principalPath = "users/$($principal.id)"
        $principalName = $principal.userPrincipalName
    }
} catch {
    throw "Kon je eigen account niet opvragen in Microsoft Graph: $($_.Exception.Message)"
}
$principalId = $principal.id

$subScope    = "/subscriptions/$SubscriptionId"
$targetScope = $subScope
if ($ResourceGroup) {
    try {
        Invoke-RestMethod -ErrorAction Stop -Headers $armHeaders `
            -Uri "$arm$subScope/resourcegroups/$($ResourceGroup)?api-version=2021-04-01" | Out-Null
        $targetScope = "$subScope/resourceGroups/$ResourceGroup"
    } catch {
        Add-Result 'Scope' 'INFO' "Resource group '$ResourceGroup' niet gevonden of niet leesbaar; RBAC wordt op subscription-niveau gecontroleerd."
    }
}

Write-Host "Account      : $principalName ($principalId)"
Write-Host "Subscription : $($account.name) ($SubscriptionId)"
Write-Host "Tenant       : $($account.tenantId)"
Write-Host "Scope        : $targetScope`n"
#endregion

#region 1. Azure RBAC
$roleIds = [ordered]@{
    'Owner'                                   = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    'Contributor'                             = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    'Role Based Access Control Administrator' = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
    'User Access Administrator'               = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
}

# Actieve assignments (direct + via groepen), op of boven de doel-scope
$rbacReadOk = $true
try {
    $assignments = @(@(Invoke-Paged -Token $armToken `
        -Uri "$arm$targetScope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$principalId')") |
        Where-Object { Test-ScopeApplies $_.properties.scope $targetScope })
} catch {
    $rbacReadOk = $false
    $rbacError  = $_.Exception.Message
}

# PIM schedule-instances: onderscheid permanent vs. tijdelijk (activatie of tijdgebonden)
$scheduleOk = $true
try {
    $instances = @(@(Invoke-Paged -Token $armToken `
        -Uri "$arm$targetScope/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01&`$filter=asTarget()") |
        Where-Object { Test-ScopeApplies $_.properties.scope $targetScope })
} catch {
    $scheduleOk = $false
    $instances  = @()
}

# PIM-eligible (nog niet geactiveerd)
try {
    $eligible = @(@(Invoke-Paged -Token $armToken `
        -Uri "$arm$targetScope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=asTarget()") |
        Where-Object { Test-ScopeApplies $_.properties.scope $targetScope })
} catch {
    $eligible = @()
}

if (-not $rbacReadOk) {
    # Geen leesrechten op role assignments = geen enkele actieve rol op deze scope. Meld wel wat eligible is.
    $eligNames = @($roleIds.Keys | Where-Object {
        $guid = $roleIds[$_]
        @($eligible | Where-Object { (Get-RoleGuid $_.properties.roleDefinitionId) -eq $guid }).Count
    })
    $hint = if ($eligNames.Count) { " Eligible in PIM: $($eligNames -join ', ') - activeer die eerst." } else { '' }
    Add-Result 'Azure RBAC' 'FAIL' "Kon role assignments niet lezen op $targetScope (waarschijnlijk geen actieve rol).$hint Fout: $rbacError"
}

function Get-RoleState {
    param([string]$RoleGuid)
    $hits = @($assignments | Where-Object { (Get-RoleGuid $_.properties.roleDefinitionId) -eq $RoleGuid })
    $elig = @($eligible    | Where-Object { (Get-RoleGuid $_.properties.roleDefinitionId) -eq $RoleGuid })

    if ($hits.Count -eq 0) {
        if ($elig.Count -gt 0) { return [pscustomobject]@{ State = 'Eligible'; Detail = 'alleen eligible in PIM, niet geactiveerd' } }
        return [pscustomobject]@{ State = 'None'; Detail = '-' }
    }

    $where = (@($hits | ForEach-Object { $_.properties.scope }) | Select-Object -Unique) -join ', '
    if (-not $scheduleOk) {
        return [pscustomobject]@{ State = 'Active'; Detail = "actief op $where (permanent/tijdelijk niet te bepalen)" }
    }

    $inst = @($instances | Where-Object { (Get-RoleGuid $_.properties.roleDefinitionId) -eq $RoleGuid })
    $perm = @($inst | Where-Object { $_.properties.assignmentType -eq 'Assigned' -and -not $_.properties.endDateTime })
    if ($perm.Count -gt 0) {
        $via = (@($perm | ForEach-Object { $_.properties.memberType }) | Select-Object -Unique) -join '/'
        return [pscustomobject]@{ State = 'Permanent'; Detail = "permanent op $where (via: $via)" }
    }

    $end = @($inst | Where-Object { $_.properties.endDateTime } |
             ForEach-Object { [datetime]$_.properties.endDateTime } | Sort-Object -Descending) | Select-Object -First 1
    if ($end) {
        return [pscustomobject]@{ State = 'TimeBound'; Detail = "actief tot $($end.ToLocalTime().ToString('yyyy-MM-dd HH:mm')) (PIM-activatie of tijdgebonden)" }
    }
    return [pscustomobject]@{ State = 'Active'; Detail = "actief op $where (geen schedule-informatie gevonden)" }
}

if ($rbacReadOk) {
    $state = [ordered]@{}
    foreach ($name in $roleIds.Keys) {
        $state[$name] = Get-RoleState $roleIds[$name]
        Write-Host ('       {0,-42} {1,-10} {2}' -f $name, $state[$name].State, $state[$name].Detail) -ForegroundColor DarkGray
    }

    $activeStates = 'Permanent', 'TimeBound', 'Active'
    function Test-State([string]$Role, [string[]]$States) { return $state[$Role].State -in $States }

    if (Test-State 'Owner' 'Permanent') {
        Add-Result 'Azure RBAC' 'PASS' 'Owner, permanent actief'
    }
    elseif ((Test-State 'Contributor' 'Permanent') -and (Test-State 'Role Based Access Control Administrator' 'Permanent')) {
        Add-Result 'Azure RBAC' 'PASS' 'Contributor + RBAC Administrator, permanent actief'
    }
    elseif ((Test-State 'Owner' $activeStates) -or
            ((Test-State 'Contributor' $activeStates) -and (Test-State 'Role Based Access Control Administrator' $activeStates))) {
        Add-Result 'Azure RBAC' 'WARN' 'Juiste rol(len) actief, maar niet permanent of niet te verifieren. Werkt zolang de activatie loopt; de docs vragen active + permanent.'
    }
    elseif ((Test-State 'Contributor' $activeStates) -and (Test-State 'User Access Administrator' $activeStates)) {
        Add-Result 'Azure RBAC' 'WARN' 'Contributor + User Access Administrator: vergelijkbare rechten, maar niet de gedocumenteerde combinatie (RBAC Administrator).'
    }
    else {
        $eligNames = @($state.Keys | Where-Object { $state[$_].State -eq 'Eligible' })
        $hint = if ($eligNames.Count) { " Eligible in PIM: $($eligNames -join ', ') - activeer die eerst." } else { '' }
        Add-Result 'Azure RBAC' 'FAIL' "Geen Owner of Contributor + RBAC Administrator op $targetScope.$hint"
    }
}
#endregion

#region 2. Entra directory-rol
try {
    try {
        $dirRoles = @(Invoke-Paged -Token $graphToken -Uri "$g/$principalPath/transitiveMemberOf/microsoft.graph.directoryRole?`$select=displayName")
    } catch {
        # Fallback als de type-cast niet wordt ondersteund
        $dirRoles = @(@(Invoke-Paged -Token $graphToken -Uri "$g/$principalPath/transitiveMemberOf") |
                      Where-Object { $_.'@odata.type' -eq '#microsoft.graph.directoryRole' })
    }

    $roleNames = @($dirRoles | ForEach-Object { $_.displayName } | Sort-Object -Unique)
    $match     = @($roleNames | Where-Object { $_ -in $AcceptedDirectoryRoles })

    if ($match.Count) {
        Add-Result 'Entra-rol' 'PASS' "Actief: $($match -join ', ')"
    } else {
        # PIM-eligible directory-rollen; lukt niet met elk az CLI-token, dan wordt dit overgeslagen
        $eligDir = @()
        try {
            $eligDir = @(@(Invoke-Paged -Token $graphToken `
                -Uri "$g/roleManagement/directory/roleEligibilityScheduleInstances?`$filter=principalId eq '$principalId'&`$expand=roleDefinition") |
                ForEach-Object { $_.roleDefinition.displayName } | Where-Object { $_ -in $AcceptedDirectoryRoles } | Sort-Object -Unique)
        } catch { }

        $other = if ($roleNames.Count) { " Wel actief: $($roleNames -join ', ')." } else { ' Geen actieve Entra-rollen gevonden.' }
        if ($eligDir.Count) {
            Add-Result 'Entra-rol' 'WARN' "Eligible in PIM: $($eligDir -join ', ') - activeer voor het provisionen.$other"
        } else {
            Add-Result 'Entra-rol' 'FAIL' "Geen Directory Readers of hogere rol.$other"
        }
    }
} catch {
    Add-Result 'Entra-rol' 'FAIL' "Kon Entra-rollen niet lezen: $($_.Exception.Message)"
}
#endregion

#region 3. Operator security group
if (-not $OperatorGroup) {
    Add-Result 'Operator-groep' 'WARN' "Geen -OperatorGroup opgegeven. Draai opnieuw met -OperatorGroup '<naam of object-id>'."
} else {
    try {
        $select = 'id,displayName,securityEnabled,mailEnabled,groupTypes'
        if ($OperatorGroup -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            $groups = @(Invoke-RestMethod -ErrorAction Stop -Headers $graphHeaders -Uri "$g/groups/$($OperatorGroup)?`$select=$select")
        } else {
            $filter = [uri]::EscapeDataString("displayName eq '$($OperatorGroup.Replace("'", "''"))'")
            $groups = @(Invoke-Paged -Token $graphToken -Uri "$g/groups?`$filter=$filter&`$select=$select")
        }

        if ($groups.Count -eq 0) {
            Add-Result 'Operator-groep' 'FAIL' "Groep '$OperatorGroup' niet gevonden."
        }
        elseif ($groups.Count -gt 1) {
            Add-Result 'Operator-groep' 'WARN' "Meerdere groepen heten '$OperatorGroup': $(@($groups.id) -join ', '). Geef de object-ID op."
        }
        else {
            $grp     = $groups[0]
            $label   = "$($grp.displayName) ($($grp.id))"
            $members = @(Invoke-Paged -Token $graphToken -Uri "$g/groups/$($grp.id)/transitiveMembers?`$select=id&`$top=999")

            $memberCheck = Invoke-RestMethod -ErrorAction Stop -Method Post -Headers $graphHeaders -ContentType 'application/json' `
                -Uri "$g/$principalPath/checkMemberGroups" -Body (@{ groupIds = @($grp.id) } | ConvertTo-Json)
            $iAmMember = @($memberCheck.value) -contains $grp.id
            $isM365    = @($grp.groupTypes) -contains 'Unified'

            if (-not $grp.securityEnabled) {
                Add-Result 'Operator-groep' 'FAIL' "$label is geen security group (securityEnabled = false)."
            }
            elseif ($members.Count -eq 0) {
                Add-Result 'Operator-groep' 'WARN' "$label bestaat, maar heeft geen leden."
            }
            else {
                $type = if ($isM365) { 'Microsoft 365-groep (security-enabled)' } else { 'security group' }
                Add-Result 'Operator-groep' 'PASS' "$label - $type, $($members.Count) (transitieve) leden"
            }

            if (-not $iAmMember) {
                Add-Result 'Operator-groep' 'WARN' "$principalName is geen lid van deze groep; voeg jezelf toe als je de machine zelf wilt beheren of benaderen."
            }
        }
    } catch {
        Add-Result 'Operator-groep' 'FAIL' "Kon groep niet opvragen: $($_.Exception.Message)"
    }
}
#endregion

#region Samenvatting
Write-Host ''
# Vaste breedte, zodat de tabel ook verschijnt als de output wordt omgeleid (log, CI, scheduled task)
Write-Host ($script:Results | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd()
Write-Host ''

$fails = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warns = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count

if ($fails) {
    Write-Host "$fails check(s) gefaald, $warns waarschuwing(en)." -ForegroundColor Red
    exit 1
} elseif ($warns) {
    Write-Host "Geen blokkers, $warns waarschuwing(en)." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host 'Alles in orde - klaar voor de volgende stap.' -ForegroundColor Green
    exit 0
}
#endregion
