#!/usr/bin/env bash
#
# Scaffolds a local WordPress site: nginx, PHP-FPM and MySQL behind Traefik,
# with a trusted mkcert certificate and a Mailpit inbox.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAEFIK_DIR="$BASE_DIR/traefik"
TEMPLATE_DIR="$TRAEFIK_DIR/templates"
CERT_DIR="$TRAEFIK_DIR/certs"
DYNAMIC_CONF="$TRAEFIK_DIR/dynamic_conf.yaml"
PROXY_NETWORK="web-proxy"
WWW_DATA_GID=33

HOSTNAME_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'

info() { printf '\n--- %s ---\n' "$1"; }
die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found. $2"
}

# Reports whether a hostname is already listed in /etc/hosts.
host_is_mapped() {
    awk -v host="$1" '
        !/^[[:space:]]*#/ { for (i = 2; i <= NF; i++) if ($i == host) found = 1 }
        END { exit(found ? 0 : 1) }
    ' /etc/hosts
}

# --- Prerequisites -----------------------------------------------------------

require_command docker "See https://docs.docker.com/engine/install/"
require_command mkcert "See https://github.com/FiloSottile/mkcert#installation"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "The Docker daemon is not reachable."

CA_ROOT="$(mkcert -CAROOT)"
[ -f "$CA_ROOT/rootCA.pem" ] || die "The mkcert local CA is missing. Run 'mkcert -install' once, then try again."

for template in wp-template.yaml nginx.conf composer.json php-fpm-dev.ini php-cli-dev.ini mu-dev-mail.php; do
    [ -f "$TEMPLATE_DIR/$template" ] || die "Template $TEMPLATE_DIR/$template is missing."
done

if [ ! -f "$DYNAMIC_CONF" ]; then
    info "Creating $DYNAMIC_CONF"
    cp "$TRAEFIK_DIR/dynamic_conf.yaml.example" "$DYNAMIC_CONF"
fi

if ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
    info "Creating the $PROXY_NETWORK network"
    docker network create "$PROXY_NETWORK" >/dev/null
fi

# --- Input -------------------------------------------------------------------

SITE_NAME=""
read -r -p "Enter project directory name (e.g., my-blog): " SITE_NAME || true
SITE_NAME="${SITE_NAME,,}"
[[ "$SITE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || die "The project name may only contain a-z, 0-9, '-' and '_', and must start with a letter or digit."

DOMAIN=""
read -r -p "Enter domain (e.g., my-blog.test): " DOMAIN || true
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ $HOSTNAME_RE ]] || die "'$DOMAIN' does not look like a hostname."
case "$DOMAIN" in
    *.test) ;;
    *) printf "Note: .test is the TLD reserved for local use. Public TLDs such as .dev are in the browser HSTS preload list and behave differently.\n" ;;
esac

PROD_DOMAIN=""
read -r -p "Enter production domain to fall back to for uploads (optional): " PROD_DOMAIN || true
PROD_DOMAIN="${PROD_DOMAIN,,}"
PROD_DOMAIN="${PROD_DOMAIN#http://}"
PROD_DOMAIN="${PROD_DOMAIN#https://}"
PROD_DOMAIN="${PROD_DOMAIN%%/*}"
if [ -n "$PROD_DOMAIN" ]; then
    [[ "$PROD_DOMAIN" =~ $HOSTNAME_RE ]] || die "'$PROD_DOMAIN' does not look like a hostname."
fi

