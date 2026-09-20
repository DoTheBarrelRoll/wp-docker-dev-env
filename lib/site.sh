#!/usr/bin/env bash
#
# What a local site is made of, and how its project files are produced.
# Sourced by create-site.sh, setup-theme.sh and delete-site.sh.
#
# The interface is five variables:
#
#   SITE_NAME     project directory name, e.g. my-blog
#   DOMAIN        local domain, e.g. my-blog.test
#   PROD_DOMAIN   production domain for the uploads fallback, may be empty
#   NETWORK_TYPE  "" for a single site, or "subdomain" or "subdirectory"
#   THEME_SLUG    theme repository at github.com/redandbluefi, may be empty
#
# site_facts_load fills them, site_facts_write records them in the project's
# site.conf, and site_render turns them into the project's files. Nothing here
# starts a container, issues a certificate, asks for sudo or reads a prompt, so
# a render can be produced anywhere and compared before it is kept.

SITE_MANIFEST="site.conf"

SITE_HOSTNAME_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
SITE_NAME_RE='^[a-z0-9][a-z0-9_-]*$'
SITE_THEME_SLUG_RE='^[a-z0-9][a-z0-9._-]*$'

SITE_NAME=""
DOMAIN=""
PROD_DOMAIN=""
NETWORK_TYPE=""
THEME_SLUG=""

# Set by site_facts_load when the facts were recovered from the generated files
# instead of read from a manifest, so a caller can have them confirmed.
SITE_FACTS_INFERRED=0

# Relative paths written by the last site_render, so that a caller can compare
# them against a project directory and drop the ones that are now stale.
SITE_RENDERED_FILES=()

# --- Output ------------------------------------------------------------------

info() { printf '\n--- %s ---\n' "$1"; }
warn() { printf 'Warning: %s\n' "$1" >&2; }
die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found. $2"
}

# --- Facts -------------------------------------------------------------------

site_facts_reset() {
    SITE_NAME=""
    DOMAIN=""
    PROD_DOMAIN=""
    NETWORK_TYPE=""
    THEME_SLUG=""
    SITE_FACTS_INFERRED=0
}

# Reports the first unusable value on stderr and returns 1, so that a caller
# working through several sites can skip one without giving up on the rest.
site_facts_check() {
    local problem=""
    if [[ ! "$SITE_NAME" =~ $SITE_NAME_RE ]]; then
        problem="The project name may only contain a-z, 0-9, '-' and '_', and must start with a letter or digit."
    elif [[ ! "$DOMAIN" =~ $SITE_HOSTNAME_RE ]]; then
        problem="'$DOMAIN' does not look like a hostname."
    elif [ -n "$PROD_DOMAIN" ] && [[ ! "$PROD_DOMAIN" =~ $SITE_HOSTNAME_RE ]]; then
        problem="'$PROD_DOMAIN' does not look like a hostname."
    elif [ -n "$THEME_SLUG" ] && [[ ! "$THEME_SLUG" =~ $SITE_THEME_SLUG_RE ]]; then
        problem="'$THEME_SLUG' is not a valid repository slug."
    else
        case "$NETWORK_TYPE" in
            "" | subdomain | subdirectory) ;;
            *) problem="The network type is 'subdomain' or 'subdirectory', not '$NETWORK_TYPE'." ;;
        esac
    fi
    [ -z "$problem" ] || { printf 'Error: %s\n' "$problem" >&2; return 1; }
    return 0
}

site_facts_validate() {
    site_facts_check || exit 1
}

site_facts_write() {
    local project_dir="$1"
    mkdir -p "$project_dir"
    cat > "$project_dir/$SITE_MANIFEST" <<EOF
# What this site is. Written by create-site.sh, read by every script that needs
# to know something about the site, and the input to
#
#   ./create-site.sh --update $SITE_NAME
#
# which re-renders docker-compose.yaml, nginx.conf, the PHP ini files and the
# mu-plugins from the current templates. Edit a value here and re-run that to
# put it into effect. The database, .env and everything in src/ are left alone.
SITE_NAME=$SITE_NAME
DOMAIN=$DOMAIN
PROD_DOMAIN=$PROD_DOMAIN
NETWORK_TYPE=$NETWORK_TYPE
THEME_SLUG=$THEME_SLUG
EOF
}

