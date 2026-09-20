#!/usr/bin/env bash
#
# Scaffolds a local WordPress site: nginx, PHP-FPM and MariaDB behind Traefik,
# with a trusted mkcert certificate and a Mailpit inbox.
#
# What a site is made of is recorded in its site.conf, and rendering the project
# files from that manifest is a step of its own, so an existing site can be
# brought up to the current templates without answering any questions again.
#
# Usage: ./create-site.sh [--multisite[=subdomain|subdirectory]]
#        ./create-site.sh --update <site>... [--dry-run] [--yes]
#        ./create-site.sh --update --all [--dry-run] [--yes]

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/site.sh
. "$BASE_DIR/lib/site.sh"

TRAEFIK_DIR="$BASE_DIR/traefik"
TEMPLATE_DIR="$TRAEFIK_DIR/templates"
CERT_DIR="$TRAEFIK_DIR/certs"
DYNAMIC_CONF="$TRAEFIK_DIR/dynamic_conf.yaml"
PROXY_NETWORK="web-proxy"
WWW_DATA_GID=33

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

MODE="create"
REQUESTED_NETWORK=""
NETWORK_GIVEN=0
UPDATE_ALL=0
DRY_RUN=0
ASSUME_YES=0
UPDATE_SITES=()

usage() {
    cat <<'EOF'
Usage: ./create-site.sh [--multisite[=<type>]]
       ./create-site.sh --update <site>... [--dry-run] [--yes]
       ./create-site.sh --update --all [--dry-run] [--yes]

  --multisite[=<type>]  Scaffold a WordPress network instead of a single site.
                        <type> is 'subdomain', the default, or 'subdirectory'.

  --update <site>...    Re-render an existing site's docker-compose.yaml,
                        nginx.conf, PHP ini files, mu-plugins and composer.json
                        from its site.conf and the current templates. The
                        database, .env and everything else in src/ are left
                        alone. A site with no site.conf gets one, recovered
                        from the files it already has.
  --update --all        Every site directory that holds a docker-compose.yaml.
  --dry-run             Show the diff and write nothing.
  --yes                 Do not ask before writing.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --multisite) REQUESTED_NETWORK="subdomain"; NETWORK_GIVEN=1 ;;
        --multisite=*) REQUESTED_NETWORK="${1#*=}"; NETWORK_GIVEN=1 ;;
        --update) MODE="update" ;;
        --all) UPDATE_ALL=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --yes | -y) ASSUME_YES=1 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; die "Unknown option '$1'." ;;
        *) UPDATE_SITES+=("$1") ;;
    esac
    shift
done

case "$REQUESTED_NETWORK" in
    "" | subdomain | subdirectory) ;;
    *) die "The network type is 'subdomain' or 'subdirectory', not '$REQUESTED_NETWORK'." ;;
esac

if [ "$MODE" = "create" ]; then
    [ "${#UPDATE_SITES[@]}" -eq 0 ] || { usage >&2; die "Site names are only accepted with --update."; }
    [ "$UPDATE_ALL" -eq 0 ] || { usage >&2; die "--all is only accepted with --update."; }
    [ "$DRY_RUN" -eq 0 ] || { usage >&2; die "--dry-run is only accepted with --update."; }
else
    [ "$NETWORK_GIVEN" -eq 0 ] \
        || die "--multisite is for creating a site. Set NETWORK_TYPE in the site's site.conf and re-run --update."
fi

site_templates_check "$TEMPLATE_DIR"

# --- Update ------------------------------------------------------------------

# Copies the render over the project and drops the managed files it no longer
# produces. Reports the files it could not write rather than reaching for sudo.
apply_render() {
    local staged="$1" project_dir="$2"
    local failed=() rel

    for rel in "${SITE_RENDERED_FILES[@]}"; do
        mkdir -p "$project_dir/$(dirname "$rel")"
        if cp "$staged/$rel" "$project_dir/$rel" 2>/dev/null; then
            chgrp "$WWW_DATA_GID" "$project_dir/$rel" 2>/dev/null || true
            chmod g+rw "$project_dir/$rel" 2>/dev/null || true
        else
            failed+=("$rel")
        fi
    done

    site_prune_stale "$project_dir" || failed+=("(removing a file this render no longer produces)")

    if [ "${#failed[@]}" -ne 0 ]; then
        warn "Could not write: ${failed[*]}. Fix the ownership with: sudo chown -R $USER:$WWW_DATA_GID $project_dir"
        return 1
    fi
    return 0
}

# Prints a unified diff of the render against the project. Returns 1 when they
# already match.
render_diff() {
    local staged="$1" project_dir="$2"
    local rel changed=0 left

    while IFS= read -r rel; do
        left="$project_dir/$rel"
        if [ -e "$staged/$rel" ]; then
            if [ -e "$left" ]; then
                diff -u --label "$rel (now)" --label "$rel (rendered)" "$left" "$staged/$rel" || changed=1
            else
                printf '+++ %s (new file)\n' "$rel"
                changed=1
            fi
        elif [ -e "$left" ]; then
            printf -- '--- %s (no longer generated, would be removed)\n' "$rel"
            changed=1
        fi
    done < <(site_managed_files)

    [ "$changed" -eq 1 ] || return 1
    return 0
}

