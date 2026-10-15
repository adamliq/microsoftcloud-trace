<#
.SYNOPSIS
  Export Azure resources and their diagnostic settings for the log coverage POC.

.DESCRIPTION
  Run in Azure Cloud Shell (PowerShell) or locally with PowerShell 7 and the Az modules,
  signed in with Connect-AzAccount. Needs Reader on the subscriptions. The Entra ID part
  needs a role that can read tenant diagnostic settings; without one it is skipped.

  Output (import both into the POC: Inventory > Import resources, then Import diagnostic settings):
    <OutDir>\resources.json            resources + activity log per subscription + Entra ID tenant
    <OutDir>\diagnostic-settings.json  every diagnostic setting found (REST format, which the POC reads)
    <OutDir>\defender-pricing.json     Defender for Cloud plans per subscription (reference only)

.EXAMPLE
  ./Export-AzureLogging.ps1
.EXAMPLE
  ./Export-AzureLogging.ps1 -ResourceGroup rg-contoso-shop-prod
.EXAMPLE
  ./Export-AzureLogging.ps1 -SubscriptionId 1111-..., 2222-... -ThrottleLimit 16
#>
[CmdletBinding()]
param(
  [string[]]$SubscriptionId,
  [string]$ResourceGroup,
  [string]$OutDir = "azure-logging-export",
  [int]$ThrottleLimit = 8
)
$ErrorActionPreference = "Stop"

foreach ($m in "Az.Accounts","Az.ResourceGraph") {
  if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module $m is required. Install-Module $m -Scope CurrentUser" }
}
Import-Module Az.Accounts, Az.ResourceGraph
if (-not (Get-AzContext)) { throw "Not signed in. Run Connect-AzAccount first." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not $SubscriptionId) { $SubscriptionId = (Get-AzSubscription | Where-Object State -eq "Enabled").Id }
if (-not $SubscriptionId) { throw "No subscriptions found." }
Write-Host "Subscriptions: $($SubscriptionId.Count)"

function Write-JsonArray($Items, $Path) {
  ConvertTo-Json -InputObject @($Items) -Depth 20 | Set-Content -Path $Path -Encoding utf8
}
function Get-Rest($Path) {
  # Returns the .value array of a GET, or an empty array if the call fails or the type has no settings.
  try {
    $r = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) {
      $j = $r.Content | ConvertFrom-Json -Depth 30
      if ($null -ne $j.value) { return @($j.value) } else { return @($j) }
    }
  } catch { }
  return @()
}

# 1. Resources from Azure Resource Graph (paged)
$q = "Resources"
if ($ResourceGroup) { $q += " | where resourceGroup =~ '$ResourceGroup'" }
$q += " | project id, name, type, kind"
$resources = [System.Collections.Generic.List[object]]::new()
$skip = $null
do {
  $p = @{ Query = $q; First = 1000; Subscription = $SubscriptionId }
  if ($skip) { $p.SkipToken = $skip }
  $r = Search-AzGraph @p
  $rows = if ($null -ne $r.Data) { $r.Data } else { $r }
  foreach ($x in $rows) { $resources.Add([pscustomobject]@{ id = $x.id; name = $x.name; type = $x.type; kind = "$($x.kind)" }) }
  $skip = $r.SkipToken
} while ($skip)
Write-Host "Resources: $($resources.Count)"

# Storage accounts log per service (blob, file, queue, table), so add those child resources.
$storage = @($resources | Where-Object { $_.type -ieq "microsoft.storage/storageaccounts" })
foreach ($a in $storage) {
  foreach ($svc in "blobServices","fileServices","queueServices","tableServices") {
    $resources.Add([pscustomobject]@{ id = "$($a.id)/$svc/default"; name = "$($a.name) / $($svc -replace 'Services','')"; type = "Microsoft.Storage/storageAccounts/$svc"; kind = "" })
  }
}

# Activity log (one per subscription) and the Entra ID tenant.
foreach ($s in $SubscriptionId) {
  $name = (Get-AzSubscription -SubscriptionId $s -ErrorAction SilentlyContinue).Name
  if (-not $name) { $name = $s }
  $resources.Add([pscustomobject]@{ id = "/subscriptions/$s"; name = "Activity log ($name)"; type = "Subscription"; kind = "" })
}
if (-not $ResourceGroup) {
  $resources.Add([pscustomobject]@{ id = "/providers/microsoft.aadiam"; name = "Entra ID tenant"; type = "Tenant"; kind = "" })
}
$resources = @($resources | Sort-Object { $_.id.ToLower() } -Unique)
Write-JsonArray $resources (Join-Path $OutDir "resources.json")
Write-Host "Wrote $OutDir/resources.json ($($resources.Count) entries)"

# 2. Diagnostic settings for every resource, through the REST API.
Write-Host "Reading diagnostic settings (this can take a while)..."
$ids = @($resources | Where-Object { $_.type -notin "Subscription","Tenant" } | ForEach-Object id)
$api = "api-version=2021-05-01-preview"
if ($PSVersionTable.PSVersion.Major -ge 7) {
  $settings = $ids | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    try {
      $r = Invoke-AzRestMethod -Method GET -Path "$_/providers/Microsoft.Insights/diagnosticSettings?$($using:api)" -ErrorAction Stop
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { ($r.Content | ConvertFrom-Json -Depth 30).value }
    } catch { }
  }
} else {
  $settings = foreach ($id in $ids) { Get-Rest "$id/providers/Microsoft.Insights/diagnosticSettings?$api" }
}
$settings = [System.Collections.Generic.List[object]]@(@($settings) | Where-Object { $_ -and $_.id })

foreach ($s in $SubscriptionId) {
  foreach ($x in (Get-Rest "/subscriptions/$s/providers/Microsoft.Insights/diagnosticSettings?$api")) { if ($x.id) { $settings.Add($x) } }
}
if (-not $ResourceGroup) {
  $entra = Get-Rest "/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01-preview"
  if (-not $entra.Count) { Write-Host "No Entra ID diagnostic settings read (none, or no access)" }
  foreach ($x in $entra) { if ($x.id) { $settings.Add($x) } }
}
Write-JsonArray $settings (Join-Path $OutDir "diagnostic-settings.json")
Write-Host "Wrote $OutDir/diagnostic-settings.json ($($settings.Count) settings)"

# 3. Defender for Cloud plans (reference only; set them in the POC's Defender for Cloud panel)
$pricing = foreach ($s in $SubscriptionId) {
  [pscustomobject]@{
    subscription = $s
    plans = @(Get-Rest "/subscriptions/$s/providers/Microsoft.Security/pricings?api-version=2024-01-01" |
      ForEach-Object { [pscustomobject]@{ name = $_.name; pricingTier = $_.properties.pricingTier; subPlan = $_.properties.subPlan } })
  }
}
Write-JsonArray $pricing (Join-Path $OutDir "defender-pricing.json")
Write-Host "Wrote $OutDir/defender-pricing.json"
Write-Host "Done. In the POC: Inventory > Clear all resources, then Import resources ($OutDir/resources.json) and Import diagnostic settings ($OutDir/diagnostic-settings.json)."
