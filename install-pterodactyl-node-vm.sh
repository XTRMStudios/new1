#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

PANEL_URL="${PANEL_URL:-}"
AUTO_DEPLOY_TOKEN="${AUTO_DEPLOY_TOKEN:-}"
NODE_FQDN="${NODE_FQDN:-}"
WINGS_PORT="${WINGS_PORT:-8080}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

log() {
  echo
  echo "==> $*"
}

ask() {
  local var="$1"
  local prompt="$2"
  local default="${3:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " value
    value="${value:-$default}"
  else
    read -rp "$prompt: " value
  fi
  printf -v "$var" '%s' "$value"
}

ask_secret() {
  local var="$1"
  local prompt="$2"
  local default="${3:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -rsp "$prompt [$default]: " value
    echo
    value="${value:-$default}"
  else
    read -rsp "$prompt: " value
    echo
  fi
  printf -v "$var" '%s' "$value"
}

if [[ -z "$PANEL_URL" ]]; then
  ask PANEL_URL "Panel URL (example: https://panel.legionmc.uk)"
fi

if [[ -z "$AUTO_DEPLOY_TOKEN" ]]; then
  ask_secret AUTO_DEPLOY_TOKEN "Auto-Deploy token from Panel > Node > Configuration"
fi

if [[ -z "$NODE_FQDN" ]]; then
  ask NODE_FQDN "Node FQDN or VM IP (optional)" ""
fi

log "Installing prerequisites"
$SUDO apt-get update
$SUDO apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https software-properties-common

log "Installing Docker"
curl -fsSL https://get.docker.com | $SUDO bash

log "Starting Docker"
$SUDO systemctl enable --now docker

log "Installing Wings"
ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then
  WINGS_ARCH="amd64"
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  WINGS_ARCH="arm64"
else
  echo "Unsupported architecture: $ARCH"
  exit 1
fi

curl -L "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}" -o /tmp/wings
chmod +x /tmp/wings
$SUDO mv /tmp/wings /usr/local/bin/wings

log "Creating Wings directory"
$SUDO mkdir -p /etc/pterodactyl

log "Configuring Wings from auto-deploy token"
$SUDO wings configure --panel-url "$PANEL_URL" --token "$AUTO_DEPLOY_TOKEN"

log "Creating systemd service"
$SUDO tee /etc/systemd/system/wings.service >/dev/null <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=always
RestartSec=5s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

log "Testing Wings config"
$SUDO wings --debug &
WINGS_TEST_PID=$!
sleep 8
kill "$WINGS_TEST_PID" >/dev/null 2>&1 || true

log "Starting Wings service"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now wings

echo
echo "=============================================="
echo "Pterodactyl Node installed in VirtualBox VM"
echo "=============================================="
echo "Panel URL: $PANEL_URL"
if [[ -n "$NODE_FQDN" ]]; then
  echo "Node FQDN/IP: $NODE_FQDN"
fi
echo
echo "Check status:"
echo "  sudo systemctl status wings"
echo "  journalctl -u wings -f"
echo
echo "Important:"
echo "  - Create the node in the panel first."
echo "  - Use the Auto-Deploy token from the node Configuration page."
echo "  - Do not put Wings behind Cloudflare Tunnel."
echo "  - Use a direct VM IP or DNS record with proxy OFF."
