<#
.SYNOPSIS
  Asettaa Copilot Credit -allokaation ja tenant-vedon monelle ymparistolle kerralla.

.DESCRIPTION
  PPAC:ssa allokaatio tehdaan yksi ymparisto kerrallaan. Tama tekee saman
  rajapinnan kautta silmukassa.

  Rajapinta: PUT https://api.powerplatform.com/licensing/allocationsV2
  Entitlement: MCSMessages (= Copilot Credits)
  Enforcement rule TenantPool:
    enabled = $false  -> ymparisto pysahtyy omaan allokaatioonsa
    enabled = $true   -> ymparisto jatkaa tenantin allokoimattomasta poolista

.NOTES
  KUIVAHARJOITUS ON OLETUS. Lisaa -Apply kun haluat kirjoittaa.

  Aja omalta koneelta, ei palvelimelta.

.EXAMPLE
  # 0. Kuivaharjoitus KAIKILLE ymparistoille, ilman app registrationia.
  #    Az PowerShell -moduuli asentuu ilman admin-oikeuksia:
  Install-Module Az.Accounts -Scope CurrentUser
  Connect-AzAccount -TenantId <tenantId>
  .\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments

.EXAMPLE
  # Jos ajo katkeaa kesken (verkkokatko), jatka siita mihin jai:
  .\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments -Quantity 1000 -Apply -Resume

.EXAMPLE
  # 1. Aseta raja 1000 kaikkiin ymparistoihin
  .\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments -Quantity 1000 -Apply

.EXAMPLE
  # 1. Katso nykytila kirjoittamatta mitaan
  .\Set-CopilotCreditCaps.ps1 -ClientId <id> -TenantId <id> -EnvironmentCsv .\envs.csv

  # 2. Sulje tenant-veto kaikilta, allokaatio 0 (oletuksena kiinni)
  .\Set-CopilotCreditCaps.ps1 -ClientId <id> -TenantId <id> -EnvironmentCsv .\envs.csv -Quantity 0 -Apply

  # 3. Anna yhdelle ymparistolle 5000 ja pida se katossa
  .\Set-CopilotCreditCaps.ps1 -ClientId <id> -TenantId <id> -EnvironmentId <envId> -Quantity 5000 -Apply
#>
[CmdletBinding()]
param(
    [string]$ClientId,                       # app registration (Power Platform API)
    [string]$TenantId,
    [switch]$UseAzCli,                       # vaihtoehto 1: token Azure CLI:sta (az)
    [switch]$UseAzModule,                    # vaihtoehto 2: token Az PowerShell -moduulista
                                             #   Install-Module Az.Accounts -Scope CurrentUser
                                             #   (ei vaadi admin-oikeuksia eika app registrationia)
    [string]$EnvironmentCsv,                 # sarake: environmentId (ja valinnainen name)
    [string]$EnvironmentId,                  # tai yksi ymparisto
    [switch]$AllEnvironments,                # tai hae kaikki tenantista
    [int]$Quantity = 0,                      # 0 = kiinni oletuksena
    [bool]$AllowTenantPool = $false,         # $false = ei vetoa tenantin poolista
    [switch]$Apply,                          # ilman tata ei kirjoiteta mitaan
    [int]$DelayMs = 400,                     # kuristussuoja
    [int]$TimeoutSec = 60,                   # yksittaisen kutsun aikakatkaisu
    [int]$Retries = 3,                       # uudelleenyritykset verkkokatkoon
    [string]$StateFile = ".\copilot-caps-state.txt",  # tehdyt ymparistot
    [switch]$Resume                          # ohita ne jotka on jo tehty
)

$apiBase    = "https://api.powerplatform.com"
$apiVersion = "2024-10-01"

# Verkkokatko jumitti ajon 26.8.2026: Invoke-RestMethod ilman aikakatkaisua jaa
# odottamaan loputtomiin. Kaikki kutsut menevat nyt taman kaaren lapi.
function Invoke-PpRest {
    param($Method, $Uri, $Headers, $Body)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = $TimeoutSec }
            if ($Body) { $p.Body = $Body; $p.ContentType = "application/json" }
            return Invoke-RestMethod @p
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            # 4xx muut kuin 429 eivat parane uudelleenyrityksesta
            if ($status -and $status -ge 400 -and $status -lt 500 -and $status -ne 429) { throw }
            if ($i -eq $Retries) { throw }
            $wait = [Math]::Pow(2, $i)
            Write-Host ("    yritys {0}/{1} epaonnistui, odotetaan {2}s" -f $i, $Retries, $wait) -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }
    }
}

# --- token ------------------------------------------------------------------
# Kolme tapaa. UseAzModule ja UseAzCli eivat vaadi omaa app registrationia.

