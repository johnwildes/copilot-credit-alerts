<#
.SYNOPSIS
  Listaa kaikki Copilot Studio -agentit tenantissa ja niiden omistajien sahkopostit.

.DESCRIPTION
  Kaksi rajapintaa:
    1. Power Platform inventory API (Resource Query) - kaikki agentit koko tenantista
       yhdella kyselylla, mukana ownerId (Entra-objektitunnus) ja environmentId.
       POST https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01
    2. Microsoft Graph - ownerId -> displayName, mail, userPrincipalName.
       Yksi kutsu per UNIIKKI omistaja, ei per agentti.
  Lisaksi ymparistojen nimet BAP-rajapinnasta, jotta CSV:ssa on nimi eika vain GUID.

  Sama todennus kuin Set-CopilotCreditCaps.ps1:ssa. Ei kirjoita mihinkaan -
  tama on pelkka lukuraportti.

  -UsersCsv: kun Graph ei ole kaytettavissa (CA/CAE), lataa kayttajat Entra admin
  centerista (Users > All users > Download users) ja anna tiedosto tassa. Omistajat
  yhdistetaan paikallisesti ownerId = id. Ei yhtaan Graph-kutsua.

  -UseMgGraph: Graph torjui Az-moduulin tokenin Sanoman tenantissa 15.9.2026
  (401 InvalidAuthenticationToken, "Continuous access evaluation ... InteractionRequired,
  LocationConditionEvaluationSatisfied"). Az ei osaa vastata CAE:n claims-haasteeseen;
  Microsoft.Graph.Authentication osaa ja avaa kirjautumisen uudelleen. Power Platform-
  ja BAP-kutsut menevat silti Az:lla.

  Tunnetut ansat (CopilotCreditAlerts/log.md 14.8.2026, todennettu oikealla datalla):
    - ownerId voi olla 00000000-0000-0000-0000-000000000000 = jarjestelman agentti
    - poistuneen kayttajan id ei loydy Graphista -> rivi merkitaan, ajo ei kaadu
    - isCLIAgent saa kolme arvoa: "true", "false" ja tyhja
    - kiintio: x-ms-ratelimit-remaining-tenant-resource-requests ~14, nollautuu 5 s
    - lauseissa '$type' on oltava ENSIMMAINEN kentta -> [ordered]@{}. Tavallinen @{}
      antoi 400 "KQLOM format is wrong or it cannot be null" (15.9.2026).
    - yksi kutsu palauttaa enintaan 1000 rivia; Sanomassa on 3964 agenttia -> sivutus
      Options.Top + skipToken/Skip, ei take-lausetta.

.NOTES
  Aja omalta koneelta (Intune-hallittu), ei palvelimelta, kunnes Conditional
  Access -poikkeus palvelimen IP:lle on paalla (Sanoma Agent Governance/log.md 15.9.2026).

.EXAMPLE
  Install-Module Az.Accounts -Scope CurrentUser
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  Connect-AzAccount -TenantId <tenantId>
  .\Get-CopilotAgentOwners.ps1 -UseAzModule -UseMgGraph -TenantId <tenantId> -OwnersCsv .\owners.csv
  # -> .\copilot-agent-owners.csv ja .\owners.csv

.EXAMPLE
  # Vain yhden ympariston agentit, ja uniikit omistajat omaan tiedostoon
  .\Get-CopilotAgentOwners.ps1 -UseAzModule -EnvironmentId <envId> -OwnersCsv .\owners.csv
#>
[CmdletBinding()]
param(
    [string]$ClientId,                       # app registration (vaihtoehto 3, MSAL.PS)
    [string]$TenantId,
    [switch]$UseAzCli,                       # vaihtoehto 1: token Azure CLI:sta
    [switch]$UseAzModule,                    # vaihtoehto 2: Az PowerShell -moduuli (suositeltu)
    [switch]$UseMgGraph,                     # omistajien haku Microsoft.Graph-moduulilla (CAE-haaste)
                                             #   Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    [switch]$DeviceCode,                     # Graph-kirjautuminen koodilla konsoliin, ei WAM-ikkunaa
                                             #   (WAM-ikkuna jai piiloon ja ajo jumittui 15.9.2026)
                                             #   HUOM: Sanoman CA estaa device code -kirjautumisen (15.9.2026)
    [string]$UsersCsv,                       # omistajat Entra admin centerin "Download users" -CSV:sta,
                                             #   ei Graphista lainkaan. Sarakkeet: id, userPrincipalName,
                                             #   displayName, mail, accountEnabled (otsikot tunnistetaan)
    [string]$EnvironmentId,                  # rajaa yhteen ymparistoon; oletus koko tenantti
    [switch]$IncludeSystemAgents,            # ota mukaan myos 0000...-omistajat (oletus: pois)
    [string]$OutCsv    = ".\copilot-agent-owners.csv",   # yksi rivi per agentti
    [string]$OwnersCsv = "",                 # valinnainen: yksi rivi per uniikki omistaja
    [int]$PageSize = 1000,                   # inventory API:n sivukoko (Options.Top); rajapinnan katto on 1000
    [int]$DelayMs = 150,                     # kuristussuoja Graph-silmukassa (533 omistajaa ~ 2 min)
    [int]$TimeoutSec = 60,
    [int]$Retries = 3
)

$apiBase    = "https://api.powerplatform.com"
$apiVersion = "2024-10-01"
$graphBase  = "https://graph.microsoft.com/v1.0"

# --- REST-kaari: aikakatkaisu + uudelleenyritys (sama kuin Set-CopilotCreditCaps) --
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
            # 4xx: nayta palvelimen oma virheteksti, muuten 400 jaa mykaksi
            if ($status -and $status -ge 400 -and $status -lt 500 -and $status -ne 429) {
                try {
                    $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                    Write-Host ("    HTTP {0}: {1}" -f $status, $sr.ReadToEnd()) -ForegroundColor Red
                } catch {}
                throw
            }
            if ($i -eq $Retries) { throw }
            $wait = [Math]::Pow(2, $i)
            Write-Host ("    yritys {0}/{1} epaonnistui, odotetaan {2}s" -f $i, $Retries, $wait) -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }
    }
}

