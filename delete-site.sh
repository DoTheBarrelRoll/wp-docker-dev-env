#!/usr/bin/env bash
#
# Removes a local site created by create-site.sh: containers, the database
# volume, the certificate, the Traefik entry and, on request, the project
# directory and its /etc/hosts entry.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAEFIK_DIR="$BASE_DIR/traefik"
CERT_DIR="$TRAEFIK_DIR/certs"
DYNAMIC_CONF="$TRAEFIK_DIR/dynamic_conf.yaml"

info() { printf '\n--- %s ---\n' "$1"; }
die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

SITE_NAME="${1:-}"
[ -n "$SITE_NAME" ] || die "Usage: $0 <project-directory-name>"
[[ "$SITE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "'$SITE_NAME' is not a valid project name."

PROJECT_DIR="$BASE_DIR/$SITE_NAME"
[ "$PROJECT_DIR" != "$BASE_DIR" ] || die "Refusing to operate on the root directory."

DOMAIN=""
if [ -f "$PROJECT_DIR/nginx/nginx.conf" ]; then
    DOMAIN="$(awk '/^[[:space:]]*server_name[[:space:]]/ { gsub(/;/, "", $2); print $2; exit }' \
        "$PROJECT_DIR/nginx/nginx.conf")"
fi

if [ ! -d "$PROJECT_DIR" ] \
    && [ ! -f "$CERT_DIR/$SITE_NAME-cert.pem" ] \
    && ! docker volume inspect "${SITE_NAME}_db_data" >/dev/null 2>&1; then
    die "Found nothing for '$SITE_NAME': no project directory, certificate or database volume."
fi

# --- Confirmation ------------------------------------------------------------

printf 'About to remove the local site "%s"%s.\n\n' "$SITE_NAME" "${DOMAIN:+ ($DOMAIN)}"
printf 'This deletes:\n'
printf '  - its containers and the volume %s_db_data, which is the local database\n' "$SITE_NAME"
printf '  - traefik/certs/%s-cert.pem and %s-key.pem\n' "$SITE_NAME" "$SITE_NAME"
printf '  - the certificate entry in traefik/dynamic_conf.yaml\n'

if [ -d "$PROJECT_DIR/src" ]; then
    repos="$(find "$PROJECT_DIR/src" -maxdepth 5 -type d -name .git -prune 2>/dev/null || true)"
    if [ -n "$repos" ]; then
        printf '\nGit repositories inside this project:\n'
        while IFS= read -r gitdir; do
            repo="${gitdir%/.git}"
            dirty="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)"
            unpushed="$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | wc -l)"
            printf '  %s: %s uncommitted change(s), %s unpushed commit(s)\n' \
                "${repo#"$BASE_DIR"/}" "$dirty" "$unpushed"
        done <<< "$repos"
    fi
fi

printf '\n'
confirm=""
read -r -p "Type the project name to confirm: " confirm || true
[ "$confirm" = "$SITE_NAME" ] || die "Aborted."

# --- Containers and volume ---------------------------------------------------

if [ -f "$PROJECT_DIR/docker-compose.yaml" ]; then
    info "Stopping containers and removing the database volume"
    (cd "$PROJECT_DIR" && docker compose down --volumes --remove-orphans)
else
    info "No docker-compose.yaml, removing the database volume directly"
    docker volume rm "${SITE_NAME}_db_data" >/dev/null 2>&1 || true
fi

# --- Certificates ------------------------------------------------------------

info "Removing certificates"
rm -f "$CERT_DIR/$SITE_NAME-cert.pem" "$CERT_DIR/$SITE_NAME-key.pem"

if [ -f "$DYNAMIC_CONF" ]; then
    info "Removing the Traefik certificate entry"
    tmp_conf="$(mktemp)"
    # The leading slash keeps a name from matching a longer one, so that
    # removing "site" leaves "old-site" alone.
    awk -v cert="/certs/$SITE_NAME-cert.pem" -v key="/certs/$SITE_NAME-key.pem" '
        /certFile:/ && index($0, cert) { next }
        /keyFile:/ && index($0, key) { next }
        { print }
    ' "$DYNAMIC_CONF" > "$tmp_conf"
    cat "$tmp_conf" > "$DYNAMIC_CONF"
    rm -f "$tmp_conf"
fi

# --- Project directory -------------------------------------------------------

if [ -d "$PROJECT_DIR" ]; then
    reply=""
    read -r -p "Delete $PROJECT_DIR and everything in it, including src/? [y/N] " reply || true
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        info "Deleting $PROJECT_DIR"
        # Container-created files are owned by uid 33, so this needs sudo.
        sudo rm -rf "$PROJECT_DIR"
    else
        printf 'Keeping %s.\n' "$PROJECT_DIR"
    fi
fi

# --- Hosts file --------------------------------------------------------------

if [ -n "$DOMAIN" ]; then
    hosts_line="127.0.0.1 $DOMAIN mail.$DOMAIN"
    if grep -qxF "$hosts_line" /etc/hosts; then
        reply=""
        read -r -p "Remove '$hosts_line' from /etc/hosts (needs sudo)? [y/N] " reply || true
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            tmp_hosts="$(mktemp)"
            grep -vxF "$hosts_line" /etc/hosts > "$tmp_hosts"
            sudo cp "$tmp_hosts" /etc/hosts
            rm -f "$tmp_hosts"
        fi
    elif grep -q "$DOMAIN" /etc/hosts; then
        printf '\nNote: /etc/hosts still mentions %s on a hand-edited line. Left untouched.\n' "$DOMAIN"
    fi
fi

printf '\n--- Done ---\n'
