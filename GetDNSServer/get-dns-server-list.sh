#!/usr/bin/env bash
#
# get-azure-custom-dns-report-graph.sh  (speed-optimized)
#
# Scans Azure Virtual Networks and Network Interfaces (NICs) with custom DNS
# configured, across MANY subscriptions at once, using Azure Resource Graph.
#
# Custom DNS in Azure lives at two levels:
#   - VNet level : dhcpOptions.dnsServers
#   - NIC level  : dnsSettings.dnsServers  (overrides the VNet for that NIC)
# Subnets don't have an independent DNS setting - they inherit from the VNet.
#
# WHAT CHANGED VS THE ORIGINAL (and why it's faster):
#   1. VNet + NIC are now ONE combined KQL query (via `union`) instead of two
#      separate `az graph query` calls per chunk -> half the round trips.
#   2. CHUNK_SIZE raised from 15 -> 200. Resource Graph's subscription list
#      per call isn't the bottleneck (it comfortably takes hundreds); the
#      bottleneck is the number of separate CLI invocations, each of which
#      pays a fixed ~1-2s `az` startup/auth tax. Fewer, bigger chunks wins.
#   3. Chunks are now run IN PARALLEL (default 6 concurrent `az graph query`
#      processes) instead of strictly sequentially. This is a network-bound
#      task, so concurrency is where the real wall-clock win comes from.
#   4. Each parallel job writes to its own temp file (safe under concurrency)
#      and results are concatenated at the end in order, so output is
#      identical to a sequential run - just much faster to produce.
#   5. Progress is reported as each chunk job completes, not just at chunk
#      boundaries, so you still get visible feedback under parallelism.
#   6. Subscriptions with no VNet/NIC at all, or none with custom DNS
#      configured, still get a row - "N/A" in the VNet/NIC and DNS Server
#      columns - so the report is a complete list of every subscription
#      scanned, not just the ones with something to report.
#   7. Subscriptions that are not in "Enabled" state (disabled, expired,
#      past due, etc.) are skipped automatically - no point querying
#      resources in a subscription you can't act on. Applies whether the
#      subscription list comes from auto-discovery or from explicit IDs
#      passed on the command line.
#   8. Any subscription named "sirim" (case-insensitive) is always skipped.
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
#   Tunables (env vars):
#     CHUNK_SIZE=200      subscriptions per Resource Graph call
#     MAX_PARALLEL=6      concurrent `az graph query` processes
#     PAGE_SIZE=1000      Resource Graph max rows per page
#
# OUTPUT
#   azure-custom-dns-report.csv, columns:
#     Subscription, VNet/NIC, DNS Server (IP), New DNS Server (IP), Remarks
#   ("New DNS Server (IP)" and "Remarks" are left blank for you to fill in
#   as you plan/track remediation.)
#   Subscriptions with no VNet/NIC, or none with custom DNS, get a single
#   row with "N/A" in the VNet/NIC and DNS Server (IP) columns.

set -euo pipefail

OUTPUT_CSV="azure-custom-dns-report.csv"
CHUNK_SIZE="${CHUNK_SIZE:-200}"     # subscriptions per Resource Graph call
MAX_PARALLEL="${MAX_PARALLEL:-6}"  # concurrent az graph query processes
PAGE_SIZE="${PAGE_SIZE:-1000}"     # Resource Graph max rows per page

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

# --- Full subscription inventory (id, name, state) - used both to resolve
#     names later in the report and to filter out subs we should skip. ---
SUB_MAP=$(az account list --query "[].{id:id,name:name,state:state}" -o json)

if [ "$#" -gt 0 ]; then
    CANDIDATE_SUBS=("$@")
else
    mapfile -t CANDIDATE_SUBS < <(echo "$SUB_MAP" | jq -r '.[].id')
fi

