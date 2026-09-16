<#
.SYNOPSIS
  Sets Copilot Credit allocations and tenant-pool access for multiple environments at once.

.DESCRIPTION
  In PPAC, allocations are configured one environment at a time. This script
  performs the same operation through the API in a loop.

  Endpoint: PUT https://api.powerplatform.com/licensing/allocationsV2
  Entitlement: MCSMessages (= Copilot Credits)
  TenantPool enforcement rule:
    enabled = $false  -> the environment stops when it reaches its own allocation
    enabled = $true   -> the environment continues using the tenant's unallocated pool

.NOTES
  DRY RUN IS THE DEFAULT. Add -Apply when you want to write changes.

  Run this from your own computer, not a server.

.EXAMPLE
  # 0. Dry run for ALL environments, without an app registration.
  #    Install the Az PowerShell module without administrator privileges:
  Install-Module Az.Accounts -Scope CurrentUser
  Connect-AzAccount -TenantId <tenantId>
  .\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments

.EXAMPLE
  # If execution is interrupted by a network outage, resume where it left off:
  .\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments -Quantity 1000 -Apply -Resume

.EXAMPLE
  # 1. Set a limit of 1000 for all environments.
  .\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments -Quantity 1000 -Apply

.EXAMPLE
  # 1. View the current state without writing any changes.
  .\Set-CopilotCreditCaps.ps1 -ClientId <id> -TenantId <id> -EnvironmentCsv .\envs.csv

  # 2. Disable tenant-pool access for all listed environments and set allocation to 0.
  #    Tenant-pool access is disabled by default.
  .\Set-CopilotCreditCaps.ps1 -ClientId <id> -TenantId <id> -EnvironmentCsv .\envs.csv -Quantity 0 -Apply

  # 3. Allocate 5000 to one environment and enforce that limit.
  .\Set-CopilotCreditCaps.ps1 -ClientId <id> -TenantId <id> -EnvironmentId <envId> -Quantity 5000 -Apply
#>
[CmdletBinding()]
param(
    [string]$ClientId,                       # App registration (Power Platform API).
    [string]$TenantId,
    [switch]$UseAzCli,                       # Option 1: obtain a token from Azure CLI (az).
    [switch]$UseAzModule,                    # Option 2: obtain a token from the Az PowerShell module.
                                             #   Install-Module Az.Accounts -Scope CurrentUser
                                             #   (No administrator privileges or app registration required.)
    [string]$EnvironmentCsv,                 # Columns: environmentId and optional name.
    [string]$EnvironmentId,                  # Alternatively, specify a single environment.
    [switch]$AllEnvironments,                # Alternatively, retrieve all environments in the tenant.
    [int]$Quantity = 0,                      # 0 = no allocation by default.
    [bool]$AllowTenantPool = $false,         # $false = do not draw from the tenant pool.
    [switch]$Apply,                          # Without this switch, no changes are written.
    [int]$DelayMs = 400,                     # Delay to reduce the risk of throttling.
    [int]$TimeoutSec = 60,                   # Timeout for an individual request.
    [int]$Retries = 3,                       # Retry attempts for network interruptions.
    [string]$StateFile = ".\copilot-caps-state.txt",  # Successfully processed environments.
    [switch]$Resume                          # Skip environments that have already been processed.
)

$apiBase    = "https://api.powerplatform.com"
$apiVersion = "2024-10-01"

# A network outage stalled execution on August 26, 2026: Invoke-RestMethod without
# a timeout can wait indefinitely. All requests now go through this wrapper.
function Invoke-PpRest {
    # Invoke a REST request with a timeout and retry handling.
    # Example: Invoke-PpRest -Method Get -Uri $availabilityUri -Headers $headers
    param($Method, $Uri, $Headers, $Body)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = $TimeoutSec }
            if ($Body) { $p.Body = $Body; $p.ContentType = "application/json" }
            return Invoke-RestMethod @p
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            # Retrying will not resolve 4xx errors other than 429.
            if ($status -and $status -ge 400 -and $status -lt 500 -and $status -ne 429) { throw }
            if ($i -eq $Retries) { throw }
            $wait = [Math]::Pow(2, $i)
            Write-Host ("    attempt {0}/{1} failed; waiting {2}s" -f $i, $Retries, $wait) -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }
    }
}

