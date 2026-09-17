#!/usr/bin/env bash
#
# Scaffolds a local WordPress site: nginx, PHP-FPM and MariaDB behind Traefik,
# with a trusted mkcert certificate and a Mailpit inbox.
#
# Usage: ./create-site.sh [--multisite[=subdomain|subdirectory]]

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

# Reports whether the traefik container holds an endpoint on the proxy network.
# Traefik publishes ports 80 and 443 only while it does, and Docker assigns that
# endpoint when the container is created, never when it is started. A container
# left over from an earlier network keeps reporting "Up" with an empty port list
# while every site refuses connections, so match on the network ID: the stale
# attachment carries the same name as the current network.
traefik_on_proxy_network() {
    local network_id
    network_id="$(docker network inspect "$PROXY_NETWORK" --format '{{.ID}}' 2>/dev/null)" || return 1
    [ -n "$network_id" ] || return 1
    docker inspect traefik --format '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' 2>/dev/null \
        | tr ' ' '\n' | grep -qxF "$network_id"
}

# --- Options -----------------------------------------------------------------

NETWORK_TYPE=""

usage() {
    cat <<'EOF'
Usage: ./create-site.sh [--multisite[=<type>]]

  --multisite[=<type>]  Scaffold a WordPress network instead of a single site.
                        <type> is 'subdomain', the default, or 'subdirectory'.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --multisite) NETWORK_TYPE="subdomain" ;;
        --multisite=*) NETWORK_TYPE="${1#*=}" ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option '$1'." ;;
    esac
    shift
done

case "$NETWORK_TYPE" in
    "" | subdomain | subdirectory) ;;
    *) die "The network type is 'subdomain' or 'subdirectory', not '$NETWORK_TYPE'." ;;
esac

# --- Prerequisites -----------------------------------------------------------

require_command docker "See https://docs.docker.com/engine/install/"
require_command mkcert "See https://github.com/FiloSottile/mkcert#installation"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "The Docker daemon is not reachable."

CA_ROOT="$(mkcert -CAROOT)"
[ -f "$CA_ROOT/rootCA.pem" ] || die "The mkcert local CA is missing. Run 'mkcert -install' once, then try again."

for template in wp-template.yaml nginx.conf multisite-subdirectory.conf composer.json \
    php-fpm-dev.ini php-cli-dev.ini mu-dev-mail.php mu-dev-multisite.php; do
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

# Recreation is what reattaches traefik, because the endpoint is fixed when the
# container is created. Restarting it would leave it detached.
if docker container inspect traefik >/dev/null 2>&1 && ! traefik_on_proxy_network; then
    info "Reattaching traefik to the $PROXY_NETWORK network"
    (cd "$TRAEFIK_DIR" && docker compose up -d --force-recreate)
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
    *) printf 'Note: .test is reserved for local use (RFC 6761) and can never be registered.\n'
       printf 'A public TLD such as .dev may already belong to someone else, and then only\n'
       printf 'the /etc/hosts entry keeps traffic off their server.\n' ;;
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

# Regenerating a network as a single site would put WP_HOME and WP_SITEURL back
# and pin every subsite to the main domain.
if [ -z "$NETWORK_TYPE" ] && [ -f "$PROJECT_DIR/src/wp-config.php" ] \
    && grep -qE "define\( *'MULTISITE', *true" "$PROJECT_DIR/src/wp-config.php"; then
    existing="subdirectory"
    if grep -qE "define\( *'SUBDOMAIN_INSTALL', *true" "$PROJECT_DIR/src/wp-config.php"; then
        existing="subdomain"
    fi
    die "$SITE_NAME is already a $existing network. Re-run with --multisite=$existing."
fi

