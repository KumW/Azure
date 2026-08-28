#!/usr/bin/env bash
# Standalone Azure SQL Database creator
# Creates a database on an EXISTING SQL logical server.

set -e

echo "=== Azure SQL Database Setup ==="
echo

# --- Check az CLI login ---
if ! az account show >/dev/null 2>&1; then
    echo "You're not logged into Azure CLI. Running 'az login'..."
    az login
fi

CURRENT_SUB=$(az account show --query "name" -o tsv)
echo "Current subscription: $CURRENT_SUB"
read -p "Use this subscription? (Y/n): " USE_SUB
USE_SUB=${USE_SUB:-Y}
if [[ "$USE_SUB" != "y" && "$USE_SUB" != "Y" ]]; then
    az account list --query "[].{Name:name, ID:id}" -o table
    read -p "Enter the Subscription ID to use: " SUB_ID
    az account set --subscription "$SUB_ID"
fi
echo

# --- Target server ---
read -p "Resource group of the existing server: " RESOURCE_GROUP
read -p "Existing SQL logical server name (without .database.windows.net): " SERVER_NAME

if ! az sql server show --name "$SERVER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Could not find server '$SERVER_NAME' in resource group '$RESOURCE_GROUP'. Check the names and try again."
    exit 1
fi
echo "Found server: $SERVER_NAME.database.windows.net"
echo

# --- Database details ---
read -p "Database name: " DB_NAME

echo "Select pricing tier / compute model:"
echo "  1) General Purpose - Provisioned"
echo "  2) General Purpose - Serverless"
echo "  3) Hyperscale"
echo "  4) Business Critical"
read -p "Choice (1-4): " TIER_CHOICE

read -p "vCore count (e.g. 2, 4, 8, 16) — press Enter for default (4): " VCORES
VCORES=${VCORES:-4}

# --- Storage preference ---
read -p "Max storage size (e.g. 32GB, 250GB, 500GB, 1TB) — press Enter for default (32GB): " MAX_SIZE
MAX_SIZE=${MAX_SIZE:-32GB}
echo "Using max storage size: $MAX_SIZE"

# --- Backup storage redundancy (applies to all editions) ---
echo
echo "Select backup storage redundancy:"
echo "  1) Geo-redundant (Geo)     [default] - backups copied to a paired region; protects against a full region outage"
echo "  2) Zone-redundant (Zone)             - backups replicated across availability zones within the same region"
echo "  3) Local-redundant (Local)           - backups kept on local storage in the same datacenter only; cheapest, least resilient"
read -p "Choice (1-3) [default: 1]: " REDUNDANCY_CHOICE
case "$REDUNDANCY_CHOICE" in
    2) BACKUP_REDUNDANCY="Zone" ;;
    3) BACKUP_REDUNDANCY="Local" ;;
    *) BACKUP_REDUNDANCY="Geo" ;;
esac
echo "Using backup storage redundancy: $BACKUP_REDUNDANCY"

case $TIER_CHOICE in
    1)
        echo "Creating General Purpose (Provisioned) database..."
        az sql db create \
            --resource-group "$RESOURCE_GROUP" \
            --server "$SERVER_NAME" \
            --name "$DB_NAME" \
            --edition GeneralPurpose \
            --family Gen5 \
            --capacity "$VCORES" \
            --max-size "$MAX_SIZE" \
            --backup-storage-redundancy "$BACKUP_REDUNDANCY"
        ;;
    2)
        read -p "Auto-pause delay in minutes (e.g. 60, or -1 to disable) — press Enter for default (60): " AUTOPAUSE
        AUTOPAUSE=${AUTOPAUSE:-60}
        echo "Using auto-pause delay: $AUTOPAUSE minutes"
        echo "Creating General Purpose (Serverless) database..."
        az sql db create \
            --resource-group "$RESOURCE_GROUP" \
            --server "$SERVER_NAME" \
            --name "$DB_NAME" \
            --edition GeneralPurpose \
            --family Gen5 \
            --compute-model Serverless \
            --capacity "$VCORES" \
            --auto-pause-delay "$AUTOPAUSE" \
            --max-size "$MAX_SIZE" \
            --backup-storage-redundancy "$BACKUP_REDUNDANCY"
        ;;
    3)
        echo "Creating Hyperscale database..."
        az sql db create \
            --resource-group "$RESOURCE_GROUP" \
            --server "$SERVER_NAME" \
            --name "$DB_NAME" \
            --edition Hyperscale \
            --family Gen5 \
            --capacity "$VCORES" \
            --max-size "$MAX_SIZE" \
            --backup-storage-redundancy "$BACKUP_REDUNDANCY"
        ;;
    4)
        echo "Creating Business Critical database..."
        az sql db create \
            --resource-group "$RESOURCE_GROUP" \
            --server "$SERVER_NAME" \
            --name "$DB_NAME" \
            --edition BusinessCritical \
            --family Gen5 \
            --capacity "$VCORES" \
            --max-size "$MAX_SIZE" \
            --backup-storage-redundancy "$BACKUP_REDUNDANCY"
        ;;
    *)
        echo "Invalid choice. Exiting without creating database."
        exit 1
        ;;
esac
echo

echo "=== Done ==="
echo "Server:   $SERVER_NAME.database.windows.net"
echo "Database: $DB_NAME"
echo
echo "Connection string (ADO.NET style, fill in your admin password):"
echo "Server=tcp:$SERVER_NAME.database.windows.net,1433;Initial Catalog=$DB_NAME;Persist Security Info=False;User ID=<admin-user>;Password=<your-password>;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
