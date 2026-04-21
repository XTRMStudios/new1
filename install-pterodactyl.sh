#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROLE="${ROLE:-panel}"                 # panel | node
INTERACTIVE_SETUP="${INTERACTIVE_SETUP:-0}"

# Shared
PANEL_URL="${PANEL_URL:-}"
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

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
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

detect_codespaces_url() {
  local port="$1"
  if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
    echo "https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  else
    echo "http://127.0.0.1:${port}"
  fi
}

panel_setup_prompts() {
  APP_DIR="${APP_DIR:-$PWD/pterodactyl-panel}"
  PANEL_PORT="${PANEL_PORT:-8080}"

  DB_NAME="${PTERO_DB_NAME:-panel}"
  DB_USER="${PTERO_DB_USER:-pterodactyl}"
  DB_PASS="${PTERO_DB_PASS:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)}"

  ADMIN_EMAIL="${PTERO_ADMIN_EMAIL:-}"
  ADMIN_USERNAME="${PTERO_ADMIN_USERNAME:-admin}"
  ADMIN_FIRST="${PTERO_ADMIN_FIRST_NAME:-Admin}"
  ADMIN_LAST="${PTERO_ADMIN_LAST_NAME:-User}"
  ADMIN_PASSWORD="${PTERO_ADMIN_PASSWORD:-}"

  DOMAIN="${DOMAIN:-}"

  if [[ "$INTERACTIVE_SETUP" == "1" ]]; then
    ask PANEL_PORT "Panel port" "${PANEL_PORT}"
    ask DOMAIN "Panel domain for APP_URL (leave blank to use Codespaces URL)" "${DOMAIN}"
    ask DB_NAME "Database name" "${DB_NAME}"
    ask DB_USER "Database user" "${DB_USER}"
    ask DB_PASS "Database password" "${DB_PASS}"
    ask ADMIN_EMAIL "Admin email" "${ADMIN_EMAIL}"
    ask ADMIN_USERNAME "Admin username" "${ADMIN_USERNAME}"
    ask ADMIN_FIRST "Admin first name" "${ADMIN_FIRST}"
    ask ADMIN_LAST "Admin last name" "${ADMIN_LAST}"
    ask ADMIN_PASSWORD "Admin password" "${ADMIN_PASSWORD}"
  fi

  if [[ -n "$DOMAIN" ]]; then
    APP_URL="https://${DOMAIN}"
  else
    APP_URL="$(detect_codespaces_url "$PANEL_PORT")"
  fi
}

install_panel() {
  panel_setup_prompts

  log "Installing panel packages"
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

  if [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_USERNAME" && -n "$ADMIN_FIRST" && -n "$ADMIN_LAST" && -n "$ADMIN_PASSWORD" ]]; then
    log "Creating admin user"
    "$PHP_BIN" artisan p:user:make \
      --email="$ADMIN_EMAIL" \
      --username="$ADMIN_USERNAME" \
      --name-first="$ADMIN_FIRST" \
      --name-last="$ADMIN_LAST" \
      --password="$ADMIN_PASSWORD" \
      --admin=1
  else
    log "Skipping admin creation because admin details were not fully set"
  fi

  log "Stopping old panel processes"
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
  echo "Pterodactyl Panel installed"
  echo "=============================================="
  echo "URL: $APP_URL"
  echo "App dir: $APP_DIR"
  echo "DB name: $DB_NAME"
  echo "DB user: $DB_USER"
  echo "DB pass: $DB_PASS"
  if [[ -n "$ADMIN_EMAIL" ]]; then
    echo "Admin email: $ADMIN_EMAIL"
    echo "Admin username: $ADMIN_USERNAME"
  fi
  echo
  echo "Cloudflare Tunnel service for the panel:"
  echo "  http://localhost:${PANEL_PORT}"
}

node_setup_prompts() {
  NODE_FQDN="${NODE_FQDN:-}"
  NODE_PANEL_URL="${NODE_PANEL_URL:-$PANEL_URL}"
  WINGS_TOKEN="${WINGS_TOKEN:-}"
  NODE_ID="${NODE_ID:-}"

  if [[ "$INTERACTIVE_SETUP" == "1" ]]; then
    ask NODE_PANEL_URL "Panel URL" "${NODE_PANEL_URL}"
    ask NODE_ID "Node ID from panel" "${NODE_ID}"
    ask WINGS_TOKEN "Wings config token from panel" "${WINGS_TOKEN}"
    ask NODE_FQDN "Node FQDN or public IP (for your own reference)" "${NODE_FQDN}"
  fi

  [[ -n "$NODE_PANEL_URL" ]] || { echo "NODE_PANEL_URL/PANEL_URL is required for ROLE=node"; exit 1; }
  [[ -n "$NODE_ID" ]] || { echo "NODE_ID is required for ROLE=node"; exit 1; }
  [[ -n "$WINGS_TOKEN" ]] || { echo "WINGS_TOKEN is required for ROLE=node"; exit 1; }
}

install_node() {
  node_setup_prompts

  log "Installing Docker and Wings prerequisites"
  $SUDO apt-get update
  $SUDO apt-get install -y \
    curl ca-certificates gnupg lsb-release software-properties-common apt-transport-https

  $SUDO install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo \
    "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  $SUDO apt-get update
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Starting Docker"
  $SUDO systemctl enable --now docker

  log "Installing Wings"
  curl -fsSL https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o /tmp/wings
  chmod +x /tmp/wings
  $SUDO mv /tmp/wings /usr/local/bin/wings
  $SUDO mkdir -p /etc/pterodactyl

  log "Configuring Wings from panel token"
  $SUDO wings configure --panel-url "$NODE_PANEL_URL" --token "$WINGS_TOKEN" --node "$NODE_ID"

  log "Creating systemd service"
  $SUDO tee /etc/systemd/system/wings.service >/dev/null <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

  log "Starting Wings"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now wings

  echo
  echo "=============================================="
  echo "Pterodactyl Node installed"
  echo "=============================================="
  echo "Panel URL: $NODE_PANEL_URL"
  echo "Node ID: $NODE_ID"
  if [[ -n "$NODE_FQDN" ]]; then
    echo "Node address: $NODE_FQDN"
  fi
  echo
  echo "Check status with:"
  echo "  sudo systemctl status wings"
  echo
  echo "Important:"
  echo "  Do not put Wings behind a Cloudflare Tunnel."
  echo "  Use a direct public IP or a DNS record with proxy OFF."
}

case "$ROLE" in
  panel)
    install_panel
    ;;
  node)
    install_node
    ;;
  *)
    echo "Unknown ROLE: $ROLE"
    echo "Use ROLE=panel or ROLE=node"
    exit 1
    ;;
esac
