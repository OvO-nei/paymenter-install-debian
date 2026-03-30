#!/bin/bash

set -Eeuo pipefail

PHP_VERSION="8.3"
PAYMENTER_DIR="/var/www/paymenter"
PAYMENTER_DB="paymenter"
PAYMENTER_DB_USER="paymenter"
PAYMENTER_SERVICE="paymenter.service"
NGINX_SITE_PATH="/etc/nginx/sites-available/paymenter.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/paymenter.conf"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
MARIADB_VERSION="mariadb-10.11"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

trap 'fail "Installer stopped near line ${LINENO}. Review the output above and retry."' ERR

require_root() {
    [ "${EUID}" -eq 0 ] || fail "Please run this script as root."
}

require_os_release() {
    [ -r /etc/os-release ] || fail "Unable to detect your operating system."
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_VERSION_ID="${VERSION_ID:-}"

    [[ "${OS_ID}" == "debian" || "${OS_ID}" == "ubuntu" ]] || fail "This script supports Debian and Ubuntu only."
    [ -n "${OS_CODENAME}" ] || fail "Could not detect the distribution codename."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

is_ip_address() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ : ]]
}

prompt_nonempty() {
    local prompt_text="$1"
    local secret="${2:-false}"
    local value=""
    local prompt_stream="/dev/tty"

    [ -r "${prompt_stream}" ] || prompt_stream="/dev/stdin"

    while [ -z "${value}" ]; do
        if [ "${secret}" = "true" ]; then
            if ! read -r -s -p "${prompt_text}" value < "${prompt_stream}"; then
                printf '\n' > /dev/tty
                fail "Input cancelled while reading: ${prompt_text}"
            fi
            printf '\n' > /dev/tty
        else
            if ! read -r -p "${prompt_text}" value < "${prompt_stream}"; then
                printf '\n' > /dev/tty
                fail "Input cancelled while reading: ${prompt_text}"
            fi
        fi
        value="$(trim_whitespace "${value}")"
        [ -n "${value}" ] || printf 'This field is required.\n' > /dev/tty
    done

    printf '%s' "${value}"
}

set_env_value() {
    local key="$1"
    local value="$2"
    local env_file="$3"
    local tmp_file

    tmp_file="$(mktemp)"
    awk -v key="${key}" -v value="${value}" '
        BEGIN { updated = 0 }
        index($0, key "=") == 1 {
            print key "=" value
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print key "=" value
            }
        }
    ' "${env_file}" > "${tmp_file}"
    mv "${tmp_file}" "${env_file}"
}

mysql_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "${value}"
}

configure_php_repo() {
    log "Configuring PHP repository for ${OS_ID}..."
    if [ "${OS_ID}" = "debian" ]; then
        install -d -m 0755 /etc/apt/keyrings
        rm -f /etc/apt/sources.list.d/sury-php.list /etc/apt/sources.list.d/php.list
        if [ -d /etc/apt/sources.list.d ]; then
            find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) \
                -exec sed -i '/packages\.sury\.org\/php/d' {} +
        fi
        if [ -f /etc/apt/sources.list ]; then
            sed -i '/packages\.sury\.org\/php/d' /etc/apt/sources.list
        fi
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg
        echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
            > /etc/apt/sources.list.d/sury-php.list
    else
        require_command add-apt-repository
        add-apt-repository -y ppa:ondrej/php
    fi
}

configure_mariadb_repo() {
    local mariadb_version="${MARIADB_VERSION}"

    if [ "${OS_ID}" = "debian" ]; then
        case "${OS_CODENAME}" in
            trixie|forky)
                mariadb_version="mariadb-11.4"
                ;;
        esac
    fi

    log "Configuring MariaDB repository..."
    curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="${mariadb_version}"
}

install_base_packages() {
    log "Updating package lists..."
    apt update -y
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
    DEBIAN_FRONTEND=noninteractive apt install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    if [ "${OS_ID}" = "ubuntu" ]; then
        DEBIAN_FRONTEND=noninteractive apt install -y software-properties-common
    fi
}

install_packages() {
    log "Installing system packages..."
    apt update -y
    DEBIAN_FRONTEND=noninteractive apt install -y \
        cron \
        git \
        nginx \
        nodejs \
        npm \
        redis-server \
        tar \
        unzip \
        mariadb-server \
        "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" \
        "php${PHP_VERSION}-gd" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-redis"
}

install_composer() {
    if command -v composer >/dev/null 2>&1; then
        log "Composer already installed, keeping the current binary."
        return
    fi

    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
}

prepare_services() {
    log "Starting and enabling required services..."
    systemctl enable --now mariadb nginx redis-server cron "${PHP_FPM_SERVICE}"
}

