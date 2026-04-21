#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

APP_DIR="${APP_DIR:-$PWD/pterodactyl-panel}"

PHP_BIN="/usr/bin/php8.3"
COMPOSER_BIN="/usr/bin/composer"

SUDO="sudo"

log() { echo -e "\n==> $*"; }

ask() {
  local var="$1"
  local prompt="$2"
  local default="$3"
  read -rp "$prompt [$default]: " input
  export "$var"="${input:-$default}"
}

# =========================
# INTERACTIVE SETUP
# =========================
if [[ "${INTERACTIVE_SETUP:-0}" == "1" ]]; then
  echo "=== INTERACTIVE SETUP ==="

  ask PANEL_PORT "Panel port" "8080"
  ask DOMAIN "Domain (Cloudflare hostname, e.g. panel.yoursite.com)" ""

  ask DB_NAME "Database name" "panel"
  ask DB_USER "Database user" "pterodactyl"
  ask DB_PASS "Database password" "$(openssl rand -base64 12)"

  ask ADMIN_EMAIL "Admin email" ""
  ask ADMIN_USERNAME "Admin username" "admin"
  ask ADMIN_FIRST "Admin first name" "Admin"
  ask ADMIN_LAST "Admin last name" "User"
  ask ADMIN_PASSWORD "Admin password" ""
else
  PANEL_PORT=8080
  DOMAIN=""
  DB_NAME="panel"
  DB_USER="pterodactyl"
  DB_PASS="$(openssl rand -base64 12)"
fi

# =========================
# URL SETUP (Cloudflare)
# =========================
if [[ -n "$DOMAIN" ]]; then
  APP_URL="https://$DOMAIN"
else
  if [[ -n "${CODESPACE_NAME:-}" ]]; then
    APP_URL="https://${CODESPACE_NAME}-${PANEL_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  else
    APP_URL="http://127.0.0.1:${PANEL_PORT}"
  fi
fi

# =========================
# INSTALL
# =========================
log "Installing packages"
$SUDO apt-get update
$SUDO apt-get install -y \
  curl unzip tar git jq openssl \
  mariadb-server redis-server nginx \
  php8.3 php8.3-cli php8.3-mysql php8.3-gd php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-intl \
  composer

log "Start services"
$SUDO service mariadb start
$SUDO service redis-server start

log "Prepare folder"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

log "Download panel"
curl -fsSL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
tar -xzf panel.tar.gz
rm panel.tar.gz

cp .env.example .env

log "Install dependencies"
COMPOSER_ALLOW_SUPERUSER=1 "$PHP_BIN" "$COMPOSER_BIN" install --no-dev

log "Setup database"
$SUDO mariadb <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\`;

DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';

CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

log "Configure .env"
sed -i "s|APP_URL=.*|APP_URL=${APP_URL}|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env

log "Generate key"
"$PHP_BIN" artisan key:generate --force

log "Migrate DB"
"$PHP_BIN" artisan migrate --seed --force

log "Create admin"
if [[ -n "${ADMIN_EMAIL:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
"$PHP_BIN" artisan p:user:make \
  --email="$ADMIN_EMAIL" \
  --username="$ADMIN_USERNAME" \
  --name-first="$ADMIN_FIRST" \
  --name-last="$ADMIN_LAST" \
  --password="$ADMIN_PASSWORD" \
  --admin=1
fi

log "Start panel"
nohup "$PHP_BIN" artisan queue:work > /dev/null 2>&1 &
nohup "$PHP_BIN" artisan serve --host=0.0.0.0 --port=$PANEL_PORT > /dev/null 2>&1 &

echo
echo "=============================="
echo "✅ INSTALL COMPLETE"
echo "=============================="
echo "URL: $APP_URL"
echo "DB: $DB_NAME / $DB_USER / $DB_PASS"

if [[ -n "$DOMAIN" ]]; then
  echo
  echo "🌐 CLOUDFLARE SETUP:"
  echo "Set tunnel service to:"
  echo "http://localhost:$PANEL_PORT"
fi