# --- Filter out: subscriptions not in "Enabled" state (disabled/expired/
#     past due etc.), and any subscription named "sirim" (case-insensitive).
FILTER_RESULT=$(printf '%s\n' "${CANDIDATE_SUBS[@]}" | jq -R -s --argjson submap "$SUB_MAP" '
    (split("\n") | map(select(length > 0))) as $ids
    | ($ids | map(. as $id | ($submap[] | select(.id == $id)) // {id: $id, name: $id, state: "unknown"})) as $subs
    | {
        keep:     [ $subs[] | select(.state == "Enabled" and ((.name // "" ) | ascii_downcase | contains("sirim") | not)) | .id ],
        disabled: [ $subs[] | select(.state != "Enabled") | "\(.name) (\(.id)) - state: \(.state)" ],
        sirim:    [ $subs[] | select(.state == "Enabled" and ((.name // "") | ascii_downcase | contains("sirim"))) | "\(.name) (\(.id))" ]
      }')

mapfile -t ALL_SUBS < <(echo "$FILTER_RESULT" | jq -r '.keep[]')
mapfile -t SKIPPED_DISABLED < <(echo "$FILTER_RESULT" | jq -r '.disabled[]')
mapfile -t SKIPPED_SIRIM < <(echo "$FILTER_RESULT" | jq -r '.sirim[]')

if [ "${#SKIPPED_DISABLED[@]}" -gt 0 ]; then
    echo "Skipping ${#SKIPPED_DISABLED[@]} non-Enabled subscription(s):"
    printf '  - %s\n' "${SKIPPED_DISABLED[@]}"
fi
if [ "${#SKIPPED_SIRIM[@]}" -gt 0 ]; then
    echo "Skipping ${#SKIPPED_SIRIM[@]} subscription(s) named 'sirim':"
    printf '  - %s\n' "${SKIPPED_SIRIM[@]}"
fi

TOTAL_SUBS=${#ALL_SUBS[@]}
echo "Found $TOTAL_SUBS subscription(s) to scan."
if [ "$TOTAL_SUBS" -eq 0 ]; then
    echo "Nothing to scan after filtering. Exiting."
    exit 0
fi

echo "\"Subscription\",\"VNet/NIC\",\"DNS Server (IP)\",\"New DNS Server (IP)\",\"Remarks\"" > "$OUTPUT_CSV"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Single combined query: VNets ∪ NICs with custom DNS, tagged by kind so we
# can build the same "VNet: x" / "NIC: y (VM: z)" labels as before.
COMBINED_KQL_TEMPLATE='
Resources
| where type =~ "microsoft.network/virtualnetworks" or type =~ "microsoft.network/networkinterfaces"
| extend isVnet = type =~ "microsoft.network/virtualnetworks"
| where (isVnet and isnotempty(properties.dhcpOptions.dnsServers))
     or (not(isVnet) and isnotempty(properties.dnsSettings.dnsServers))
| project subscriptionId,
          label = iff(isVnet,
                      strcat("VNet: ", name),
                      strcat("NIC: ", name,
                             iff(isnotempty(properties.virtualMachine.id),
                                 strcat(" (VM: ", tostring(split(tostring(properties.virtualMachine.id), "/")[-1]), ")"),
                                 " (unattached)"))),
          dnsServers = iff(isVnet, properties.dhcpOptions.dnsServers, properties.dnsSettings.dnsServers)
'

# --- Run one chunk: pages through results, writes its own temp CSV, and
#     drops a small status file so the parent can report progress/failures.
run_chunk () {
    local chunk_idx="$1"
    shift
    local chunk_subs=("$@")
    local outfile="$WORKDIR/chunk_${chunk_idx}.csv"
    local statusfile="$WORKDIR/chunk_${chunk_idx}.status"
    local skip=0
    local rows count total=0
    local seenfile="$WORKDIR/chunk_${chunk_idx}.seen"

    : > "$outfile"
    : > "$seenfile"

    while true; do
        if ! rows=$(az graph query -q "$COMBINED_KQL_TEMPLATE" --subscriptions "${chunk_subs[@]}" \
                 --first "$PAGE_SIZE" --skip "$skip" --query "data" -o json 2>"$WORKDIR/chunk_${chunk_idx}.err"); then
            echo "FAILED" > "$statusfile"
            return 1
        fi
        count=$(echo "$rows" | jq 'length')
        [ "$count" -eq 0 ] && break

        echo "$rows" | jq -r --argjson submap "$SUB_MAP" '
            .[] as $r
            | ($submap[] | select(.id == $r.subscriptionId) | .name) as $subname
            | ($r.dnsServers | join("; ")) as $dns
            | [$subname, $r.label, $dns, "", ""] | @csv' >> "$outfile"

        # Track which subscriptions actually had a matching resource, so we
        # can backfill "N/A" rows for the ones that didn't.
        echo "$rows" | jq -r '.[].subscriptionId' >> "$seenfile"

        total=$((total + count))
        [ "$count" -lt "$PAGE_SIZE" ] && break
        skip=$((skip + PAGE_SIZE))
    done

    # --- Backfill N/A rows for subscriptions in this chunk with no VNet/NIC
    #     at all, or none with custom DNS configured. ---
    sort -u "$seenfile" > "${seenfile}.sorted"
    local missing=()
    for sub in "${chunk_subs[@]}"; do
        grep -qxF "$sub" "${seenfile}.sorted" || missing+=("$sub")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '%s\n' "${missing[@]}" | jq -R -s --argjson submap "$SUB_MAP" '
            (split("\n") | map(select(length > 0))) as $ids
            | $ids[] as $id
            | (($submap[] | select(.id == $id) | .name) // $id) as $subname
            | [$subname, "N/A", "N/A", "", ""] | @csv' >> "$outfile"
    fi

    echo "$total" > "$statusfile"
}

# --- Build chunks ---
CHUNK_STARTS=()
for ((i = 0; i < TOTAL_SUBS; i += CHUNK_SIZE)); do
    CHUNK_STARTS+=("$i")
done
TOTAL_CHUNKS=${#CHUNK_STARTS[@]}
echo "Scanning in $TOTAL_CHUNKS chunk(s) of up to $CHUNK_SIZE subscriptions, $MAX_PARALLEL at a time..."

# --- Launch chunks with bounded parallelism (portable, no GNU parallel needed) ---
running=0
idx=0
for start in "${CHUNK_STARTS[@]}"; do
    chunk=("${ALL_SUBS[@]:start:CHUNK_SIZE}")
    run_chunk "$idx" "${chunk[@]}" &
    idx=$((idx + 1))
    running=$((running + 1))
    if [ "$running" -ge "$MAX_PARALLEL" ]; then
        wait -n
        running=$((running - 1))
    fi
done
wait   # drain remaining jobs

# --- Collect results in order, report progress/failures, tally totals ---
TOTAL_FOUND=0
FAILED_CHUNKS=()
for ((c = 0; c < TOTAL_CHUNKS; c++)); do
    statusfile="$WORKDIR/chunk_${c}.status"
    outfile="$WORKDIR/chunk_${c}.csv"
    if [ -f "$statusfile" ] && [ "$(cat "$statusfile")" = "FAILED" ]; then
        FAILED_CHUNKS+=("$c")
        echo "  Chunk $((c + 1))/$TOTAL_CHUNKS: FAILED (see $WORKDIR/chunk_${c}.err)" >&2
        continue
    fi
    n=$(cat "$statusfile" 2>/dev/null || echo 0)
    TOTAL_FOUND=$((TOTAL_FOUND + n))
    cat "$outfile" >> "$OUTPUT_CSV"
    echo "  Chunk $((c + 1))/$TOTAL_CHUNKS: $n resource(s) with custom DNS"
done

echo ""
if [ "${#FAILED_CHUNKS[@]}" -gt 0 ]; then
    echo "WARNING: ${#FAILED_CHUNKS[@]} chunk(s) failed - report is incomplete. See errors above." >&2
fi
if [ "$TOTAL_FOUND" -eq 0 ]; then
    echo "Done. No custom DNS configuration found across the scanned subscriptions."
else
    echo "Done. Found $TOTAL_FOUND resource(s) with custom DNS configured."
    echo "Report written to: $OUTPUT_CSV"
    echo "Columns: Subscription, VNet/NIC, DNS Server (IP), New DNS Server (IP) [blank - fill in], Remarks [blank - fill in]"
fi
