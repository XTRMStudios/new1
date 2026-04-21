#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

APP_DIR="${APP_DIR:-$PWD/pterodactyl-panel}"
PANEL_PORT="${PANEL_PORT:-8080}"

DB_NAME="${PTERO_DB_NAME:-panel}"
DB_USER="${PTERO_DB_USER:-pterodactyl}"
DB_PASS="${PTERO_DB_PASS:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)}"

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
  local name="$1"
  $SUDO service "$name" start >/dev/null 2>&1 || true
}

wait_for_mysql() {
  for _ in {1..30}; do
    if mysqladmin ping --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "MariaDB did not start in time."
  exit 1
}

detect_url() {
  if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
    echo "https://${CODESPACE_NAME}-${PANEL_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  else
    echo "http://127.0.0.1:${PANEL_PORT}"
  fi
}

APP_URL="$(detect_url)"

log "Installing system packages"
$SUDO apt-get update
$SUDO apt-get install -y \
  curl ca-certificates unzip tar git jq openssl \
  mariadb-server redis-server nginx \
  php8.3 php8.3-cli php8.3-fpm php8.3-mysql php8.3-gd php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-intl php8.3-sqlite3 php8.3-common php8.3-readline libapache2-mod-php8.3 \
  php-cli php-fpm php-mysql php-gd php-mbstring php-bcmath php-xml php-curl php-zip php-intl \
  composer redis-tools mariadb-client

log "Checking PHP binary"
if [[ ! -x "$PHP_BIN" ]]; then
  echo "Expected PHP binary not found at $PHP_BIN"
  exit 1
fi

log "Checking required PHP extensions"
"$PHP_BIN" -m | grep -qi '^pdo_mysql$' || { echo "pdo_mysql missing"; exit 1; }
"$PHP_BIN" -m | grep -qi '^zip$' || { echo "zip missing"; exit 1; }
"$PHP_BIN" -m | grep -qi '^bcmath$' || { echo "bcmath missing"; exit 1; }
"$PHP_BIN" -m | grep -qi '^sodium$' || { echo "sodium missing"; exit 1; }

log "Starting MariaDB and Redis"
start_service mariadb
start_service mysql
start_service redis-server

wait_for_mysql

log "Preparing app directory"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

log "Downloading latest Pterodactyl Panel"
curl -fsSL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz

log "Preparing environment file"
if [[ ! -f ".env" ]]; then
  cp .env.example .env
fi

log "Installing PHP dependencies with forced PHP 8.3"
COMPOSER_ALLOW_SUPERUSER=1 "$PHP_BIN" "$COMPOSER_BIN" install --no-dev --optimize-autoloader

log "Generating app key"
"$PHP_BIN" artisan key:generate --force

log "Creating database and database user"
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

log "Writing environment config"
cat > .env <<EOF
APP_NAME=Pterodactyl
APP_ENV=production
APP_KEY=
APP_DEBUG=true
APP_URL=${APP_URL}

APP_TIMEZONE=UTC
APP_SERVICE_AUTHOR=unknown@example.com

TRUSTED_PROXIES=*
LOG_CHANNEL=stack
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

BROADCAST_DRIVER=log
CACHE_STORE=file
FILESYSTEM_DISK=local
QUEUE_CONNECTION=redis
SESSION_DRIVER=file
SESSION_LIFETIME=120

MEMCACHED_HOST=127.0.0.1

REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
MAIL_SCHEME=null
MAIL_HOST=127.0.0.1
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_FROM_ADDRESS="panel@example.com"
MAIL_FROM_NAME="Pterodactyl"

APP_ENVIRONMENT_ONLY=false
EOF

log "Regenerating app key into new .env"
"$PHP_BIN" artisan key:generate --force

log "Fixing permissions"
mkdir -p storage/logs bootstrap/cache
chmod -R 755 storage bootstrap/cache || true

log "Running migrations and seeds"
"$PHP_BIN" artisan migrate --seed --force

log "Storage and caches"
"$PHP_BIN" artisan storage:link || true
"$PHP_BIN" artisan config:clear || true
"$PHP_BIN" artisan cache:clear || true
"$PHP_BIN" artisan view:clear || true
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

log "Stopping old workers if present"
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
