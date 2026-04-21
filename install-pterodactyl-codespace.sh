#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

APP_DIR="${APP_DIR:-$PWD/pterodactyl-panel}"
PANEL_PORT="${PANEL_PORT:-8080}"

DB_NAME="${PTERO_DB_NAME:-panel}"
DB_USER="${PTERO_DB_USER:-pterodactyl}"
DB_PASS="${PTERO_DB_PASS:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)}"

ADMIN_EMAIL="${PTERO_ADMIN_EMAIL:-}"
ADMIN_USERNAME="${PTERO_ADMIN_USERNAME:-admin}"
ADMIN_FIRST="${PTERO_ADMIN_FIRST_NAME:-Admin}"
ADMIN_LAST="${PTERO_ADMIN_LAST_NAME:-User}"
ADMIN_PASSWORD="${PTERO_ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)}"

PHP_BIN="/usr/bin/php8.3"
COMPOSER_BIN="/usr/bin/composer"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

log() {
  echo
  echo "==> $*"
}

start_service() {
  $SUDO service "$1" start >/dev/null 2>&1 || true
}

wait_for_mysql() {
  for _ in {1..30}; do
    if $SUDO mysqladmin ping --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "MariaDB failed to start."
  exit 1
}

detect_url() {
  if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
    echo "https://${CODESPACE_NAME}-${PANEL_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  else
    echo "http://127.0.0.1:${PANEL_PORT}"
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

APP_URL="$(detect_url)"

log "Installing packages"
$SUDO apt-get update
$SUDO apt-get install -y \
  curl ca-certificates unzip tar git jq openssl \
  mariadb-server mariadb-client redis-server redis-tools nginx \
  php8.3 php8.3-cli php8.3-common php8.3-mysql php8.3-gd php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-intl php8.3-sqlite3 php8.3-readline \
  composer

log "Checking PHP"
[[ -x "$PHP_BIN" ]] || { echo "Missing $PHP_BIN"; exit 1; }
"$PHP_BIN" -m | grep -qi '^pdo_mysql$' || { echo "Missing pdo_mysql"; exit 1; }
"$PHP_BIN" -m | grep -qi '^zip$' || { echo "Missing zip"; exit 1; }
"$PHP_BIN" -m | grep -qi '^bcmath$' || { echo "Missing bcmath"; exit 1; }
"$PHP_BIN" -m | grep -qi '^sodium$' || { echo "Missing sodium"; exit 1; }

log "Starting MariaDB and Redis"
start_service mariadb
start_service mysql
start_service redis-server
wait_for_mysql

log "Preparing app directory"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

log "Downloading latest Pterodactyl Panel"
curl -fsSL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz

log "Preparing .env"
cp .env.example .env

log "Installing composer dependencies"
COMPOSER_ALLOW_SUPERUSER=1 "$PHP_BIN" "$COMPOSER_BIN" install --no-dev --optimize-autoloader

log "Creating database and user"
$SUDO mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

log "Writing environment settings"
set_env_value APP_ENV production
set_env_value APP_DEBUG true
set_env_value APP_URL "$APP_URL"
set_env_value APP_TIMEZONE UTC

set_env_value DB_CONNECTION mysql
set_env_value DB_HOST 127.0.0.1
set_env_value DB_PORT 3306
set_env_value DB_DATABASE "$DB_NAME"
set_env_value DB_USERNAME "$DB_USER"
set_env_value DB_PASSWORD "$DB_PASS"

set_env_value BROADCAST_CONNECTION log
set_env_value CACHE_STORE file
set_env_value FILESYSTEM_DISK local
set_env_value QUEUE_CONNECTION redis
set_env_value SESSION_DRIVER file
set_env_value SESSION_LIFETIME 120

set_env_value REDIS_HOST 127.0.0.1
set_env_value REDIS_PASSWORD null
set_env_value REDIS_PORT 6379

set_env_value MAIL_MAILER log
set_env_value MAIL_HOST 127.0.0.1
set_env_value MAIL_PORT 1025
set_env_value MAIL_USERNAME null
set_env_value MAIL_PASSWORD null
set_env_value MAIL_FROM_ADDRESS panel@example.com
set_env_value MAIL_FROM_NAME Pterodactyl

log "Generating application key"
"$PHP_BIN" artisan key:generate --force

log "Testing database connection"
mysql -h 127.0.0.1 -u "$DB_USER" -p"$DB_PASS" -e "USE \`${DB_NAME}\`; SELECT 1;" >/dev/null

log "Fixing permissions"
mkdir -p storage/logs bootstrap/cache
chmod -R 755 storage bootstrap/cache || true

log "Clearing cached config"
"$PHP_BIN" artisan config:clear || true
"$PHP_BIN" artisan cache:clear || true
"$PHP_BIN" artisan view:clear || true

log "Running migrations"
"$PHP_BIN" artisan migrate --seed --force

log "Final cache build"
"$PHP_BIN" artisan storage:link || true
"$PHP_BIN" artisan config:cache || true
"$PHP_BIN" artisan route:cache || true
"$PHP_BIN" artisan view:cache || true

if [[ -n "$ADMIN_EMAIL" ]]; then
  log "Creating admin user"
  "$PHP_BIN" artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USERNAME" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST" \
    --password="$ADMIN_PASSWORD" \
    --admin=1
else
  log "Skipping admin creation because PTERO_ADMIN_EMAIL is not set"
fi

log "Stopping old processes"
pkill -f "artisan queue:work" >/dev/null 2>&1 || true
pkill -f "artisan serve --host=0.0.0.0 --port=${PANEL_PORT}" >/dev/null 2>&1 || true

log "Starting queue worker"
nohup "$PHP_BIN" artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 \
  > storage/logs/queue-worker.log 2>&1 &

log "Starting panel on port ${PANEL_PORT}"
nohup "$PHP_BIN" artisan serve --host=0.0.0.0 --port="${PANEL_PORT}" \
  > storage/logs/panel-web.log 2>&1 &

echo
echo "=============================================="
echo "Pterodactyl Panel installed in Codespaces"
echo "=============================================="
echo "URL: $APP_URL"
echo "App dir: $APP_DIR"
echo "DB name: $DB_NAME"
echo "DB user: $DB_USER"
echo "DB pass: $DB_PASS"
echo "PHP binary: $PHP_BIN"
if [[ -n "$ADMIN_EMAIL" ]]; then
  echo "Admin email: $ADMIN_EMAIL"
  echo "Admin username: $ADMIN_USERNAME"
  echo "Admin password: $ADMIN_PASSWORD"
else
  echo "Admin account not auto-created."
  echo "Create one with:"
  echo "  cd $APP_DIR && $PHP_BIN artisan p:user:make"
fi
echo
echo "Logs:"
echo "  tail -f $APP_DIR/storage/logs/panel-web.log"
echo "  tail -f $APP_DIR/storage/logs/queue-worker.log"
echo
echo "Make sure port ${PANEL_PORT} is forwarded in Codespaces."
