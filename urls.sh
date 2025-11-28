#!/bin/bash

# require sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
    exit 1
fi

echo

#
# === get IP ===
#

HOST_IP_OVERRIDE=""
CURRENT_HOST_IP=""
if [ -z "$HOST_IP_OVERRIDE" ]; then
    DETECTED_HOST_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$DETECTED_HOST_IP" ]; then
        echo "Warning: Could not automatically determine host IP address using 'hostname -I'."
        echo "Please ensure 'hostname -I' works or set HOST_IP_OVERRIDE manually in the script."
        echo "Defaulting to 'localhost' for display purposes, but this might not be accurate for external access."
        CURRENT_HOST_IP="localhost"
    else
        CURRENT_HOST_IP="$DETECTED_HOST_IP"
    fi
else
    CURRENT_HOST_IP="$HOST_IP_OVERRIDE"
fi

CONTAINER_IDS=$(docker ps -q)

if [ -z "$CONTAINER_IDS" ]; then
    echo "No running Docker containers found."
    exit 0
fi

#
# === show HTTP endpoints ===
#

TEMP_HTTP_ENDPOINTS_FILE=$(mktemp)

for ID in $CONTAINER_IDS; do
    CONTAINER_INFO=$(docker inspect --format '{"Name":"{{.Name}}", "Ports":{{json .NetworkSettings.Ports}}}' "$ID")
    CONTAINER_NAME=$(echo "$CONTAINER_INFO" | jq -r '.Name | ltrimstr("/")')
    PORTS_JSON=$(echo "$CONTAINER_INFO" | jq -r '.Ports')

    if [ "$PORTS_JSON" == "null" ] || [ -z "$PORTS_JSON" ]; then
        continue
    fi
    echo "$PORTS_JSON" | jq -r 'to_entries[] | select(.value != null) | .value[0].HostIp + ":" + .value[0].HostPort' | while read -r HOST_MAPPING; do
        HOST_PORT=$(echo "$HOST_MAPPING" | cut -d':' -f2)
        ENDPOINT="http://${CURRENT_HOST_IP}:${HOST_PORT} (${CONTAINER_NAME})"
        echo "$ENDPOINT" >> "$TEMP_HTTP_ENDPOINTS_FILE"
    done
done

if [ -s "$TEMP_HTTP_ENDPOINTS_FILE" ]; then
    sort -u "$TEMP_HTTP_ENDPOINTS_FILE"
else
    echo "No HTTP endpoints found based on exposed host ports for running containers."
fi

rm -f "$TEMP_HTTP_ENDPOINTS_FILE"

#
# === show HTTPS endpoints ===
#

echo

NGINX_CONTAINER_NAME="nginx"

if ! docker ps --format "{{.Names}}" | grep -q "^${NGINX_CONTAINER_NAME}$"; then
    echo "Error: Nginx container '$NGINX_CONTAINER_NAME' not found or not running."
    echo "Please ensure the container is named 'nginx' and it is currently running."
    exit 1
fi

NGINX_CONFIG_CONTENT=$(docker exec "$NGINX_CONTAINER_NAME" sh -c "
    find /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ -maxdepth 1 -type f -name '*.conf' 2>/dev/null | xargs -r cat 2>/dev/null || cat /etc/nginx/nginx.conf 2>/dev/null
")

if [ -z "$NGINX_CONFIG_CONTENT" ]; then
    echo "Error: Could not retrieve Nginx configuration from container '$NGINX_CONTAINER_NAME'."
    echo "Ensure Nginx is installed and configuration files exist inside the container."
    exit 1
fi

LOCATION_PATHS=$(echo "$NGINX_CONFIG_CONTENT" | \
    grep -oE 'location\s+(\/[^ {;]+)' | \
    awk '{print $2}' | \
    grep -E '^\/')

TEMP_HTTPS_ENDPOINTS_FILE=$(mktemp)

if [ -z "$LOCATION_PATHS" ]; then
    echo "Warning: No exposed paths (location directives starting with '/') found in the Nginx configuration."
    echo "Please verify your Nginx configuration inside the container."
else
    echo "$LOCATION_PATHS" | while IFS= read -r path; do
        if [ "$path" == "/" ]; then
            echo "https://${CURRENT_HOST_IP}/" >> "$TEMP_HTTPS_ENDPOINTS_FILE"
        else
            if [[ "$path" != */ ]]; then
                echo "https://${CURRENT_HOST_IP}${path}/" >> "$TEMP_HTTPS_ENDPOINTS_FILE"
            else
                echo "https://${CURRENT_HOST_IP}${path}" >> "$TEMP_HTTPS_ENDPOINTS_FILE"
            fi
        fi
    done
fi

if [ -s "$TEMP_HTTPS_ENDPOINTS_FILE" ]; then
    sort -u "$TEMP_HTTPS_ENDPOINTS_FILE"
else
    echo "No HTTPS endpoints found based on Nginx configuration."
fi

rm -f "$TEMP_HTTPS_ENDPOINTS_FILE"

echo