# Reads the manifest into the five variables. Returns 1 when there is none.
# The file is parsed rather than sourced, so that a stray line in it cannot run
# as a command.
site_facts_read() {
    local project_dir="$1"
    local file="$project_dir/$SITE_MANIFEST"
    [ -f "$file" ] || return 1

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#'* | '') continue ;;
        esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        # Trim surrounding whitespace and one layer of quotes.
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        case "$key" in
            SITE_NAME) SITE_NAME="$value" ;;
            DOMAIN) DOMAIN="$value" ;;
            PROD_DOMAIN) PROD_DOMAIN="$value" ;;
            NETWORK_TYPE) NETWORK_TYPE="$value" ;;
            THEME_SLUG) THEME_SLUG="$value" ;;
            *) warn "Ignoring unknown key '$key' in $file." ;;
        esac
    done < "$file"
    return 0
}

# Recovers the facts from the files a previous run generated, for the sites
# that predate the manifest. Every source here is a generated artefact, so this
# runs once per site, to produce a manifest, and never again.
site_facts_infer() {
    local project_dir="$1"
    SITE_NAME="$(basename "$project_dir")"

    if [ -f "$project_dir/nginx/nginx.conf" ]; then
        DOMAIN="$(awk '/^[[:space:]]*server_name[[:space:]]/ { gsub(/;/, "", $2); print $2; exit }' \
            "$project_dir/nginx/nginx.conf")"
    fi

    if [ -f "$project_dir/nginx/configs/uploads-proxy.conf" ]; then
        PROD_DOMAIN="$(sed -nE 's#^[[:space:]]*return[[:space:]]+30[0-9][[:space:]]+https?://([^/$]+).*#\1#p' \
            "$project_dir/nginx/configs/uploads-proxy.conf" | head -1)"
    fi

    # wp-config.php is written by WP-CLI when the network is installed, so it is
    # the one source that cannot be out of date.
    if [ -f "$project_dir/src/wp-config.php" ] \
        && grep -qE "define\( *'MULTISITE', *true" "$project_dir/src/wp-config.php"; then
        if grep -qE "define\( *'SUBDOMAIN_INSTALL', *true" "$project_dir/src/wp-config.php"; then
            NETWORK_TYPE="subdomain"
        else
            NETWORK_TYPE="subdirectory"
        fi
    elif [ -f "$project_dir/nginx/configs/multisite-subdirectory.conf" ]; then
        NETWORK_TYPE="subdirectory"
    elif [ -f "$project_dir/nginx/nginx.conf" ] \
        && grep -qE '^[[:space:]]*server_name[^;]*\*\.' "$project_dir/nginx/nginx.conf"; then
        NETWORK_TYPE="subdomain"
    fi

    # Only a single checkout identifies itself. A project with a parent and a
    # child theme, or with none, leaves the slug for the operator to fill in.
    local themes_dir="$project_dir/src/wp-content/themes"
    if [ -d "$themes_dir" ]; then
        local found=() gitdir
        while IFS= read -r gitdir; do
            found+=("$(basename "$(dirname "$gitdir")")")
        done < <(find "$themes_dir" -mindepth 2 -maxdepth 2 -name .git 2>/dev/null | sort)
        if [ "${#found[@]}" -eq 1 ]; then
            THEME_SLUG="${found[0]}"
        fi
    fi

    SITE_FACTS_INFERRED=1
}

# Reads the manifest, falling back to the generated files. Returns 1 when the
# project directory holds nothing to go on.
site_facts_load() {
    local project_dir="$1"
    site_facts_reset
    if site_facts_read "$project_dir"; then
        [ -n "$SITE_NAME" ] || SITE_NAME="$(basename "$project_dir")"
        return 0
    fi
    [ -d "$project_dir" ] || return 1
    site_facts_infer "$project_dir"
    [ -n "$DOMAIN" ] || return 1
    return 0
}