# --- token ------------------------------------------------------------------
function Get-PpToken {
    param([string]$Resource)
    if ($UseAzModule) {
        $t = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop
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
} elseif (-not $UseAzCli) {
    if (-not $ClientId -or -not $TenantId) {
        throw "Anna -ClientId ja -TenantId, tai kayta -UseAzModule / -UseAzCli."
    }
    Import-Module MSAL.PS -ErrorAction Stop
}

Write-Host "Haetaan tokenit (Power Platform API, BAP)..." -ForegroundColor Cyan
$ppToken    = Get-PpToken -Resource "https://api.powerplatform.com"
$bapToken   = Get-PpToken -Resource "https://api.bap.microsoft.com/"
foreach ($pair in @(@("Power Platform", $ppToken), @("BAP", $bapToken))) {
    if (-not $pair[1]) { throw "Tokenia ei saatu: $($pair[0]). 401/403 tai CA-esto - aja hallitulta koneelta." }
}
$ppHeaders    = @{ Authorization = "Bearer $ppToken" }
$bapHeaders   = @{ Authorization = "Bearer $bapToken" }

$users = @{}
if ($UsersCsv) {
    if (-not (Test-Path $UsersCsv)) { throw "Kayttajatiedostoa ei loydy: $UsersCsv" }
    $raw = Import-Csv $UsersCsv
    if (-not $raw) { throw "Kayttajatiedosto on tyhja: $UsersCsv" }
    # Entra-viennin otsikot vaihtelevat (id / objectId / Object Id ...) - tunnistetaan nimella
    $cols = @($raw[0].PSObject.Properties.Name)
    function Find-Col { param($cands) foreach ($c in $cands) { $hit = $cols | Where-Object { $_ -replace '[\s_]','' -ieq $c }; if ($hit) { return $hit | Select-Object -First 1 } } ; return $null }
    $cId  = Find-Col @('id','objectid','userid')
    $cUpn = Find-Col @('userPrincipalName','upn')
    $cNm  = Find-Col @('displayName','name')
    $cMl  = Find-Col @('mail','email','emailaddress')
    $cEn  = Find-Col @('accountEnabled','enabled')
    if (-not $cId) { throw "Kayttajatiedostosta ei loydy id-saraketta. Sarakkeet: $($cols -join ', ')" }
    foreach ($u in $raw) {
        $id = ([string]$u.$cId).Trim().ToLower()
        if (-not $id) { continue }
        $en = $null
        if ($cEn) { $v = [string]$u.$cEn; if ($v -match '^(true|yes|1)$') { $en = $true } elseif ($v -match '^(false|no|0)$') { $en = $false } }
        $users[$id] = [pscustomobject]@{
            ownerName    = $(if ($cNm) { $u.$cNm } else { '' })
            ownerEmail   = $(if ($cMl -and $u.$cMl) { $u.$cMl } elseif ($cUpn) { $u.$cUpn } else { '' })
            ownerUpn     = $(if ($cUpn) { $u.$cUpn } else { '' })
            ownerEnabled = $en
            ownerStatus  = 'ok'
        }
    }
    Write-Host "Kayttajatiedosto: $($users.Count) kayttajaa ($UsersCsv)" -ForegroundColor Cyan
}
elseif ($UseMgGraph) {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    if (-not $ctx -or ($TenantId -and $ctx.TenantId -ne $TenantId)) {
        Write-Host "Kirjaudutaan Graphiin (Microsoft.Graph)..." -ForegroundColor Cyan
        $cp = @{ Scopes = @("User.Read.All"); NoWelcome = $true }
        if ($TenantId) { $cp.TenantId = $TenantId }
        if ($DeviceCode) { $cp.UseDeviceCode = $true }
        Connect-MgGraph @cp
    }
    # Yhteystesti heti: jos CAE/CA torjuu, se nakyy tassa eika 1112 kutsun silmukassa.
    # Jumi tassa kohdassa = piilossa oleva kirjautumisikkuna -> aja -DeviceCode.
    Write-Host "Graph-yhteystesti..." -ForegroundColor Cyan
    try {
        $null = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/users?`$top=1&`$select=id" -ErrorAction Stop
        Write-Host "  Graph OK ($((Get-MgContext).Account))" -ForegroundColor Green
    } catch {
        throw "Graph-yhteystesti epaonnistui: $($_.Exception.Message)"
    }
} else {
    $graphToken = Get-PpToken -Resource "https://graph.microsoft.com"
    if (-not $graphToken) { throw "Graph-tokenia ei saatu. Kokeile -UseMgGraph." }
    $graphHeaders = @{ Authorization = "Bearer $graphToken"; ConsistencyLevel = "eventual" }
}

# Yksi Graph-haku, kummalla tahansa reitilla. Heittaa poikkeuksen jossa .Status on HTTP-koodi.
function Get-GraphUser {
    param([string]$Id)
    $uri = "$graphBase/users/$Id`?`$select=id,displayName,mail,userPrincipalName,accountEnabled"
    if ($UseMgGraph) {
        try { return Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop }
        catch {
            $st = $null
            try { $st = [int]$_.Exception.Response.StatusCode } catch {}
            if (-not $st -and $_.ErrorDetails.Message -match '"code"\s*:\s*"Request_ResourceNotFound"') { $st = 404 }
            throw [System.Exception]::new("HTTP $st $($_.Exception.Message)")
        }
    }
    return Invoke-PpRest -Method Get -Headers $graphHeaders -Uri $uri
}

# --- 1. ymparistojen nimet ---------------------------------------------------
Write-Host "Haetaan ymparistot..." -ForegroundColor Cyan
$envNames = @{}
try {
    $envs = Invoke-PpRest -Method Get -Headers $bapHeaders `
        -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01"
    foreach ($e in $envs.value) {
        # Inventaario palauttaa oletusympariston muodossa default-<id>, BAP muodossa
        # Default-<id>. Avain pieniksi kirjaimiksi, muuten oletusymparisto jaa nimettomaksi.
        $envNames[$e.name.ToLower()] = $e.properties.displayName
    }
    Write-Host "  $($envNames.Count) ymparistoa." -ForegroundColor DarkGray
} catch {
    Write-Host "  Ymparistolistaa ei saatu ($($_.Exception.Message)) - CSV:ssa vain GUIDit." -ForegroundColor Yellow
}

# --- 2. agentit inventory API:sta, sivutettuna ------------------------------
Write-Host "Haetaan Copilot Studio -agentit..." -ForegroundColor Cyan
# [ordered] on pakollinen: palvelin lukee lauseen tyypin '$type'-kentasta ja se on
# oltava objektin ENSIMMAINEN kentta. Tavallinen @{} ei sailyta jarjestysta ->
# "KQLOM format is wrong or it cannot be null" (400, todettu 15.9.2026).
$clauses = @(
    [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = '=='; Values = @("'microsoft.copilotstudio/agents'") }
)
if ($EnvironmentId) {
    $clauses += [ordered]@{ '$type' = 'where'; FieldName = 'properties.environmentId'; Operator = '=='; Values = @("'$EnvironmentId'") }
}
$clauses += [ordered]@{ '$type' = 'project'; FieldList = @(
    'name',
    'displayName = tostring(properties.displayName)',
    'environmentId = tostring(properties.environmentId)',
    'ownerId = tostring(properties.ownerId)',
    'isCLIAgent = tostring(properties.isCLIAgent)'
) }
# Sivutus: rajapinta palauttaa enintaan 1000 rivia per kutsu take-arvosta riippumatta
# (Sanoma 15.9.2026: totalRecords=3964, take 5000 -> 1000 rivia). Learn (inventory-api):
# Options { Top, Skip, SkipToken }; vastauksessa totalRecords, count, skipToken.
# EI take-lausetta - se estaa skipTokenin. Ensisijaisesti skipToken, varalla Skip-offset.
$agents = @()
$skipToken = $null
$offset = 0
$page = 0
do {
    $page++
    $options = [ordered]@{ Top = $PageSize }
    if ($skipToken) { $options.SkipToken = $skipToken } elseif ($offset) { $options.Skip = $offset }
    $body = [ordered]@{ TableName = 'PowerPlatformResources'; Clauses = $clauses; Options = $options } | ConvertTo-Json -Depth 10
    $r = Invoke-PpRest -Method Post -Headers $ppHeaders `
         -Uri "$apiBase/resourcequery/resources/query?api-version=$apiVersion" -Body $body
    $got = @($r.data)
    $agents += $got
    $offset += $got.Count
    $skipToken = $r.skipToken
    Write-Host ("  sivu {0}: {1} agenttia (yhteensa {2}/{3})" -f $page, $got.Count, $agents.Count, $r.totalRecords) -ForegroundColor DarkGray
    $more = ($got.Count -gt 0) -and ($skipToken -or ($r.totalRecords -and $agents.Count -lt $r.totalRecords))
    if ($more) { Start-Sleep -Seconds 5 }   # kiintio ~14 kutsua, nollautuu 5 s
    if ($page -ge 50) { Write-Host "  VAROITUS: 50 sivua, lopetetaan." -ForegroundColor Yellow; $more = $false }
} while ($more)
if ($r.totalRecords -and $agents.Count -lt $r.totalRecords) {
    Write-Host ("  VAROITUS: saatiin {0}/{1} - sivutus ei kattanut kaikkea." -f $agents.Count, $r.totalRecords) -ForegroundColor Yellow
}

$zeroGuid = '00000000-0000-0000-0000-000000000000'
$system = @($agents | Where-Object { -not $_.ownerId -or $_.ownerId -eq $zeroGuid })
if (-not $IncludeSystemAgents) {
    $agents = @($agents | Where-Object { $_.ownerId -and $_.ownerId -ne $zeroGuid })
}
Write-Host ("  {0} agenttia, joista {1} jarjestelman omistamaa{2}." -f ($agents.Count + $(if ($IncludeSystemAgents) { 0 } else { $system.Count })), $system.Count, $(if ($IncludeSystemAgents) { " (mukana)" } else { " (ohitettu, -IncludeSystemAgents ottaa mukaan)" })) -ForegroundColor Cyan

# --- 2b. agenttilista levylle HETI, ennen omistajien hakua --------------------
# Jos Graph kaatuu tai jumittuu, inventaario on silti tallessa (15.9.2026: kolme
# ajoa kaatui Graph-vaiheeseen ja lista meni joka kerta hukkaan).
$agents | Select-Object @{n='agentName';e={$_.displayName}}, @{n='agentId';e={$_.name}},
    @{n='environmentName';e={$envNames[([string]$_.environmentId).ToLower()]}}, environmentId, ownerId, isCLIAgent |
    Sort-Object environmentName, agentName | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host "Agenttilista kirjoitettu (ilman omistajia): $OutCsv" -ForegroundColor DarkGray

# --- 3. omistajat: tiedostosta tai Graphista, yksi haku per uniikki id ----------
$ownerIds = @($agents | ForEach-Object { $_.ownerId } | Where-Object { $_ -and $_ -ne $zeroGuid } | Sort-Object -Unique)
$owners = @{}
$i = 0
$graphBlocked = $false
if ($UsersCsv) {
    Write-Host "Yhdistetaan $($ownerIds.Count) uniikkia omistajaa kayttajatiedostosta..." -ForegroundColor Cyan
    foreach ($id in $ownerIds) {
        $hit = $users[$id.ToLower()]
        if ($hit) { $owners[$id] = $hit }
        else { $owners[$id] = [pscustomobject]@{ ownerName=''; ownerEmail=''; ownerUpn=''; ownerEnabled=$null; ownerStatus='ei loydy kayttajatiedostosta (poistettu / vieras / ryhma?)' } }
    }
    $ownerIds = @()   # Graph-silmukka ohitetaan
} else {
    Write-Host "Haetaan $($ownerIds.Count) uniikkia omistajaa Graphista..." -ForegroundColor Cyan
}
foreach ($id in $ownerIds) {
    $i++
    if ($graphBlocked) {
        $owners[$id] = [pscustomobject]@{ ownerName=''; ownerEmail=''; ownerUpn=''; ownerEnabled=$null; ownerStatus='ei haettu (Graph esti)' }
        continue
    }
    try {
        $u = Get-GraphUser -Id $id
        $owners[$id] = [pscustomobject]@{
            ownerName    = $u.displayName
            ownerEmail   = $(if ($u.mail) { $u.mail } else { $u.userPrincipalName })
            ownerUpn     = $u.userPrincipalName
            ownerEnabled = $u.accountEnabled
            ownerStatus  = 'ok'
        }
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if (-not $status -and $_.Exception.Message -match '^HTTP (\d+)') { $status = [int]$Matches[1] }
        # 401/403 = koko Graph-reitti kiinni (CA/CAE) - ei toisteta 500 kertaa
        if ($status -eq 401 -or $status -eq 403) {
            $graphBlocked = $true
            Write-Host "  Graph torjui ($status). Omistajia ei haeta; CSV:hen tulee ownerId. Kokeile -UseMgGraph." -ForegroundColor Yellow
            Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkGray
            $owners[$id] = [pscustomobject]@{ ownerName=''; ownerEmail=''; ownerUpn=''; ownerEnabled=$null; ownerStatus="ei haettu (Graph $status)" }
            continue
        }
        # 404 = poistettu kayttaja tai ei kayttaja lainkaan (esim. tiimi/palvelutunnus)
        $owners[$id] = [pscustomobject]@{
            ownerName = ''; ownerEmail = ''; ownerUpn = ''; ownerEnabled = $null
            ownerStatus = $(if ($status -eq 404) { 'ei loydy (poistettu?)' } else { "virhe $status" })
        }
    }
    if ($i % 25 -eq 0) { Write-Host "  $i/$($ownerIds.Count)" -ForegroundColor DarkGray }
    Start-Sleep -Milliseconds $DelayMs
}

# --- 4. tulos ----------------------------------------------------------------
$rows = foreach ($a in $agents) {
    $o = $owners[$a.ownerId]
    [pscustomobject]@{
        agentName       = $a.displayName
        agentId         = $a.name
        environmentName = $envNames[([string]$a.environmentId).ToLower()]
        environmentId   = $a.environmentId
        ownerName       = $(if ($o) { $o.ownerName }  else { '' })
        ownerEmail      = $(if ($o) { $o.ownerEmail } else { '' })
        ownerEnabled    = $(if ($o) { $o.ownerEnabled } else { $null })
        ownerStatus     = $(if ($o) { $o.ownerStatus } elseif ($a.ownerId -eq $zeroGuid -or -not $a.ownerId) { 'jarjestelma' } else { '' })
        ownerId         = $a.ownerId
        isCLIAgent      = $a.isCLIAgent
    }
}
$rows | Sort-Object environmentName, agentName | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host "`nKirjoitettu: $OutCsv  ($($rows.Count) rivia)" -ForegroundColor Green

if ($OwnersCsv) {
    $rows | Where-Object { $_.ownerEmail } |
        Group-Object ownerEmail |
        ForEach-Object {
            [pscustomobject]@{
                ownerEmail   = $_.Name
                ownerName    = $_.Group[0].ownerName
                ownerEnabled = $_.Group[0].ownerEnabled
                agentCount   = $_.Count
                agents       = ($_.Group.agentName -join '; ')
            }
        } | Sort-Object agentCount -Descending | Export-Csv -Path $OwnersCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Kirjoitettu: $OwnersCsv  (uniikit omistajat)" -ForegroundColor Green
}

$missing = @($rows | Where-Object { $_.ownerStatus -ne 'ok' -and $_.ownerStatus -ne 'jarjestelma' })
$disabled = @($rows | Where-Object { $_.ownerEnabled -eq $false })
Write-Host ""
Write-Host ("Yhteenveto: {0} agenttia, {1} uniikkia omistajaa, {2} ilman loytyvaa omistajaa, {3} omistaja pois kaytosta." -f `
    $rows.Count, $ownerIds.Count, $missing.Count, $disabled.Count) -ForegroundColor Cyan
if ($missing.Count -or $disabled.Count) {
    Write-Host "Nama ovat ne joille halytysta ei voi lahettaa - katso ownerStatus/ownerEnabled CSV:sta." -ForegroundColor Yellow
}
