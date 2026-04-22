#!/usr/bin/env bash
set -euo pipefail

echo "==> Starting PufferPanel Codespaces installer"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not available. Make sure the Codespace is using the devcontainer."
  exit 1
fi

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

echo
echo "=== Create Admin User ==="
read -p "Username: " PP_USER
read -p "Email: " PP_EMAIL
read -s -p "Password: " PP_PASS
echo
read -s -p "Confirm Password: " PP_PASS_CONFIRM
echo

if [ "$PP_PASS" != "$PP_PASS_CONFIRM" ]; then
  echo "Passwords do not match."
  exit 1
fi

echo "==> Creating admin user..."

docker exec -i pufferpanel /pufferpanel/bin/pufferpanel user add <<EOF
$PP_USER
$PP_EMAIL
$PP_PASS
$PP_PASS
y
EOF

echo
echo "Admin user created successfully."
echo "Open the forwarded port 8080 in Codespaces."
echo
echo "Useful commands:"
echo "  docker logs -f pufferpanel"
echo "  $COMPOSE_CMD restart"