setup_database() {
    log "Creating Paymenter database and database user..."
    local escaped_db_password

    escaped_db_password="$(mysql_escape "${DB_PASSWORD}")"
    mysql <<MYSQL
CREATE DATABASE IF NOT EXISTS \`${PAYMENTER_DB}\`;
CREATE USER IF NOT EXISTS '${PAYMENTER_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${escaped_db_password}';
ALTER USER '${PAYMENTER_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${escaped_db_password}';
GRANT ALL PRIVILEGES ON \`${PAYMENTER_DB}\`.* TO '${PAYMENTER_DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL
}

download_paymenter() {
    log "Preparing ${PAYMENTER_DIR}..."
    mkdir -p "${PAYMENTER_DIR}"
    cd "${PAYMENTER_DIR}"

    if [ ! -f artisan ]; then
        log "Downloading the latest Paymenter release..."
        rm -f paymenter.tar.gz
        curl -fsSL -o paymenter.tar.gz https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz
        tar -xzf paymenter.tar.gz --strip-components=1
        rm -f paymenter.tar.gz
    else
        log "Existing Paymenter installation detected, reusing current files."
    fi

    [ -f .env ] || cp .env.example .env
}

configure_environment() {
    APP_URL="${APP_SCHEME}://${DOMAIN}"

    log "Writing Paymenter environment settings..."
    set_env_value "APP_URL" "${APP_URL}" .env
    set_env_value "DB_HOST" "127.0.0.1" .env
    set_env_value "DB_PORT" "3306" .env
    set_env_value "DB_DATABASE" "${PAYMENTER_DB}" .env
    set_env_value "DB_USERNAME" "${PAYMENTER_DB_USER}" .env
    set_env_value "DB_PASSWORD" "${DB_PASSWORD}" .env
    set_env_value "REDIS_HOST" "127.0.0.1" .env
    set_env_value "REDIS_PASSWORD" "null" .env
    set_env_value "REDIS_PORT" "6379" .env
}

install_paymenter_dependencies() {
    log "Installing PHP dependencies..."
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction --working-dir="${PAYMENTER_DIR}"
}

build_paymenter_assets() {
    cd "${PAYMENTER_DIR}"

    if [ ! -f package.json ]; then
        log "No frontend package.json found, skipping asset build."
        return
    fi

    log "Installing frontend dependencies and building assets..."
    if [ -f package-lock.json ]; then
        npm ci
    else
        npm install
    fi
    npm run build
}

run_artisan_setup() {
    log "Running Paymenter setup commands..."
    cd "${PAYMENTER_DIR}"
    php artisan key:generate --force
    php artisan storage:link || true
    php artisan migrate --force --seed
    php artisan app:settings:change app_url "${APP_URL}"
}

apply_permissions() {
    log "Applying file permissions..."
    chown -R www-data:www-data "${PAYMENTER_DIR}"
    chmod -R 750 "${PAYMENTER_DIR}/storage" "${PAYMENTER_DIR}/bootstrap/cache"
}

configure_nginx() {
    log "Writing Nginx configuration..."
    cat <<EOF > "${NGINX_SITE_PATH}"
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${PAYMENTER_DIR}/public;
    index index.php;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf "${NGINX_SITE_PATH}" "${NGINX_SITE_LINK}"
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx
}

configure_ssl() {
    local ssl_choice

    ssl_choice="$(prompt_nonempty 'Do you want to install SSL for your domain? (Y/N): ')"
    if [[ ! "${ssl_choice}" =~ ^[Yy]$ ]]; then
        return
    fi

    if is_ip_address "${DOMAIN}"; then
        log "Skipping Certbot because SSL issuance requires a real domain name, not an IP address."
        return
    fi

    log "Installing Certbot and requesting a certificate..."
    DEBIAN_FRONTEND=noninteractive apt install -y certbot python3-certbot-nginx
    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}"
    APP_SCHEME="https"
    configure_environment
    cd "${PAYMENTER_DIR}"
    php artisan app:settings:change app_url "${APP_URL}"
}

configure_cron() {
    log "Installing the Paymenter cron entry..."
    (crontab -l 2>/dev/null | grep -Fv "${PAYMENTER_DIR}/artisan app:cron-job" || true
     echo "* * * * * php ${PAYMENTER_DIR}/artisan app:cron-job >> /dev/null 2>&1") | crontab -
}

configure_queue_worker() {
    log "Installing the Paymenter queue worker service..."
    cat <<EOF > "/etc/systemd/system/${PAYMENTER_SERVICE}"
[Unit]
Description=Paymenter Queue Worker
After=network.target mariadb.service redis-server.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=${PAYMENTER_DIR}
ExecStart=/usr/bin/php ${PAYMENTER_DIR}/artisan queue:work --sleep=3 --tries=3
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${PAYMENTER_SERVICE}"
}

create_admin_user() {
    log "Creating the initial Paymenter admin user..."
    cd "${PAYMENTER_DIR}"
    if [ "$(php artisan tinker --execute="echo \\App\\Models\\User::where('email', '${ADMIN_EMAIL}')->exists() ? 'yes' : 'no';" 2>/dev/null)" = "yes" ]; then
        log "An admin user with email ${ADMIN_EMAIL} already exists, skipping creation."
        return
    fi
    php artisan app:user:create "${ADMIN_FIRST_NAME}" "${ADMIN_LAST_NAME}" "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}" 1
}

summarize() {
    log "Installation complete."
    printf 'Paymenter URL: %s\n' "${APP_URL}"
    printf 'Nginx config: %s\n' "${NGINX_SITE_PATH}"
    printf 'Queue service: %s\n' "${PAYMENTER_SERVICE}"
}

require_root
require_os_release

install_base_packages
require_command curl
require_command gpg
require_command systemctl

DOMAIN="$(prompt_nonempty 'Enter your domain name or IP address for Paymenter: ')"
DB_PASSWORD="$(prompt_nonempty 'Enter the database password for Paymenter: ' true)"
ADMIN_FIRST_NAME="$(prompt_nonempty 'Admin first name: ')"
ADMIN_LAST_NAME="$(prompt_nonempty 'Admin last name: ')"
ADMIN_EMAIL="$(prompt_nonempty 'Admin email: ')"
ADMIN_PASSWORD="$(prompt_nonempty 'Admin password: ' true)"

APP_SCHEME="http"
APP_URL="${APP_SCHEME}://${DOMAIN}"

configure_php_repo
configure_mariadb_repo
install_packages
require_command mysql
require_command php
install_composer
require_command composer
prepare_services
setup_database
download_paymenter
configure_environment
install_paymenter_dependencies
build_paymenter_assets
run_artisan_setup
apply_permissions
configure_nginx
configure_ssl
configure_cron
configure_queue_worker
create_admin_user
summarize
