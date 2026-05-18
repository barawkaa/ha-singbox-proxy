#!/usr/bin/with-contenv bashio

set -e

log_step() {
  bashio::log.info "[STAGE=$1] [RESULT=$2] $3"
}

log_error() {
  bashio::log.error "[STAGE=$1] [RESULT=ERROR] $2"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

SECRET="$(bashio::config 'secret')"
HTTP_PROXY_PORT="$(bashio::config 'http_proxy_port')"
SOCKS_PROXY_PORT="$(bashio::config 'socks_proxy_port')"
SOCKS_AUTH_ENABLED="$(bashio::config 'socks_auth_enabled')"
HTTP_AUTH_ENABLED="$(bashio::config 'http_auth_enabled')"
PROXY_USERNAME="$(bashio::config 'proxy_username')"
PROXY_PASSWORD="$(bashio::config 'proxy_password')"
URLTEST_INTERVAL="$(bashio::config 'urltest_interval')"
URLTEST_TOLERANCE="$(bashio::config 'urltest_tolerance')"
LOG_LEVEL="$(bashio::config 'log_level')"
CONFIG_SERVERS_JSON="$(bashio::config 'servers_json')"

DEFAULT_SERVERS_FILE="/defaults/servers.json"

INBOUND_SOCKS_TAG="IN-SOCKS5-${SOCKS_PROXY_PORT}"
INBOUND_HTTP_TAG="IN-HTTP-${HTTP_PROXY_PORT}"

ESCAPED_SECRET="$(json_escape "${SECRET}")"
ESCAPED_PROXY_USERNAME="$(json_escape "${PROXY_USERNAME}")"
ESCAPED_PROXY_PASSWORD="$(json_escape "${PROXY_PASSWORD}")"

log_step "BOOT" "START" "Starting Sing-box Proxy add-on"
log_step "CONFIG" "OK" "HTTP proxy port=${HTTP_PROXY_PORT}; SOCKS5 proxy port=${SOCKS_PROXY_PORT}; dashboard/API port=9090; log_level=${LOG_LEVEL}"
log_step "CONFIG" "OK" "SOCKS5 auth=${SOCKS_AUTH_ENABLED}; HTTP auth=${HTTP_AUTH_ENABLED}; proxy_username=${PROXY_USERNAME}"
log_step "CONFIG" "OK" "urltest_interval=${URLTEST_INTERVAL}; urltest_tolerance=${URLTEST_TOLERANCE}"

mkdir -p /etc/sing-box
mkdir -p /etc/sing-box/ui

# Источник серверов:
# 1) Если servers_json в настройках add-on заполнен и не равен [] — используем его.
# 2) Если servers_json пустой или [] — используем файл /defaults/servers.json,
#    который копируется из /addons/singbox-proxy/servers.json при сборке add-on.
SERVERS_JSON_TRIMMED="$(printf '%s' "${CONFIG_SERVERS_JSON}" | tr -d '[:space:]')"

if [ -n "${SERVERS_JSON_TRIMMED}" ] && [ "${SERVERS_JSON_TRIMMED}" != "[]" ]; then
  SERVERS_JSON="${CONFIG_SERVERS_JSON}"
  log_step "SERVERS_SOURCE" "OK" "Using servers_json from add-on configuration"
else
  if [ ! -f "${DEFAULT_SERVERS_FILE}" ]; then
    log_error "SERVERS_SOURCE" "servers_json is empty and ${DEFAULT_SERVERS_FILE} not found"
    exit 1
  fi

  SERVERS_JSON="$(cat "${DEFAULT_SERVERS_FILE}")"
  log_step "SERVERS_SOURCE" "OK" "Using default servers file: ${DEFAULT_SERVERS_FILE}"
fi

cat > /etc/sing-box/ui/config.js <<EOF
window.SINGBOX_DASHBOARD_CONFIG = {
  secret: "${ESCAPED_SECRET}"
};
EOF

cat > /etc/sing-box/ui/servers.json <<EOF
${SERVERS_JSON}
EOF

log_step "UI" "OK" "Generated UI config.js and servers.json"

SERVER_TAGS="$(printf '%s\n' "${SERVERS_JSON}" | grep -oE '"tag"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"tag"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"

if [ -z "${SERVER_TAGS}" ]; then
  log_error "SERVERS" "No server tags found. Check servers_json or /addons/singbox-proxy/servers.json"
  exit 1
fi

SERVER_COUNT="$(printf '%s\n' "${SERVER_TAGS}" | grep -c . || true)"
log_step "SERVERS" "OK" "Found ${SERVER_COUNT} server tags"

SELECTOR_LIST='"auto"'
URLTEST_LIST=''

while IFS= read -r TAG; do
  ESCAPED_TAG="$(json_escape "${TAG}")"
  SELECTOR_LIST="${SELECTOR_LIST}, \"${ESCAPED_TAG}\""

  if [ -z "${URLTEST_LIST}" ]; then
    URLTEST_LIST="\"${ESCAPED_TAG}\""
  else
    URLTEST_LIST="${URLTEST_LIST}, \"${ESCAPED_TAG}\""
  fi

  log_step "SERVERS" "LOADED" "tag=${TAG}"
done <<EOF
${SERVER_TAGS}
EOF

SERVER_OUTBOUNDS="$(printf '%s\n' "${SERVERS_JSON}" | sed '1s/^[[:space:]]*\[//' | sed '$s/\][[:space:]]*$//')"

SOCKS_AUTH_BLOCK=""
HTTP_AUTH_BLOCK=""

if [ "${SOCKS_AUTH_ENABLED}" = "true" ]; then
  SOCKS_AUTH_BLOCK=", 
      \"users\": [
        {
          \"username\": \"${ESCAPED_PROXY_USERNAME}\",
          \"password\": \"${ESCAPED_PROXY_PASSWORD}\"
        }
      ]"