THEME_SLUG=""
read -r -p "Enter theme repository slug from github.com/redandbluefi (optional, e.g. eternia): " THEME_SLUG || true
THEME_SLUG="${THEME_SLUG,,}"
if [ -n "$THEME_SLUG" ]; then
    [[ "$THEME_SLUG" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "'$THEME_SLUG' is not a valid repository slug."
    [ -x "$BASE_DIR/setup-theme.sh" ] || die "setup-theme.sh is missing or not executable."
fi

PROJECT_DIR="$BASE_DIR/$SITE_NAME"
if [ -e "$PROJECT_DIR" ]; then
    printf '\n%s already exists.\n' "$PROJECT_DIR"
    printf 'Continuing rewrites docker-compose.yaml, nginx.conf, the PHP ini files and\n'
    printf 'composer.json. The database volume and everything in src/ are left alone.\n'
    reply=""
    read -r -p "Continue? [y/N] " reply || true
    [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."
fi

# --- Project files -----------------------------------------------------------

info "Creating project directories"
mkdir -p "$PROJECT_DIR/src/wp-content/mu-plugins" "$PROJECT_DIR/nginx/configs" "$PROJECT_DIR/php"

info "Generating nginx configuration"
if [ -n "$PROD_DOMAIN" ]; then
    sed -e "s|\${PROD_URL}|$PROD_DOMAIN|g" \
        "$TEMPLATE_DIR/uploads-proxy.conf" > "$PROJECT_DIR/nginx/configs/uploads-proxy.conf"
    UPLOADS_FALLBACK="include /etc/nginx/custom_includes/uploads-proxy.conf;"
else
    rm -f "$PROJECT_DIR/nginx/configs/uploads-proxy.conf"
    UPLOADS_FALLBACK="return 404;"
fi
sed -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${UPLOADS_FALLBACK}|$UPLOADS_FALLBACK|g" \
    "$TEMPLATE_DIR/nginx.conf" > "$PROJECT_DIR/nginx/nginx.conf"

info "Generating PHP configuration"
cp "$TEMPLATE_DIR/php-fpm-dev.ini" "$PROJECT_DIR/php/php-fpm-dev.ini"
cp "$TEMPLATE_DIR/php-cli-dev.ini" "$PROJECT_DIR/php/php-cli-dev.ini"

info "Installing the local mail routing mu-plugin"
cp "$TEMPLATE_DIR/mu-dev-mail.php" "$PROJECT_DIR/src/wp-content/mu-plugins/dev-mail.php"

info "Generating docker-compose.yaml"
sed -e "s/\${SITE_NAME}/$SITE_NAME/g" \
    -e "s/\${DOMAIN}/$DOMAIN/g" \
    "$TEMPLATE_DIR/wp-template.yaml" > "$PROJECT_DIR/docker-compose.yaml"

info "Generating SSL certificates"
mkcert -cert-file "$CERT_DIR/$SITE_NAME-cert.pem" \
       -key-file "$CERT_DIR/$SITE_NAME-key.pem" \
       "$DOMAIN" "*.$DOMAIN"

info "Updating the Traefik dynamic configuration"
if grep -qF "/certs/$SITE_NAME-cert.pem" "$DYNAMIC_CONF"; then
    echo "Already listed, nothing to add."
else
    cat >> "$DYNAMIC_CONF" <<EOF
    - certFile: /etc/traefik/certs/$SITE_NAME-cert.pem
      keyFile: /etc/traefik/certs/$SITE_NAME-key.pem
EOF
fi

# --- Composer ----------------------------------------------------------------

info "Preparing composer.json"
sed -e "s/\${SITE_NAME}/$SITE_NAME/g" "$TEMPLATE_DIR/composer.json" > "$PROJECT_DIR/src/composer.json"

if [ -f "$TEMPLATE_DIR/auth.json" ]; then
    require_command composer "See https://getcomposer.org/download/"
    info "Installing plugins with Composer"
    # The credentials are passed in the environment so that they never end up
    # in the webroot, where nginx could serve them.
    (
        cd "$PROJECT_DIR/src"
        COMPOSER_AUTH="$(cat "$TEMPLATE_DIR/auth.json")" \
            composer install --no-dev --no-interaction --optimize-autoloader
    )
    rm -f "$PROJECT_DIR/src/auth.json"
else
    info "No $TEMPLATE_DIR/auth.json found, skipping Composer install"
fi

# --- Start -------------------------------------------------------------------

info "Starting the stack"
(cd "$PROJECT_DIR" && docker compose up -d)

info "Waiting for the WordPress installation to finish"
setup_status=0
(cd "$PROJECT_DIR" && docker compose wait wp-setup) || setup_status=$?
if [ "$setup_status" -ne 0 ]; then
    printf 'The setup container exited with status %s. Check it with:\n' "$setup_status"
    printf '  cd %s && docker compose logs wp-setup\n' "$SITE_NAME"
fi

info "Normalising ownership and permissions"
sudo chown -R "$USER:$WWW_DATA_GID" "$PROJECT_DIR"
sudo find "$PROJECT_DIR" -type d -exec chmod 2775 {} +
# g+rw rather than an absolute mode, so executables in vendor/ and
# node_modules/ keep their execute bit.
sudo find "$PROJECT_DIR" -type f -exec chmod g+rw {} +

theme_status=0
if [ -n "$THEME_SLUG" ]; then
    "$BASE_DIR/setup-theme.sh" "$SITE_NAME" "$THEME_SLUG" "$DOMAIN" || theme_status=$?
    if [ "$theme_status" -ne 0 ]; then
        printf '\nTheme setup failed with status %s. The site itself is running. Retry with:\n' "$theme_status"
        printf '  ./setup-theme.sh %s %s\n' "$SITE_NAME" "$THEME_SLUG"
    fi
fi

# --- Hosts file --------------------------------------------------------------

if host_is_mapped "$DOMAIN"; then
    info "$DOMAIN is already in /etc/hosts"
else
    reply=""
    read -r -p "Add '127.0.0.1 $DOMAIN mail.$DOMAIN' to /etc/hosts (needs sudo)? [Y/n] " reply || true
    if [[ ! "$reply" =~ ^[Nn]$ ]]; then
        printf '127.0.0.1 %s mail.%s\n' "$DOMAIN" "$DOMAIN" | sudo tee -a /etc/hosts >/dev/null
    else
        printf "Remember to add '127.0.0.1 %s mail.%s' to /etc/hosts yourself.\n" "$DOMAIN" "$DOMAIN"
    fi
fi

# --- Summary -----------------------------------------------------------------

cat <<EOF

--- Done ---

Site       https://$DOMAIN
Admin      https://$DOMAIN/wp-admin  (admin / password)
Mail       https://mail.$DOMAIN
Debug log  $SITE_NAME/src/wp-content/debug.log

WP-CLI     cd $SITE_NAME && docker compose run --rm wp-cli wp <command>
Logs       cd $SITE_NAME && docker compose logs -f
Stop       cd $SITE_NAME && docker compose down
Remove     ./delete-site.sh $SITE_NAME
EOF

if [ -n "$THEME_SLUG" ] && [ "$theme_status" -eq 0 ]; then
    printf 'Theme      %s/src/wp-content/themes/%s\n' "$SITE_NAME" "$THEME_SLUG"
    printf 'Watch      cd %s/src/wp-content/themes/%s && pnpm run dev\n' "$SITE_NAME" "$THEME_SLUG"
fi

if ! docker ps --format '{{.Names}}' | grep -qx traefik; then
    printf '\nWarning: the traefik container is not running, so the site is not reachable yet.\n'
    printf 'Start it with: cd traefik && docker compose up -d\n'
fi
