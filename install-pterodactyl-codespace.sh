#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
# Pterodactyl Panel installer for GitHub Codespaces
# - Installs deps
# - Downloads latest official panel release
# - Sets up MariaDB + Redis
# - Configures .env
# - Runs migrations
# - Starts panel on port 8080
#
# Optional env vars before running:
#   PTERO_DB_NAME
#   PTERO_DB_USER
#   PTERO_DB_PASS
#   PTERO_ADMIN_EMAIL
#   PTERO_ADMIN_USERNAME
#   PTERO_ADMIN_FIRST_NAME
#   PTERO_ADMIN_LAST_NAME
#   PTERO_ADMIN_PASSWORD
# ==========================================

export DEBIAN_FRONTEND=noninteractive

APP_DIR="${APP_DIR:-$PWD/pterodactyl-panel}"
PANEL_PORT="${PANEL_PORT:-8080}"

PTERO_DB_NAME="${PTERO_DB_NAME:-panel}"
PTERO_DB_USER="${PTERO_DB_USER:-pterodactyl}"
PTERO_DB_PASS="${PTERO_DB_PASS:-$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)}"

PTERO_ADMIN_EMAIL="${PTERO_ADMIN_EMAIL:-}"
PTERO_ADMIN_USERNAME="${PTERO_ADMIN_USERNAME:-admin}"
PTERO_ADMIN_FIRST_NAME="${PTERO_ADMIN_FIRST_NAME:-Admin}"
PTERO_ADMIN_LAST_NAME="${PTERO_ADMIN_LAST_NAME:-User}"
PTERO_ADMIN_PASSWORD="${PTERO_ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

log() {
  echo
  echo "==> $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

detect_app_url() {
  if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
    echo "https://${CODESPACE_NAME}-${PANEL_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  else
    echo "http://127.0.0.1:${PANEL_PORT}"
  fi
}

start_service_safe() {
  local svc="$1"
  $SUDO service "$svc" start >/dev/null 2>&1 || true
}

wait_for_mysql() {
  for _ in {1..30}; do
    if mysqladmin ping --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "MariaDB did not become ready in time." >&2
  exit 1
}

APP_URL="$(detect_app_url)"

log "Updating apt and installing packages"
$SUDO apt-get update
$SUDO apt-get install -y \
  curl ca-certificates unzip tar git redis-server mariadb-server nginx \
  php php-cli php-fpm php-mysql php-gd php-mbstring php-bcmath php-xml php-curl php-zip \
  composer jq openssl

require_cmd curl
require_cmd tar
require_cmd php
require_cmd composer
require_cmd mysql

log "Starting MariaDB and Redis with service (Codespaces-friendly)"
start_service_safe mariadb
start_service_safe mysql
start_service_safe redis-server

wait_for_mysql

log "Creating app directory"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

log "Downloading latest official Pterodactyl Panel release"
curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz

log "Setting permissions"
mkdir -p storage/logs bootstrap/cache
chmod -R 755 storage bootstrap/cache || true

if [[ ! -f ".env" ]]; then
  cp .env.example .env
fi

log "Installing PHP dependencies"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

log "Generating application key"
php artisan key:generate --force

log "Creating MariaDB database and user"
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${PTERO_DB_NAME}\`;
CREATE USER IF NOT EXISTS '${PTERO_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PTERO_DB_PASS}';
CREATE USER IF NOT EXISTS '${PTERO_DB_USER}'@'localhost' IDENTIFIED BY '${PTERO_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PTERO_DB_NAME}\`.* TO '${PTERO_DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${PTERO_DB_NAME}\`.* TO '${PTERO_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

log "Writing .env settings"
sed -i "s|^APP_ENV=.*|APP_ENV=production|" .env
sed -i "s|^APP_DEBUG=.*|APP_DEBUG=true|" .env
sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env

sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|" .env
sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|^DB_PORT=.*|DB_PORT=3306|" .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${PTERO_DB_NAME}|" .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${PTERO_DB_USER}|" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${PTERO_DB_PASS}|" .env

sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=file|" .env
sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=file|" .env
sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env

if grep -q '^REDIS_HOST=' .env; then
  sed -i "s|^REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env
else
  echo "REDIS_HOST=127.0.0.1" >> .env
fi

if grep -q '^REDIS_PASSWORD=' .env; then
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=null|" .env
else
  echo "REDIS_PASSWORD=null" >> .env
fi

if grep -q '^REDIS_PORT=' .env; then
  sed -i "s|^REDIS_PORT=.*|REDIS_PORT=6379|" .env
else
  echo "REDIS_PORT=6379" >> .env
fi

log "Running database migrations and seeders"
php artisan migrate --seed --force

log "Linking storage and caching config"
php artisan storage:link || true
php artisan config:clear || true
php artisan config:cache || true
php artisan route:cache || true
php artisan view:cache || true

if [[ -n "$PTERO_ADMIN_EMAIL" ]]; then
  log "Creating admin user"
  php artisan p:user:make \
    --email="$PTERO_ADMIN_EMAIL" \
    --username="$PTERO_ADMIN_USERNAME" \
    --name-first="$PTERO_ADMIN_FIRST_NAME" \
    --name-last="$PTERO_ADMIN_LAST_NAME" \
    --password="$PTERO_ADMIN_PASSWORD" \
    --admin=1
else
  log "Skipping admin creation because PTERO_ADMIN_EMAIL was not set"
fi

log "Starting queue worker in background"
pkill -f "artisan queue:work" >/dev/null 2>&1 || true
nohup php artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 \
  > storage/logs/queue-worker.log 2>&1 &

log "Starting Pterodactyl on 0.0.0.0:${PANEL_PORT}"
pkill -f "artisan serve --host=0.0.0.0 --port=${PANEL_PORT}" >/dev/null 2>&1 || true
nohup php artisan serve --host=0.0.0.0 --port="${PANEL_PORT}" \
  > storage/logs/panel-web.log 2>&1 &

cat <<EOF

==========================================
Pterodactyl Panel installed in Codespaces
==========================================

App directory:
  ${APP_DIR}

Panel URL:
  ${APP_URL}

Database:
  name=${PTERO_DB_NAME}
  user=${PTERO_DB_USER}
  pass=${PTERO_DB_PASS}

Admin login:
EOF

if [[ -n "$PTERO_ADMIN_EMAIL" ]]; then
  cat <<EOF
  email=${PTERO_ADMIN_EMAIL}
  username=${PTERO_ADMIN_USERNAME}
  password=${PTERO_ADMIN_PASSWORD}
EOF
else
  cat <<EOF
  Not created automatically.
  Create one manually with:
    cd ${APP_DIR}
    php artisan p:user:make
EOF
fi

cat <<EOF

Logs:
  tail -f ${APP_DIR}/storage/logs/panel-web.log
  tail -f ${APP_DIR}/storage/logs/queue-worker.log

Important:
- In Codespaces, make sure port ${PANEL_PORT} is forwarded.
- If the forwarded URL opens but looks broken, refresh after ~10 seconds.
- This sets up the Panel only. Wings/game server nodes are a separate step.

EOF