fi

if [ "${HTTP_AUTH_ENABLED}" = "true" ]; then
  HTTP_AUTH_BLOCK=", 
      \"users\": [
        {
          \"username\": \"${ESCAPED_PROXY_USERNAME}\",
          \"password\": \"${ESCAPED_PROXY_PASSWORD}\"
        }
      ]"
fi

cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "${LOG_LEVEL}",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "/etc/sing-box/ui",
      "secret": "${ESCAPED_SECRET}"
    }
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "${INBOUND_SOCKS_TAG}",
      "listen": "0.0.0.0",
      "listen_port": ${SOCKS_PROXY_PORT}${SOCKS_AUTH_BLOCK}
    },
    {
      "type": "http",
      "tag": "${INBOUND_HTTP_TAG}",
      "listen": "0.0.0.0",
      "listen_port": ${HTTP_PROXY_PORT}${HTTP_AUTH_BLOCK}
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "Proxy",
      "outbounds": [${SELECTOR_LIST}],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": [${URLTEST_LIST}],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "${URLTEST_INTERVAL}",
      "tolerance": ${URLTEST_TOLERANCE}
    },
    ${SERVER_OUTBOUNDS},
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "Proxy",
    "auto_detect_interface": true
  }
}
EOF

log_step "CONFIG_GENERATE" "OK" "Generated /etc/sing-box/config.json"
log_step "INBOUND" "READY" "tag=${INBOUND_SOCKS_TAG}; type=socks; auth=${SOCKS_AUTH_ENABLED}; listen=0.0.0.0:${SOCKS_PROXY_PORT}; purpose=SOCKS5 proxy for Telegram/apps"
log_step "INBOUND" "READY" "tag=${INBOUND_HTTP_TAG}; type=http; auth=${HTTP_AUTH_ENABLED}; listen=0.0.0.0:${HTTP_PROXY_PORT}; purpose=HTTP proxy for Switch/browser"
log_step "OUTBOUND" "READY" "selector=Proxy; default=auto; servers=${SERVER_COUNT}"
log_step "DASHBOARD" "READY" "Clash API and built-in dashboard will listen on 0.0.0.0:9090"
log_step "SING_BOX" "START" "Starting sing-box core"

/usr/local/bin/sing-box run -c /etc/sing-box/config.json