site_facts_print() {
    printf '  SITE_NAME     %s\n' "$SITE_NAME"
    printf '  DOMAIN        %s\n' "$DOMAIN"
    printf '  PROD_DOMAIN   %s\n' "${PROD_DOMAIN:-(none)}"
    printf '  NETWORK_TYPE  %s\n' "${NETWORK_TYPE:-(single site)}"
    printf '  THEME_SLUG    %s\n' "${THEME_SLUG:-(none)}"
}

# --- Render ------------------------------------------------------------------

SITE_TEMPLATES="wp-template.yaml nginx.conf multisite-subdirectory.conf composer.json
    php-fpm-dev.ini php-cli-dev.ini mu-dev-mail.php mu-dev-multisite.php uploads-proxy.conf"

site_templates_check() {
    local template_dir="$1" template
    for template in $SITE_TEMPLATES; do
        [ -f "$template_dir/$template" ] || die "Template $template_dir/$template is missing."
    done
}

# Writes a site's project files from the five variables and nothing else.
# Pure in the sense that matters here: no container, no certificate, no sudo,
# no network and no prompt, so the same call can render into the project
# directory or into a throwaway directory for comparison.
#
#   site_render <output-dir> <template-dir>
#
# Leaves the paths it wrote in SITE_RENDERED_FILES.
site_render() {
    local outdir="$1" template_dir="$2"

    # A single site pins its URL with WP_HOME and WP_SITEURL. A network cannot:
    # it reads every site URL from the network tables, so those two lines are
    # dropped from the compose file and WP-CLI writes the multisite constants
    # into src/wp-config.php when it installs the network instead.
    local server_name="$DOMAIN"
    local traefik_rule="Host(\`$DOMAIN\`)"
    local is_installed="is-installed"
    local core_install="install"
    local plugin_activate="plugin activate"
    local compose_filter=()

    if [ -n "$NETWORK_TYPE" ]; then
        compose_filter=(-e "/define( 'WP_HOME'/d" -e "/define( 'WP_SITEURL'/d")
        is_installed="is-installed --network"
        core_install="multisite-install"
        plugin_activate="plugin activate --network"
    fi

    if [ "$NETWORK_TYPE" = "subdomain" ]; then
        core_install="multisite-install --subdomains"
        server_name="$DOMAIN *.$DOMAIN"
        # Traefik v3 matches HostRegexp with a Go regular expression. The dots
        # are literal, written as [.] so that no backslash has to survive YAML,
        # and the anchor is written as $$, which is how Compose escapes a
        # literal $.
        traefik_rule="Host(\`$DOMAIN\`) || HostRegexp(\`^.+[.]${DOMAIN//./[.]}\$\$\`)"
    fi

    SITE_RENDERED_FILES=()
    mkdir -p "$outdir/src/wp-content/mu-plugins" "$outdir/nginx/configs" "$outdir/php"

    local uploads_fallback nginx_filter=()
    if [ -n "$PROD_DOMAIN" ]; then
        sed -e "s|\${PROD_URL}|$PROD_DOMAIN|g" \
            "$template_dir/uploads-proxy.conf" > "$outdir/nginx/configs/uploads-proxy.conf"
        SITE_RENDERED_FILES+=("nginx/configs/uploads-proxy.conf")
        uploads_fallback="include /etc/nginx/custom_includes/uploads-proxy.conf;"
    else
        uploads_fallback="return 404;"
    fi

    if [ "$NETWORK_TYPE" = "subdirectory" ]; then
        cp "$template_dir/multisite-subdirectory.conf" "$outdir/nginx/configs/multisite-subdirectory.conf"
        SITE_RENDERED_FILES+=("nginx/configs/multisite-subdirectory.conf")
        nginx_filter=(-e "s|\${MULTISITE_REWRITES}|include /etc/nginx/custom_includes/multisite-subdirectory.conf;|")
    else
        nginx_filter=(-e "/\${MULTISITE_REWRITES}/d")
    fi

    sed "${nginx_filter[@]}" \
        -e "s|\${SERVER_NAME}|$server_name|g" \
        -e "s|\${UPLOADS_FALLBACK}|$uploads_fallback|g" \
        "$template_dir/nginx.conf" > "$outdir/nginx/nginx.conf"
    SITE_RENDERED_FILES+=("nginx/nginx.conf")

    cp "$template_dir/php-fpm-dev.ini" "$outdir/php/php-fpm-dev.ini"
    cp "$template_dir/php-cli-dev.ini" "$outdir/php/php-cli-dev.ini"
    SITE_RENDERED_FILES+=("php/php-fpm-dev.ini" "php/php-cli-dev.ini")

    cp "$template_dir/mu-dev-mail.php" "$outdir/src/wp-content/mu-plugins/dev-mail.php"
    SITE_RENDERED_FILES+=("src/wp-content/mu-plugins/dev-mail.php")
    if [ -n "$NETWORK_TYPE" ]; then
        cp "$template_dir/mu-dev-multisite.php" "$outdir/src/wp-content/mu-plugins/dev-multisite.php"
        SITE_RENDERED_FILES+=("src/wp-content/mu-plugins/dev-multisite.php")
    fi

    sed "${compose_filter[@]}" \
        -e "s/\${SITE_NAME}/$SITE_NAME/g" \
        -e "s/\${DOMAIN}/$DOMAIN/g" \
        -e "s@\${TRAEFIK_RULE}@$traefik_rule@g" \
        -e "s@\${IS_INSTALLED}@$is_installed@g" \
        -e "s@\${CORE_INSTALL}@$core_install@g" \
        -e "s@\${PLUGIN_ACTIVATE}@$plugin_activate@g" \
        "$template_dir/wp-template.yaml" > "$outdir/docker-compose.yaml"
    SITE_RENDERED_FILES+=("docker-compose.yaml")

    sed -e "s/\${SITE_NAME}/$SITE_NAME/g" "$template_dir/composer.json" > "$outdir/src/composer.json"
    SITE_RENDERED_FILES+=("src/composer.json")
}