# --- Token ------------------------------------------------------------------
# Three authentication methods. UseAzModule and UseAzCli do not require
# your own app registration.

function Get-PpToken {
    # Obtain an access token using the selected authentication method.
    # Example: Get-PpToken -Resource "https://api.powerplatform.com"
    param([string]$Resource)
    if ($UseAzModule) {
        $t = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop
        # Newer Az versions return a SecureString.
        if ($t.Token -is [System.Security.SecureString]) {
            return [System.Net.NetworkCredential]::new("", $t.Token).Password
        }
        return $t.Token
    }
    elseif ($UseAzCli) {
        return az account get-access-token --resource $Resource --query accessToken -o tsv
    }
    else {
        $a = Get-MsalToken -ClientId $ClientId -TenantId $TenantId `
                           -Scope "$Resource/.default" -Interactive
        return $a.AccessToken
    }
}

if ($UseAzModule) {
    Import-Module Az.Accounts -ErrorAction Stop
    if (-not (Get-AzContext)) {
        if ($TenantId) { Connect-AzAccount -TenantId $TenantId | Out-Null }
        else           { Connect-AzAccount | Out-Null }
    }
    Write-Host "Retrieving a token from the Az PowerShell module..." -ForegroundColor Cyan
    $token = Get-PpToken -Resource "https://api.powerplatform.com"
    if (-not $token) { throw "Could not obtain a token. Run: Connect-AzAccount -TenantId <tenantId>" }
}
elseif ($UseAzCli) {
    Write-Host "Retrieving a token from Azure CLI..." -ForegroundColor Cyan
    Write-Host "Retrieving a token from Azure CLI..." -ForegroundColor Cyan
    $token = Get-PpToken -Resource "https://api.powerplatform.com"
    if (-not $token) { throw "az did not return a token. First run: az login --tenant <tenantId>" }
} else {
    if (-not $ClientId -or -not $TenantId) {
        throw "Specify -ClientId and -TenantId, or use -UseAzModule / -UseAzCli."
    }
    Import-Module MSAL.PS -ErrorAction Stop   # Install-Module MSAL.PS -Scope CurrentUser
    $token = Get-PpToken -Resource "https://api.powerplatform.com"
}
$headers = @{ Authorization = "Bearer $token" }

# --- Connection test: detect permission or Conditional Access blocks early ---
try {
    $null = Invoke-PpRest -Method Get -Headers $headers `
            -Uri "$apiBase/licensing/allocationsV2/availability?api-version=$apiVersion&`$filter=$([uri]::EscapeDataString("EntitlementId in ('MCSMessages')"))"
    Write-Host "API connection OK.`n" -ForegroundColor Green
} catch {
    Write-Host "Connection test: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "(404 is normal if the filter has no match; 401/403 indicates a permissions or Conditional Access block.)`n"
}

# --- Environment list -------------------------------------------------------
$targets = @()
if ($EnvironmentCsv) {
    $targets = Import-Csv $EnvironmentCsv
} elseif ($EnvironmentId) {
    $targets = @([pscustomobject]@{ environmentId = $EnvironmentId; name = $EnvironmentId })
} elseif ($AllEnvironments) {
    # Listing environments uses a separate API (BAP) and requires its own token.
    Write-Host "Retrieving all environments in the tenant..." -ForegroundColor Cyan
    $bapToken = Get-PpToken -Resource "https://api.bap.microsoft.com/"
    if (-not $bapToken) { throw "Could not obtain a token for the environment list." }
    $bapHeaders = @{ Authorization = "Bearer $bapToken" }
    $envs = Invoke-PpRest -Method Get -Headers $bapHeaders `
        -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01"
    $targets = $envs.value | ForEach-Object {
        [pscustomobject]@{
            environmentId = $_.name
            name          = $_.properties.displayName
            type          = $_.properties.environmentSku
        }
    }
    Write-Host "Found $($targets.Count) environments.`n" -ForegroundColor Cyan
} else {
    throw "Specify -AllEnvironments, -EnvironmentCsv, or -EnvironmentId."
}
Write-Host "Environments: $($targets.Count)   Quantity: $Quantity   TenantPool: $AllowTenantPool" -ForegroundColor Cyan
if (-not $Apply) { Write-Host "DRY RUN - no changes will be written. Add -Apply to write changes.`n" -ForegroundColor Yellow }

# --- Resume an interrupted run ----------------------------------------------
$done = @()
if ($Resume -and (Test-Path $StateFile)) {
    $done = Get-Content $StateFile | Where-Object { $_ }
    Write-Host "Resuming: $($done.Count) environments have already been processed and will be skipped.`n" -ForegroundColor Cyan
}

$ok = 0; $fail = 0; $skipped = 0; $already = 0

foreach ($t in $targets) {
    $envId = $t.environmentId
    $name  = if ($t.name) { $t.name } else { $envId }
    if (-not $envId) { continue }
    if ($Resume -and $done -contains $envId) { $already++; continue }

    # --- 1. Current state: quantity available for allocation ----------------
    $available = "?"
    try {
        $filter = [uri]::EscapeDataString("environmentId eq '$envId' and EntitlementId in ('MCSMessages')")
        $a = Invoke-PpRest -Method Get -Headers $headers `
             -Uri "$apiBase/licensing/allocationsV2/availability?api-version=$apiVersion&`$filter=$filter"
        $mcs = $a.entitlementAllocationsAvailable | Where-Object { $_.entitlementId -eq 'MCSMessages' }
        if ($mcs) { $available = $mcs.availableQuantity }
    } catch {
        $available = "n/a"   # 404 = no allocation exists, which is useful information itself.
    }

    if (-not $Apply) {
        $t = if ($t.type) { $t.type } else { "" }
        Write-Host ("  (dry run) {0,-38} {1,-12} available for allocation: {2}" -f `
            $name.Substring(0,[Math]::Min(38,$name.Length)), $t, $available)
        $skipped++
        continue
    }

    # --- 2. Write the allocation --------------------------------------------
    $body = @{
        scope = @{ environmentId = $envId }
        allocatedEntitlements = @(
            @{
                entitlementId    = "MCSMessages"
                allocation       = @{ quantity = $Quantity }
                enforcementRules = @(
                    @{ ruleType = "TenantPool"; enabled = $AllowTenantPool }
                )
            }
        )
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-PpRest -Method Put -Headers $headers `
            -Uri "$apiBase/licensing/allocationsV2?api-version=$apiVersion" -Body $body | Out-Null
        Add-Content -Path $StateFile -Value $envId
        Write-Host ("  OK    {0,-42} quantity={1} tenantPool={2}" -f `
            $name.Substring(0,[Math]::Min(42,$name.Length)), $Quantity, $AllowTenantPool) -ForegroundColor Green
        $ok++
    } catch {
        Write-Host ("  FAIL  {0,-42} {1}" -f `
            $name.Substring(0,[Math]::Min(42,$name.Length)), $_.Exception.Message) -ForegroundColor Red
        $fail++
    }
    Start-Sleep -Milliseconds $DelayMs
}

Write-Host ""
if ($Apply) {
    Write-Host "Done: $ok succeeded, $fail failed$(if($already){", $already skipped (already processed)"})." -ForegroundColor Cyan
    Write-Host "Processed environments: $StateFile  (resume an interrupted run with -Resume)" -ForegroundColor DarkGray
}
else        { Write-Host "Dry run: reviewed $skipped environments; no changes were made." -ForegroundColor Yellow }
