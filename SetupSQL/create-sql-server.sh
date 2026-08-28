#!/usr/bin/env bash
# Standalone Azure SQL Logical Server creator
# Creates the server + optional firewall rules. Does NOT create a database.

set -e

echo "=== Azure SQL Logical Server Setup ==="
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

# --- Resource group ---
read -p "Resource group name: " RESOURCE_GROUP
if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Resource group '$RESOURCE_GROUP' already exists — reusing it."
else
    read -p "Resource group doesn't exist. Region to create it in (e.g. southeastasia): " LOCATION
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
    echo "Resource group created."
fi
echo

# --- Location (needed for server even if RG existed) ---
LOCATION=$(az group show --name "$RESOURCE_GROUP" --query "location" -o tsv)
echo "Using region: $LOCATION"
echo

# --- Server details ---
read -p "New SQL logical server name (must be globally unique, lowercase, no spaces): " SERVER_NAME
read -p "Admin username: " ADMIN_USER

while true; do
    read -s -p "Admin password (min 8 chars, upper/lower/number/symbol): " ADMIN_PASSWORD
    echo
    read -s -p "Confirm password: " ADMIN_PASSWORD_CONFIRM
    echo
    if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
        break
    else
        echo "Passwords didn't match. Try again."
    fi
done
echo

echo "Creating SQL logical server '$SERVER_NAME'..."
az sql server create \
    --name "$SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --admin-user "$ADMIN_USER" \
    --admin-password "$ADMIN_PASSWORD"
echo "Server created: $SERVER_NAME.database.windows.net"
echo

# --- Firewall rules ---
read -p "Allow your current public IP through the firewall? (Y/n): " ALLOW_MY_IP
ALLOW_MY_IP=${ALLOW_MY_IP:-Y}
if [[ "$ALLOW_MY_IP" == "y" || "$ALLOW_MY_IP" == "Y" ]]; then
    MY_IP=$(curl -s ifconfig.me)
    echo "Detected public IP: $MY_IP"
    az sql server firewall-rule create \
        --resource-group "$RESOURCE_GROUP" \
        --server "$SERVER_NAME" \
        --name "AllowMyIP" \
        --start-ip-address "$MY_IP" \
        --end-ip-address "$MY_IP"
    echo "Firewall rule added for $MY_IP"
fi

read -p "Allow all Azure services to connect (0.0.0.0 rule)? (Y/n): " ALLOW_AZURE
ALLOW_AZURE=${ALLOW_AZURE:-Y}
if [[ "$ALLOW_AZURE" == "y" || "$ALLOW_AZURE" == "Y" ]]; then
    az sql server firewall-rule create \
        --resource-group "$RESOURCE_GROUP" \
        --server "$SERVER_NAME" \
        --name "AllowAzureServices" \
        --start-ip-address "0.0.0.0" \
        --end-ip-address "0.0.0.0"
    echo "Azure services firewall rule added."
fi
echo

echo "=== Done ==="
echo "Server:         $SERVER_NAME.database.windows.net"
echo "Resource group: $RESOURCE_GROUP"
echo "Admin:          $ADMIN_USER"
echo
echo "Next step: run create-sql-db.sh to create a database on this server."