update_site() {
    local site="$1"
    local project_dir="$BASE_DIR/$site"

    info "$site"
    [ -d "$project_dir" ] || { warn "$project_dir does not exist, skipping."; return 1; }

    site_facts_load "$project_dir" \
        || { warn "$site has no site.conf and nothing to recover one from, skipping."; return 1; }

    # The database volume and every container name are built from SITE_NAME, so
    # a manifest that disagrees with its own directory is not something to
    # guess about: rendering either value would orphan something.
    if [ "$SITE_NAME" != "$site" ]; then
        warn "$site/site.conf says SITE_NAME=$SITE_NAME. Fix it to match the directory, skipping."
        return 1
    fi

    if [ "$SITE_FACTS_INFERRED" -eq 1 ]; then
        printf 'No site.conf. Recovered from the files this site already has:\n'
        site_facts_print
        if [ -z "$THEME_SLUG" ]; then
            printf '\nThe theme slug could not be recovered: there is no checkout under\n'
            printf 'src/wp-content/themes, or there is more than one. Fill it in afterwards\n'
            printf 'if this site has a project theme.\n'
        fi
        if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
            local reply=""
            printf '\n'
            read -r -p "Record this as $site/site.conf? [Y/n] " reply || true
            [[ ! "$reply" =~ ^[Nn]$ ]] || { warn "Skipping $site."; return 1; }
        fi
    fi

    site_facts_check || { warn "Skipping $site."; return 1; }

    local staged
    staged="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staged'" RETURN

    site_render "$staged" "$TEMPLATE_DIR"

    if ! render_diff "$staged" "$project_dir"; then
        echo "Already matches the current templates."
        if [ "$DRY_RUN" -eq 0 ] && [ "$SITE_FACTS_INFERRED" -eq 1 ]; then
            site_facts_write "$project_dir"
            echo "Recorded $site/site.conf."
        fi
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo
        echo "Dry run, nothing written."
        return 0
    fi

    if [ "$ASSUME_YES" -eq 0 ]; then
        local reply=""
        printf '\n'
        read -r -p "Write these changes to $site? [y/N] " reply || true
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "Skipped."; return 1; }
    fi

    site_facts_write "$project_dir"
    site_ensure_env "$project_dir"
    apply_render "$staged" "$project_dir" || true
    echo "Updated. Recreate the containers with:"
    echo "  cd $site && docker compose up -d --force-recreate"
    return 0
}

if [ "$MODE" = "update" ]; then
    if [ "$UPDATE_ALL" -eq 1 ]; then
        [ "${#UPDATE_SITES[@]}" -eq 0 ] || die "Name sites or pass --all, not both."
        while IFS= read -r compose; do
            site="$(basename "$(dirname "$compose")")"
            [ "$site" != "traefik" ] || continue
            UPDATE_SITES+=("$site")
        done < <(find "$BASE_DIR" -mindepth 2 -maxdepth 2 -name docker-compose.yaml | sort)
    fi
    [ "${#UPDATE_SITES[@]}" -ne 0 ] || { usage >&2; die "Name a site to update, or pass --all."; }

    updated=0
    skipped=0
    for site in "${UPDATE_SITES[@]}"; do
        [[ "$site" =~ $SITE_NAME_RE ]] || { warn "'$site' is not a valid project name, skipping."; skipped=$((skipped + 1)); continue; }
        if update_site "$site"; then
            updated=$((updated + 1))
        else
            skipped=$((skipped + 1))
        fi
    done

    printf '\n--- Done ---\n\n'
    printf '%s site(s) handled, %s skipped.\n' "$updated" "$skipped"
    exit 0
fi

# --- Prerequisites -----------------------------------------------------------

require_command docker "See https://docs.docker.com/engine/install/"
require_command mkcert "See https://github.com/FiloSottile/mkcert#installation"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "The Docker daemon is not reachable."

CA_ROOT="$(mkcert -CAROOT)"
[ -f "$CA_ROOT/rootCA.pem" ] || die "The mkcert local CA is missing. Run 'mkcert -install' once, then try again."

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

# An existing site answers most of this itself, so re-running over one is a
# matter of pressing return.
read -r -p "Enter project directory name (e.g., my-blog): " reply || true
SITE_NAME="${reply,,}"
[[ "$SITE_NAME" =~ $SITE_NAME_RE ]] \
    || die "The project name may only contain a-z, 0-9, '-' and '_', and must start with a letter or digit."

PROJECT_DIR="$BASE_DIR/$SITE_NAME"
WANTED_NAME="$SITE_NAME"
site_facts_load "$PROJECT_DIR" || site_facts_reset
SITE_NAME="$WANTED_NAME"

if [ "$SITE_FACTS_INFERRED" -eq 1 ]; then
    printf '\n%s exists but has no site.conf. Recovered from its files:\n' "$SITE_NAME"
    site_facts_print
