#!/usr/bin/env bash
#
# get-azure-custom-dns-report-graph.sh
#
# Scans Azure Virtual Networks and Network Interfaces (NICs) with custom DNS
# configured, across MANY subscriptions at once, using Azure Resource Graph.
# Subscriptions are processed in chunks so you get visible progress instead
# of one silent query.
#
# Custom DNS in Azure lives at two levels:
#   - VNet level : dhcpOptions.dnsServers
#   - NIC level  : dnsSettings.dnsServers  (overrides the VNet for that NIC)
# Subnets don't have an independent DNS setting - they inherit from the VNet.
#
# REQUIREMENTS
#   - Azure CLI (az), logged in: az login
#   - resource-graph extension: az extension add --name resource-graph
#   - jq
#
# USAGE
#   ./get-azure-custom-dns-report-graph.sh                     # all subs you can see
#   ./get-azure-custom-dns-report-graph.sh sub-id-1 sub-id-2    # specific subs
#
# OUTPUT
#   azure-custom-dns-report.csv, columns:
#     Subscription, VNet/NIC, DNS Server (IP), New DNS Server (IP), Remarks
#   ("New DNS Server (IP)" and "Remarks" are left blank for you to fill in
#   as you plan/track remediation.)

set -euo pipefail

OUTPUT_CSV="azure-custom-dns-report.csv"
CHUNK_SIZE=15    # subscriptions per Resource Graph call, for progress granularity
PAGE_SIZE=1000   # Resource Graph max rows per page

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) not found." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found." >&2; exit 1; }

if ! az account show >/dev/null 2>&1; then
    echo "Not logged in. Running 'az login'..."
    az login >/dev/null
fi

if ! az extension show --name resource-graph >/dev/null 2>&1; then
    echo "Installing the resource-graph CLI extension..."
    az extension add --name resource-graph -y >/dev/null
fi

# --- Subscriptions to scan ---
if [ "$#" -gt 0 ]; then
    ALL_SUBS=("$@")
else
    mapfile -t ALL_SUBS < <(az account list --query "[].id" -o tsv)
fi
TOTAL_SUBS=${#ALL_SUBS[@]}
echo "Found $TOTAL_SUBS subscription(s) to scan."

# Map of subId -> subName, for the report
SUB_MAP=$(az account list --query "[].{id:id,name:name}" -o json)

echo "\"Subscription\",\"VNet/NIC\",\"DNS Server (IP)\",\"New DNS Server (IP)\",\"Remarks\"" > "$OUTPUT_CSV"

TOTAL_FOUND=0
DONE_SUBS=0

print_progress () {
    local pct=$(( DONE_SUBS * 100 / TOTAL_SUBS ))
    echo "  Progress: $DONE_SUBS/$TOTAL_SUBS subscriptions scanned (${pct}%) | $TOTAL_FOUND resource(s) with custom DNS found so far"
}

VNET_KQL_TEMPLATE='
Resources
| where type =~ "microsoft.network/virtualnetworks"
| where isnotempty(properties.dhcpOptions.dnsServers)
| project subscriptionId,
          label = strcat("VNet: ", name),
          dnsServers = properties.dhcpOptions.dnsServers
'

NIC_KQL_TEMPLATE='
Resources
| where type =~ "microsoft.network/networkinterfaces"
| where isnotempty(properties.dnsSettings.dnsServers)
| project subscriptionId,
          label = strcat("NIC: ", name,
                   iff(isnotempty(properties.virtualMachine.id),
                       strcat(" (VM: ", tostring(split(tostring(properties.virtualMachine.id), "/")[-1]), ")"),
                       " (unattached)")),
          dnsServers = properties.dnsSettings.dnsServers
'

run_query_for_chunk () {
    local kql="$1"
    shift
    local chunk_subs=("$@")
    local skip=0
    local rows
    local count

    while true; do
        rows=$(az graph query -q "$kql" --subscriptions "${chunk_subs[@]}" \
                 --first "$PAGE_SIZE" --skip "$skip" --query "data" -o json)
        count=$(echo "$rows" | jq 'length')
        [ "$count" -eq 0 ] && break

        echo "$rows" | jq -r --argjson submap "$SUB_MAP" '
            .[] as $r
            | ($submap[] | select(.id == $r.subscriptionId) | .name) as $subname
            | ($r.dnsServers | join("; ")) as $dns
            | [$subname, $r.label, $dns, "", ""] | @csv' >> "$OUTPUT_CSV"

        TOTAL_FOUND=$((TOTAL_FOUND + count))
        [ "$count" -lt "$PAGE_SIZE" ] && break
        skip=$((skip + PAGE_SIZE))
    done
}

# --- Process subscriptions in chunks, reporting progress after each chunk ---
for ((i = 0; i < TOTAL_SUBS; i += CHUNK_SIZE)); do
    chunk=("${ALL_SUBS[@]:i:CHUNK_SIZE}")
    echo "Scanning subscriptions $((i + 1))-$((i + ${#chunk[@]})) of $TOTAL_SUBS ..."

    run_query_for_chunk "$VNET_KQL_TEMPLATE" "${chunk[@]}"
    run_query_for_chunk "$NIC_KQL_TEMPLATE" "${chunk[@]}"

    DONE_SUBS=$((DONE_SUBS + ${#chunk[@]}))
    print_progress
done

echo ""
if [ "$TOTAL_FOUND" -eq 0 ]; then
    echo "Done. No custom DNS configuration found across the scanned subscriptions."
else
    echo "Done. Found $TOTAL_FOUND resource(s) with custom DNS configured."
    echo "Report written to: $OUTPUT_CSV"
    echo "Columns: Subscription, VNet/NIC, DNS Server (IP), New DNS Server (IP) [blank - fill in], Remarks [blank - fill in]"
fi
