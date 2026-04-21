#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

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
  php php-cli php-fpm php-mysql php-gd php-mbstring php-bcmath php-xml php-curl php-zip \
  composer

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

log "Installing PHP dependencies"
if [[ ! -f ".env" ]]; then
  cp .env.example .env
fi

COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

log "Generating app key"
php artisan key:generate --force

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
php -r '
$path = ".env";
$env = file_get_contents($path);

$vars = [
  "APP_ENV" => "production",
  "APP_DEBUG" => "true",
  "APP_URL" => getenv("APP_URL_SET"),
  "DB_CONNECTION" => "mysql",
  "DB_HOST" => "127.0.0.1",
  "DB_PORT" => "3306",
  "DB_DATABASE" => getenv("DB_NAME_SET"),
  "DB_USERNAME" => getenv("DB_USER_SET"),
  "DB_PASSWORD" => getenv("DB_PASS_SET"),
  "CACHE_DRIVER" => "file",
  "SESSION_DRIVER" => "file",
  "QUEUE_CONNECTION" => "redis",
  "REDIS_HOST" => "127.0.0.1",
  "REDIS_PASSWORD" => "null",
  "REDIS_PORT" => "6379",
];

foreach ($vars as $key => $value) {
  if (preg_match("/^{$key}=.*/m", $env)) {
    $env = preg_replace("/^{$key}=.*/m", "{$key}={$value}", $env);
  } else {
    $env .= PHP_EOL . "{$key}={$value}";
  }
}

file_put_contents($path, $env);
' \
APP_URL_SET="$APP_URL" \
DB_NAME_SET="$DB_NAME" \
DB_USER_SET="$DB_USER" \
DB_PASS_SET="$DB_PASS"

log "Fixing permissions"
mkdir -p storage/logs bootstrap/cache
chmod -R 755 storage bootstrap/cache || true

log "Running migrations and seeds"
php artisan migrate --seed --force

log "Caching config"
php artisan storage:link || true
php artisan config:clear || true
php artisan config:cache || true
php artisan route:cache || true
php artisan view:cache || true

if [[ -n "$ADMIN_EMAIL" ]]; then
  log "Creating admin user"
  php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USERNAME" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST" \
    --password="$ADMIN_PASSWORD" \
    --admin=1
else
  log "Skipping admin creation because PTERO_ADMIN_EMAIL is not set"
fi

log "Starting queue worker"
pkill -f "artisan queue:work" >/dev/null 2>&1 || true
nohup php artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 \
  > storage/logs/queue-worker.log 2>&1 &

log "Starting Panel on port ${PANEL_PORT}"
pkill -f "artisan serve --host=0.0.0.0 --port=${PANEL_PORT}" >/dev/null 2>&1 || true
nohup php artisan serve --host=0.0.0.0 --port="${PANEL_PORT}" \
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
if [[ -n "$ADMIN_EMAIL" ]]; then
  echo "Admin email: $ADMIN_EMAIL"
  echo "Admin username: $ADMIN_USERNAME"
  echo "Admin password: $ADMIN_PASSWORD"
else
  echo "Admin account not auto-created."
  echo "Create one with:"
  echo "  cd $APP_DIR && php artisan p:user:make"
fi
echo
echo "Logs:"
echo "  tail -f $APP_DIR/storage/logs/panel-web.log"
echo "  tail -f $APP_DIR/storage/logs/queue-worker.log"
echo
echo "Make sure port ${PANEL_PORT} is forwarded in Codespaces."
