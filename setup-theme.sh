#!/usr/bin/env bash
#
# Clones a theme from github.com/redandbluefi into a local site and gets it
# ready to run: .env, auth.json, Composer dependencies and an asset build.
# Safe to run against an existing site, and safe to run twice.
#
# Usage: ./setup-theme.sh <project-directory-name> <theme-slug> [domain]

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$BASE_DIR/traefik/templates"
LICENSES_FILE="$TEMPLATE_DIR/licenses.env"
GITHUB_ORG="redandbluefi"
WWW_DATA_GID=33

info() { printf '\n--- %s ---\n' "$1"; }
warn() { printf 'Warning: %s\n' "$1" >&2; }
die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found. $2"
}

# --- Arguments ---------------------------------------------------------------

SITE_NAME="${1:-}"
THEME_SLUG="${2:-}"
DOMAIN="${3:-}"

[ -n "$SITE_NAME" ] && [ -n "$THEME_SLUG" ] \
    || die "Usage: $0 <project-directory-name> <theme-slug> [domain]"
[[ "$SITE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "'$SITE_NAME' is not a valid project name."
[[ "$THEME_SLUG" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "'$THEME_SLUG' is not a valid repository slug."

PROJECT_DIR="$BASE_DIR/$SITE_NAME"
[ -d "$PROJECT_DIR" ] || die "$PROJECT_DIR does not exist. Create the site first with ./create-site.sh."

THEMES_DIR="$PROJECT_DIR/src/wp-content/themes"
THEME_DIR="$THEMES_DIR/$THEME_SLUG"

if [ -z "$DOMAIN" ] && [ -f "$PROJECT_DIR/nginx/nginx.conf" ]; then
    DOMAIN="$(awk '/^[[:space:]]*server_name[[:space:]]/ { gsub(/;/, "", $2); print $2; exit }' \
        "$PROJECT_DIR/nginx/nginx.conf")"
fi
[ -n "$DOMAIN" ] || die "Could not read the local domain from the project. Pass it as the third argument."

SITE_URL="https://$DOMAIN"

# --- Clone -------------------------------------------------------------------

require_command git "See https://git-scm.com/downloads"

# WordPress creates wp-content/themes as www-data with mode 755, so a fresh
# site needs the mode relaxed before anything can be cloned into it.
if [ ! -w "$THEMES_DIR" ]; then
    if ! mkdir -p "$THEMES_DIR" 2>/dev/null; then
        info "Making $THEMES_DIR writable (needs sudo)"
        sudo chown "$USER:$WWW_DATA_GID" "$THEMES_DIR"
        sudo chmod 2775 "$THEMES_DIR"
    fi
fi

if [ -d "$THEME_DIR/.git" ]; then
    info "$THEME_SLUG is already cloned, skipping the clone"
elif [ -e "$THEME_DIR" ]; then
    die "$THEME_DIR exists but is not a git checkout. Move it aside first."
else
    info "Cloning $GITHUB_ORG/$THEME_SLUG"
    git clone --depth 1 "git@github.com:$GITHUB_ORG/$THEME_SLUG.git" "$THEME_DIR"
fi

# --- .env --------------------------------------------------------------------

info "Writing .env"
if [ ! -f "$THEME_DIR/.env" ]; then
    [ -f "$THEME_DIR/.envexample" ] || die "$THEME_SLUG has no .envexample to copy."
    cp "$THEME_DIR/.envexample" "$THEME_DIR/.env"
    echo "Created from .envexample."
else
    echo "Keeping the existing .env, only the proxy URL is updated."
fi

# printf rather than sed, so that characters special to a replacement string
# cannot corrupt the value.
if grep -qE '^[[:space:]]*proxyUrl[[:space:]]*=' "$THEME_DIR/.env"; then
    env_tmp="$(mktemp)"
    awk -v url="$SITE_URL" '
        /^[[:space:]]*proxyUrl[[:space:]]*=/ { printf "proxyUrl=\"%s\"\n", url; next }
        { print }
    ' "$THEME_DIR/.env" > "$env_tmp"
    cat "$env_tmp" > "$THEME_DIR/.env"
    rm -f "$env_tmp"
else
    printf 'proxyUrl="%s"\n' "$SITE_URL" >> "$THEME_DIR/.env"
fi
echo "proxyUrl set to $SITE_URL"

# --- auth.json ---------------------------------------------------------------

ACF_LICENSE=""
if [ -f "$LICENSES_FILE" ]; then
    ACF_LICENSE="$(sed -nE 's/^[[:space:]]*ACF_PRO_LICENSE[[:space:]]*=[[:space:]]*"?([^"[:space:]]*)"?.*/\1/p' \
        "$LICENSES_FILE" | head -1)"
fi

if [ -n "$ACF_LICENSE" ]; then
    [[ "$ACF_LICENSE" =~ ^[A-Za-z0-9+/=_.:-]+$ ]] \
        || die "ACF_PRO_LICENSE in $LICENSES_FILE contains unexpected characters."

    info "Writing auth.json"
    if [ -f "$THEME_DIR/auth.json.example" ]; then
        auth_tmp="$(mktemp)"
        # Only the ACF entry is rewritten, so other credentials in the example
        # survive. printf keeps the license out of a substitution pattern.
        awk -v lic="$ACF_LICENSE" -v url="$SITE_URL" '
            /connect\.advancedcustomfields\.com/ { in_acf = 1 }
            in_acf && /"username"/ {
                match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
                comma = ($0 ~ /,[[:space:]]*$/) ? "," : ""
                printf "%s\"username\": \"%s\"%s\n", indent, lic, comma
                next
            }
            in_acf && /"password"/ {
                match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
                comma = ($0 ~ /,[[:space:]]*$/) ? "," : ""
                printf "%s\"password\": \"%s\"%s\n", indent, url, comma
                in_acf = 0
                next
            }
            { print }
        ' "$THEME_DIR/auth.json.example" > "$auth_tmp"
        cat "$auth_tmp" > "$THEME_DIR/auth.json"
        rm -f "$auth_tmp"
    else
        cat > "$THEME_DIR/auth.json" <<EOF
{
  "http-basic": {
    "connect.advancedcustomfields.com": {
      "username": "$ACF_LICENSE",
      "password": "$SITE_URL"
    }
  }
}
EOF
    fi
    echo "ACF Pro credentials written for $SITE_URL"
else
    warn "No ACF_PRO_LICENSE found in $LICENSES_FILE. Copy licenses.env.example and fill it in."
fi

# --- Composer ----------------------------------------------------------------

composer_ran="not needed"
if [ -f "$THEME_DIR/composer.json" ]; then
    if [ -n "$ACF_LICENSE" ]; then
        require_command composer "See https://getcomposer.org/download/"
        info "Installing Composer dependencies"
        (cd "$THEME_DIR" && composer install --no-interaction)
        composer_ran="yes"
    else
        warn "Skipping composer install: ACF Pro cannot be downloaded without a license key."
        composer_ran="no"
    fi
fi

# --- Assets ------------------------------------------------------------------

assets_built="skipped"
if [ -f "$THEME_DIR/package.json" ]; then
    require_command pnpm "See https://pnpm.io/installation"

    info "Installing npm dependencies"
    if ! (cd "$THEME_DIR" && pnpm install); then
        # pnpm 10 and newer refuse to run dependency build scripts until they
        # are approved, and fail the install when any are pending. The themes
        # need them for esbuild and the image optimisers.
        warn "Install failed. Approving the dependency build scripts and retrying."
        (cd "$THEME_DIR" && pnpm approve-builds --all) || true
        (cd "$THEME_DIR" && pnpm install)
    fi

    info "Building assets"
    if (cd "$THEME_DIR" && pnpm run build); then
        assets_built="yes"
    else
        assets_built="no"
        warn "The asset build failed. The site and the theme are installed, but the theme has no compiled assets yet."
    fi
fi

# --- Permissions -------------------------------------------------------------

# We own everything we just cloned and built, so the group and modes can be
# fixed without sudo as long as this account is in the web server group.
# WordPress needs group write to save ACF field groups into the theme's
# acf-json directory.
info "Normalising theme file permissions"
if ! { chgrp -R "$WWW_DATA_GID" "$THEME_DIR" \
    && find "$THEME_DIR" -type d -exec chmod 2775 {} + \
    && find "$THEME_DIR" -type f -exec chmod g+rw {} +; } 2>/dev/null; then
    warn "Could not set group ownership on the theme. WordPress will not be able to write acf-json. Fix with: sudo chown -R $USER:$WWW_DATA_GID $THEME_DIR"
fi

# --- Activate ----------------------------------------------------------------

wp_cli() {
    (cd "$PROJECT_DIR" && docker compose run --rm wp-cli "$@")
}

activate=1
activate_reason=""

if [ "$composer_ran" = "no" ]; then
    activate=0
    activate_reason="its plugins are not installed, and the theme calls plugin functions such as get_field()"
elif [ -f "$THEME_DIR/style.css" ] \
    && grep -qiE '^[[:space:]]*Template:' "$THEME_DIR/style.css"; then
    parent="$(sed -nE 's/^[[:space:]]*[Tt]emplate:[[:space:]]*([^[:space:]]+).*/\1/p' \
        "$THEME_DIR/style.css" | head -1)"
    if [ -n "$parent" ] && [ ! -d "$THEMES_DIR/$parent" ]; then
        activate=0
        activate_reason="it is a child of '$parent', which is not installed"
    fi
fi

site_running=0
if [ -n "$(cd "$PROJECT_DIR" && docker compose ps --status running -q wordpress 2>/dev/null)" ]; then
    site_running=1
fi

activated="no"
if [ "$activate" -eq 0 ]; then
    warn "Not activating the theme, because $activate_reason. Activating it would take the site down."
elif [ "$site_running" -eq 0 ]; then
    echo
    echo "The site is not running, so the theme was not activated."
else
    info "Activating the theme"
    previous_theme="$(wp_cli wp option get stylesheet 2>/dev/null || true)"
    wp_cli wp theme activate "$THEME_SLUG"

    # A theme that fatals on load takes the whole site down, so verify that
    # WordPress still boots and back out if it does not.
    if wp_cli wp eval 'echo "theme-ok";' 2>/dev/null | grep -q 'theme-ok'; then
        activated="yes"
        echo "WordPress loads the theme cleanly."
    elif [ -n "$previous_theme" ]; then
        warn "WordPress fails to load with this theme. Reverting to '$previous_theme'."
        wp_cli wp --skip-themes theme activate "$previous_theme"
    else
        warn "WordPress fails to load with this theme, and the previous theme could not be determined. Recover with: docker compose run --rm wp-cli wp --skip-themes theme activate twentytwentyfive"
    fi
fi

cat <<EOF

--- Theme ready ---

Theme      $THEME_DIR
Proxy URL  $SITE_URL
Watch      cd $SITE_NAME/src/wp-content/themes/$THEME_SLUG && pnpm run dev
EOF

if [ "$activated" != "yes" ]; then
    printf 'Activate   cd %s && docker compose run --rm wp-cli wp theme activate %s\n' \
        "$SITE_NAME" "$THEME_SLUG"
fi
if [ "$assets_built" = "no" ]; then
    printf 'Assets     NOT BUILT, see the build output above\n'
    printf '           Starter themes need blocks/ and block-library/ before they build.\n'
fi
if [ -z "$ACF_LICENSE" ]; then
    printf 'Plugins    NOT INSTALLED, no ACF Pro license in %s\n' "$LICENSES_FILE"
fi
