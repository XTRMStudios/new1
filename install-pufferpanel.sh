#!/usr/bin/env bash
set -euo pipefail

echo "==> Starting PufferPanel Codespaces installer"

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not available. Make sure Codespace is using devcontainer."
  exit 1
fi

# Detect compose
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Docker Compose not found."
  exit 1
fi

mkdir -p pufferpanel-data

echo "==> Starting PufferPanel container"
$COMPOSE_CMD up -d

echo "==> Waiting for PufferPanel to boot..."
sleep 10

# Prompt user input
echo
echo "=== Create Admin User ==="
read -p "Username: " PP_USER
read -p "Email: " PP_EMAIL
read -s -p "Password: " PP_PASS
echo
read -s -p "Confirm Password: " PP_PASS_CONFIRM
echo

# Check password match
if [ "$PP_PASS" != "$PP_PASS_CONFIRM" ]; then
  echo "❌ Passwords do not match. Restart script."
  exit 1
fi

echo "==> Creating admin user..."

docker exec -i pufferpanel /pufferpanel/pufferpanel user add <<EOF
$PP_USER
$PP_EMAIL
$PP_PASS
$PP_PASS
y
EOF

echo
echo "✅ Admin user created successfully!"

echo
echo "🌐 Open PufferPanel:"
echo "➡️ Go to the Ports tab and open port 8080"
echo

echo "📋 Useful commands:"
echo "Logs: docker logs -f pufferpanel"
echo "Restart: $COMPOSE_CMD restart"
