#!/usr/bin/env bash
set -euo pipefail

echo "==> Starting PufferPanel Codespaces installer"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not available in this Codespace."
  echo "Make sure this repo is opened with the devcontainer config."
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Docker Compose is not available."
  exit 1
fi

mkdir -p pufferpanel-data

echo "==> Pulling and starting PufferPanel"
$COMPOSE_CMD up -d

echo "==> Waiting for container to come up"
sleep 8

echo "==> Current container status"
docker ps --filter "name=pufferpanel"

echo
echo "PufferPanel should now be running."
echo "Open the forwarded port 8080 in Codespaces."
echo
echo "To create your admin user, run:"
echo "docker exec -it pufferpanel /pufferpanel/pufferpanel user add"
echo
echo "To view logs, run:"
echo "docker logs -f pufferpanel"