# The files site_render owns, whether or not this site's facts produce them, so
# that a render can also take one away.
site_managed_files() {
    printf '%s\n' \
        docker-compose.yaml \
        nginx/nginx.conf \
        nginx/configs/uploads-proxy.conf \
        nginx/configs/multisite-subdirectory.conf \
        php/php-fpm-dev.ini \
        php/php-cli-dev.ini \
        src/wp-content/mu-plugins/dev-mail.php \
        src/wp-content/mu-plugins/dev-multisite.php \
        src/composer.json
}

# Removes the files site_render owns but did not produce this time, so that
# taking the production domain away also takes its nginx include away, and a
# network turned back into a single site loses dev-multisite.php. Run it after
# site_render, against the directory that was rendered into.
site_prune_stale() {
    local project_dir="$1" rel status=0
    while IFS= read -r rel; do
        [ -e "$project_dir/$rel" ] || continue
        if ! printf '%s\n' "${SITE_RENDERED_FILES[@]}" | grep -qxF "$rel"; then
            rm -f "$project_dir/$rel" || status=1
        fi
    done < <(site_managed_files)
    return "$status"
}

# Holds secrets once a project is under way, so an existing file is never
# rewritten. The compose file marks it optional, and a site that needs nothing
# from it simply leaves it as comments.
site_ensure_env() {
    local project_dir="$1"
    [ ! -f "$project_dir/.env" ] || return 0
    cat > "$project_dir/.env" <<'EOF'
# Environment variables for this site, passed to PHP-FPM and to WP-CLI. A theme
# or plugin reads them with getenv(). One KEY=value per line, no quotes needed:
#
#   SOME_API_KEY=xxxx
#
# This file stays outside src/, so nginx never serves it, and it is not in
# version control. After editing it run
#
#   docker compose up -d --force-recreate wordpress
#
# because a running container keeps the environment it was created with.
EOF
    chmod 600 "$project_dir/.env"
}