function Get-PpToken {
    param([string]$Resource)
    if ($UseAzModule) {
        $t = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop
        # Uudemmat Az-versiot palauttavat SecureStringin
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
    Write-Host "Haetaan token Az PowerShell -moduulista..." -ForegroundColor Cyan
    $token = Get-PpToken -Resource "https://api.powerplatform.com"
    if (-not $token) { throw "Tokenia ei saatu. Aja: Connect-AzAccount -TenantId <tenantId>" }
}
elseif ($UseAzCli) {
    Write-Host "Haetaan token Azure CLI:sta..." -ForegroundColor Cyan
    Write-Host "Haetaan token Azure CLI:sta..." -ForegroundColor Cyan
    $token = Get-PpToken -Resource "https://api.powerplatform.com"
    if (-not $token) { throw "az ei antanut tokenia. Aja ensin: az login --tenant <tenantId>" }
} else {
    if (-not $ClientId -or -not $TenantId) {
        throw "Anna -ClientId ja -TenantId, tai kayta -UseAzModule / -UseAzCli."
    }
    Import-Module MSAL.PS -ErrorAction Stop   # Install-Module MSAL.PS -Scope CurrentUser
    $token = Get-PpToken -Resource "https://api.powerplatform.com"
}
$headers = @{ Authorization = "Bearer $token" }

# --- yhteystesti: paljastaa heti jos oikeudet tai CA estavat ----------------
try {
    $null = Invoke-PpRest -Method Get -Headers $headers `
            -Uri "$apiBase/licensing/allocationsV2/availability?api-version=$apiVersion&`$filter=$([uri]::EscapeDataString("EntitlementId in ('MCSMessages')"))"
    Write-Host "Yhteys rajapintaan OK.`n" -ForegroundColor Green
} catch {
    Write-Host "Yhteystesti: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "(404 on normaali jos suodatin ei osu - 401/403 tarkoittaa oikeus- tai CA-estoa.)`n"
}

# --- ymparistolista ---------------------------------------------------------
$targets = @()
if ($EnvironmentCsv) {
    $targets = Import-Csv $EnvironmentCsv
} elseif ($EnvironmentId) {
    $targets = @([pscustomobject]@{ environmentId = $EnvironmentId; name = $EnvironmentId })
} elseif ($AllEnvironments) {
    # Ymparistojen listaus on eri rajapinnassa (BAP) ja vaatii oman tokenin.
    Write-Host "Haetaan kaikki ymparistot tenantista..." -ForegroundColor Cyan
    $bapToken = Get-PpToken -Resource "https://api.bap.microsoft.com/" 
    if (-not $bapToken) { throw "Ymparistolistan tokenia ei saatu." }
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
    Write-Host "Loytyi $($targets.Count) ymparistoa.`n" -ForegroundColor Cyan
} else {
    throw "Anna -AllEnvironments, -EnvironmentCsv tai -EnvironmentId."
}
Write-Host "Ymparistoja: $($targets.Count)   Quantity: $Quantity   TenantPool: $AllowTenantPool" -ForegroundColor Cyan
if (-not $Apply) { Write-Host "KUIVAHARJOITUS - mitaan ei kirjoiteta. Lisaa -Apply.`n" -ForegroundColor Yellow }

# --- jatkaminen keskeytyneesta ajosta ---------------------------------------
$done = @()
if ($Resume -and (Test-Path $StateFile)) {
    $done = Get-Content $StateFile | Where-Object { $_ }
    Write-Host "Jatketaan: $($done.Count) ymparistoa on jo tehty, ne ohitetaan.`n" -ForegroundColor Cyan
}

$ok = 0; $fail = 0; $skipped = 0; $already = 0

foreach ($t in $targets) {
    $envId = $t.environmentId
    $name  = if ($t.name) { $t.name } else { $envId }
    if (-not $envId) { continue }
    if ($Resume -and $done -contains $envId) { $already++; continue }

    # --- 1. nykytila: paljonko allokoitavissa -------------------------------
    $available = "?"
    try {
        $filter = [uri]::EscapeDataString("environmentId eq '$envId' and EntitlementId in ('MCSMessages')")
        $a = Invoke-PpRest -Method Get -Headers $headers `
             -Uri "$apiBase/licensing/allocationsV2/availability?api-version=$apiVersion&`$filter=$filter"
        $mcs = $a.entitlementAllocationsAvailable | Where-Object { $_.entitlementId -eq 'MCSMessages' }
        if ($mcs) { $available = $mcs.availableQuantity }
    } catch {
        $available = "n/a"   # 404 = allokaatiota ei ole, se on itsessaan tieto
    }

    if (-not $Apply) {
        $t = if ($t.type) { $t.type } else { "" }
        Write-Host ("  (kuiva) {0,-38} {1,-12} allokoitavissa: {2}" -f `
            $name.Substring(0,[Math]::Min(38,$name.Length)), $t, $available)
        $skipped++
        continue
    }

    # --- 2. kirjoita allokaatio ---------------------------------------------
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
    Write-Host "Valmis: $ok onnistui, $fail epaonnistui$(if($already){", $already ohitettu (jo tehty)"})." -ForegroundColor Cyan
    Write-Host "Tehdyt ymparistot: $StateFile  (jatka katkosta: -Resume)" -ForegroundColor DarkGray
}
else        { Write-Host "Kuivaharjoitus: $skipped ymparistoa lapikayty, mitaan ei muutettu." -ForegroundColor Yellow }
