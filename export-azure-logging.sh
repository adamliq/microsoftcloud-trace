#!/usr/bin/env bash
# Export Azure resources and their diagnostic settings for the log coverage POC.
#
# Run in Azure Cloud Shell (bash) or anywhere with Azure CLI + jq, signed in with `az login`.
# Needs Reader on the subscriptions. The Entra ID part needs a role that can read
# tenant diagnostic settings; if you don't have one, that step is skipped.
#
# Usage:
#   ./export-azure-logging.sh                         # every enabled subscription you can see
#   SUBS="sub-id-1 sub-id-2" ./export-azure-logging.sh
#   RG=rg-contoso-shop-prod ./export-azure-logging.sh # only one resource group (faster)
#   OUT=my-export PARALLEL=16 ./export-azure-logging.sh
#
# Output (import both into the POC: Inventory > Import resources, then Import diagnostic settings):
#   $OUT/resources.json            resources + activity log (per subscription) + Entra ID tenant
#   $OUT/diagnostic-settings.json  every diagnostic setting found, in `az monitor diagnostic-settings list` format
#   $OUT/defender-pricing.json     Defender for Cloud plans per subscription (for reference)

set -uo pipefail
OUT=${OUT:-azure-logging-export}
PARALLEL=${PARALLEL:-8}
RG=${RG:-}
command -v az >/dev/null || { echo "Azure CLI (az) is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
az extension add --name resource-graph --only-show-errors >/dev/null 2>&1 || true

mkdir -p "$OUT/raw/ds"
SUBS=${SUBS:-$(az account list --query "[?state=='Enabled'].id" -o tsv)}
[ -n "$SUBS" ] || { echo "No subscriptions found. Run az login first."; exit 1; }
echo "Subscriptions: $(echo $SUBS | wc -w)"

# 1. Resources from Azure Resource Graph (paged)
Q="Resources"
[ -n "$RG" ] && Q="$Q | where resourceGroup =~ '$RG'"
Q="$Q | project id, name, type, kind"
: > "$OUT/raw/resources.ndjson"
token=""
while :; do
  if [ -n "$token" ]; then
    res=$(az graph query -q "$Q" --first 1000 --subscriptions $SUBS --skip-token "$token" -o json)
  else
    res=$(az graph query -q "$Q" --first 1000 --subscriptions $SUBS -o json)
  fi
  echo "$res" | jq -c '.data[]' >> "$OUT/raw/resources.ndjson"
  token=$(echo "$res" | jq -r '.skip_token // .skipToken // empty')
  [ -z "$token" ] && break
done
echo "Resources: $(wc -l < "$OUT/raw/resources.ndjson")"

# Storage accounts log per service (blob, file, queue, table), so add those child resources.
jq -c 'select(.type|ascii_downcase=="microsoft.storage/storageaccounts")
  | . as $a | ("blobServices","fileServices","queueServices","tableServices")
  | {id:($a.id+"/"+.+"/default"), name:($a.name+" / "+(.|sub("Services";""))), type:("Microsoft.Storage/storageAccounts/"+.), kind:""}' \
  "$OUT/raw/resources.ndjson" >> "$OUT/raw/resources.ndjson"

# Activity log (one per subscription) and the Entra ID tenant.
for s in $SUBS; do
  name=$(az account show --subscription "$s" --query name -o tsv 2>/dev/null || echo "$s")
  jq -nc --arg id "/subscriptions/$s" --arg n "Activity log ($name)" '{id:$id,name:$n,type:"Subscription",kind:""}' >> "$OUT/raw/resources.ndjson"
done
[ -z "$RG" ] && jq -nc '{id:"/providers/microsoft.aadiam",name:"Entra ID tenant",type:"Tenant",kind:""}' >> "$OUT/raw/resources.ndjson"

jq -s 'unique_by(.id|ascii_downcase)' "$OUT/raw/resources.ndjson" > "$OUT/resources.json"
echo "Wrote $OUT/resources.json ($(jq length "$OUT/resources.json") entries)"

# 2. Diagnostic settings per resource, in parallel. Types without diagnostic settings return nothing.
echo "Reading diagnostic settings (this can take a while)..."
jq -r '.[] | select(.type!="Subscription" and .type!="Tenant") | .id' "$OUT/resources.json" |
  xargs -P "$PARALLEL" -I{} sh -c '
    f="$2/$(printf %s "$1" | md5sum | cut -c1-16).json"
    az monitor diagnostic-settings list --resource "$1" --query "value || @" -o json 2>/dev/null > "$f" || echo "[]" > "$f"
    [ -s "$f" ] || echo "[]" > "$f"' _ {} "$OUT/raw/ds"

for s in $SUBS; do
  az monitor diagnostic-settings subscription list --subscription "$s" --query "value || @" -o json \
    > "$OUT/raw/ds/sub-$s.json" 2>/dev/null || echo "[]" > "$OUT/raw/ds/sub-$s.json"
done

if [ -z "$RG" ]; then
  az rest --method get \
    --url "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01-preview" \
    --query value -o json > "$OUT/raw/ds/entra.json" 2>/dev/null \
    || { echo "Skipped Entra ID diagnostic settings (no access)"; echo "[]" > "$OUT/raw/ds/entra.json"; }
fi

jq -s '[ .[] | if type=="array" then .[] else empty end | select(.id != null) ]' "$OUT"/raw/ds/*.json > "$OUT/diagnostic-settings.json"
echo "Wrote $OUT/diagnostic-settings.json ($(jq length "$OUT/diagnostic-settings.json") settings)"

# 3. Defender for Cloud plans (reference only; set them in the POC's Defender for Cloud panel)
for s in $SUBS; do
  az security pricing list --subscription "$s" -o json 2>/dev/null \
    | jq --arg s "$s" '{subscription:$s, plans:[(.value // .)[] | {name, pricingTier, subPlan}]}'
done | jq -s '.' > "$OUT/defender-pricing.json"
echo "Wrote $OUT/defender-pricing.json"
echo "Done. In the POC: Inventory > Clear all resources, then Import resources ($OUT/resources.json) and Import diagnostic settings ($OUT/diagnostic-settings.json)."