fi

reply=""
read -r -p "Enter domain (e.g., my-blog.test)${DOMAIN:+ [$DOMAIN]}: " reply || true
DOMAIN="${reply:-$DOMAIN}"
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ $SITE_HOSTNAME_RE ]] || die "'$DOMAIN' does not look like a hostname."
case "$DOMAIN" in
    *.test) ;;
    *) printf 'Note: .test is reserved for local use (RFC 6761) and can never be registered.\n'
       printf 'A public TLD such as .dev may already belong to someone else, and then only\n'
       printf 'the /etc/hosts entry keeps traffic off their server.\n' ;;
esac

# A recorded value is offered back, and "-" is how you take one away.
reply=""
read -r -p "Enter production domain to fall back to for uploads (optional, '-' to clear)${PROD_DOMAIN:+ [$PROD_DOMAIN]}: " reply || true
PROD_DOMAIN="${reply:-$PROD_DOMAIN}"
[ "$PROD_DOMAIN" != "-" ] || PROD_DOMAIN=""
PROD_DOMAIN="${PROD_DOMAIN,,}"
PROD_DOMAIN="${PROD_DOMAIN#http://}"
PROD_DOMAIN="${PROD_DOMAIN#https://}"
PROD_DOMAIN="${PROD_DOMAIN%%/*}"

reply=""
read -r -p "Enter theme repository slug from github.com/redandbluefi (optional, '-' to clear)${THEME_SLUG:+ [$THEME_SLUG]}: " reply || true
THEME_SLUG="${reply:-$THEME_SLUG}"
[ "$THEME_SLUG" != "-" ] || THEME_SLUG=""
THEME_SLUG="${THEME_SLUG,,}"
if [ -n "$THEME_SLUG" ]; then
    [ -x "$BASE_DIR/setup-theme.sh" ] || die "setup-theme.sh is missing or not executable."
fi

# Regenerating a network as a single site would put WP_HOME and WP_SITEURL back
# and pin every subsite to the main domain.
if [ "$NETWORK_GIVEN" -eq 1 ]; then
    NETWORK_TYPE="$REQUESTED_NETWORK"
elif [ -n "$NETWORK_TYPE" ]; then
    die "$SITE_NAME is already a $NETWORK_TYPE network. Re-run with --multisite=$NETWORK_TYPE."
fi

site_facts_validate

if [ -e "$PROJECT_DIR" ]; then
    printf '\n%s already exists.\n' "$PROJECT_DIR"
    printf 'Continuing rewrites docker-compose.yaml, nginx.conf, the PHP ini files and\n'
    printf 'composer.json. The database volume, .env and everything in src/ are left\n'
    printf 'alone.\n'
    reply=""
    read -r -p "Continue? [y/N] " reply || true
    [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."
fi

# --- Project files -----------------------------------------------------------

info "Recording $SITE_NAME/site.conf"
site_facts_write "$PROJECT_DIR"
site_facts_print

info "Rendering the project files"
site_render "$PROJECT_DIR" "$TEMPLATE_DIR"
site_prune_stale "$PROJECT_DIR" || warn "Could not remove a file this render no longer produces."
printf '%s\n' "${SITE_RENDERED_FILES[@]}" | sed 's/^/  /'

info "Preparing .env"
if [ -f "$PROJECT_DIR/.env" ]; then
    echo "Keeping the existing .env."
else
    site_ensure_env "$PROJECT_DIR"
    echo "Created."
fi

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
# node_modules/ keep their execute bit. Files named .env are skipped: they hold
# secrets, and the compose CLI and the theme build both read them as you rather
# than as www-data.
sudo find "$PROJECT_DIR" -type f ! -name .env -exec chmod g+rw {} +

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
Env vars   $SITE_NAME/.env
Manifest   $SITE_NAME/site.conf

WP-CLI     cd $SITE_NAME && docker compose run --rm wp-cli wp <command>
Logs       cd $SITE_NAME && docker compose logs -f
Stop       cd $SITE_NAME && docker compose down
Update     ./create-site.sh --update $SITE_NAME
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

# The site containers send their outbound HTTP through this, and under a VPN
# it is the only route they have.
if ! docker ps --format '{{.Names}}' | grep -qx egress-proxy; then
    printf '\nWarning: the egress-proxy container is not running, so the site containers\n'
    printf 'reach nothing outside this machine: no plugin installs, no WP Migrate and no\n'
    printf 'Composer from WP-CLI. Start it with:\n'
    printf '  cd traefik && docker compose up -d\n'
fi

if ! docker ps --format '{{.Names}}' | grep -qx traefik; then
    printf '\nWarning: the traefik container is not running, so the site is not reachable yet.\n'
    printf 'Start it with: cd traefik && docker compose up -d\n'
elif ! traefik_on_proxy_network; then
    printf '\nWarning: traefik is running but is not attached to the %s network, so the\n' "$PROXY_NETWORK"
    printf 'site is not reachable yet. Reattach it with:\n'
    printf '  cd traefik && docker compose up -d --force-recreate\n'
fi