if [ -e "$PROJECT_DIR" ]; then
    printf '\n%s already exists.\n' "$PROJECT_DIR"
    printf 'Continuing rewrites docker-compose.yaml, nginx.conf, the PHP ini files and\n'
    printf 'composer.json. The database volume and everything in src/ are left alone.\n'
    reply=""
    read -r -p "Continue? [y/N] " reply || true
    [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."
fi

# --- Network type ------------------------------------------------------------

# A single site pins its URL with WP_HOME and WP_SITEURL. A network cannot: it
# reads every site URL from the network tables, so those two lines are dropped
# from the compose file and WP-CLI writes the multisite constants into
# src/wp-config.php when it installs the network instead.
SERVER_NAME="$DOMAIN"
TRAEFIK_RULE="Host(\`$DOMAIN\`)"
IS_INSTALLED="is-installed"
CORE_INSTALL="install"
PLUGIN_ACTIVATE="plugin activate"
COMPOSE_FILTER=()

if [ -n "$NETWORK_TYPE" ]; then
    COMPOSE_FILTER=(-e "/define( 'WP_HOME'/d" -e "/define( 'WP_SITEURL'/d")
    IS_INSTALLED="is-installed --network"
    CORE_INSTALL="multisite-install"
    PLUGIN_ACTIVATE="plugin activate --network"
fi

if [ "$NETWORK_TYPE" = "subdomain" ]; then
    CORE_INSTALL="multisite-install --subdomains"
    SERVER_NAME="$DOMAIN *.$DOMAIN"
    # Traefik v3 matches HostRegexp with a Go regular expression. The dots are
    # literal, written as [.] so that no backslash has to survive YAML, and the
    # anchor is written as $$, which is how Compose escapes a literal $.
    TRAEFIK_RULE="Host(\`$DOMAIN\`) || HostRegexp(\`^.+[.]${DOMAIN//./[.]}\$\$\`)"
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
if [ "$NETWORK_TYPE" = "subdirectory" ]; then
    cp "$TEMPLATE_DIR/multisite-subdirectory.conf" "$PROJECT_DIR/nginx/configs/multisite-subdirectory.conf"
    NGINX_FILTER=(-e "s|\${MULTISITE_REWRITES}|include /etc/nginx/custom_includes/multisite-subdirectory.conf;|")
else
    rm -f "$PROJECT_DIR/nginx/configs/multisite-subdirectory.conf"
    NGINX_FILTER=(-e "/\${MULTISITE_REWRITES}/d")
fi

sed "${NGINX_FILTER[@]}" \
    -e "s|\${SERVER_NAME}|$SERVER_NAME|g" \
    -e "s|\${UPLOADS_FALLBACK}|$UPLOADS_FALLBACK|g" \
    "$TEMPLATE_DIR/nginx.conf" > "$PROJECT_DIR/nginx/nginx.conf"

info "Generating PHP configuration"
cp "$TEMPLATE_DIR/php-fpm-dev.ini" "$PROJECT_DIR/php/php-fpm-dev.ini"
cp "$TEMPLATE_DIR/php-cli-dev.ini" "$PROJECT_DIR/php/php-cli-dev.ini"

info "Installing the mu-plugins"
cp "$TEMPLATE_DIR/mu-dev-mail.php" "$PROJECT_DIR/src/wp-content/mu-plugins/dev-mail.php"
if [ -n "$NETWORK_TYPE" ]; then
    cp "$TEMPLATE_DIR/mu-dev-multisite.php" "$PROJECT_DIR/src/wp-content/mu-plugins/dev-multisite.php"
else
    rm -f "$PROJECT_DIR/src/wp-content/mu-plugins/dev-multisite.php"
fi

info "Generating docker-compose.yaml"
sed "${COMPOSE_FILTER[@]}" \
    -e "s/\${SITE_NAME}/$SITE_NAME/g" \
    -e "s/\${DOMAIN}/$DOMAIN/g" \
    -e "s@\${TRAEFIK_RULE}@$TRAEFIK_RULE@g" \
    -e "s@\${IS_INSTALLED}@$IS_INSTALLED@g" \
    -e "s@\${CORE_INSTALL}@$CORE_INSTALL@g" \
    -e "s@\${PLUGIN_ACTIVATE}@$PLUGIN_ACTIVATE@g" \
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

if [ -n "$NETWORK_TYPE" ]; then
    cat <<EOF

--- Network ---

This is a $NETWORK_TYPE network. Create a subsite with:

  cd $SITE_NAME && docker compose run --rm wp-cli wp site create --slug=sub
EOF
    if [ "$NETWORK_TYPE" = "subdomain" ]; then
        cat <<EOF

Each subsite then needs its own /etc/hosts line, because hosts files have no
wildcards. The certificate and the Traefik router already cover them all:

  127.0.0.1 sub.$DOMAIN
EOF
    else
        printf '\nThe subsite is served at https://%s/sub/, no /etc/hosts change needed.\n' "$DOMAIN"
    fi
    cat <<EOF

A network reads every site URL from its own tables, so WP_HOME and WP_SITEURL
are not set here. After a production database import, put the site back on the
local domain with wp search-replace.
EOF
fi

if ! docker ps --format '{{.Names}}' | grep -qx traefik; then
    printf '\nWarning: the traefik container is not running, so the site is not reachable yet.\n'
    printf 'Start it with: cd traefik && docker compose up -d\n'
elif ! traefik_on_proxy_network; then
    printf '\nWarning: traefik is running but is not attached to the %s network, so the\n' "$PROXY_NETWORK"
    printf 'site is not reachable yet. Reattach it with:\n'
    printf '  cd traefik && docker compose up -d --force-recreate\n'
fi
