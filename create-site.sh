#!/bin/bash

# Configuration
# Base dir is the current directory where the script is located, you can change it to your desired path
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAEFIK_DIR="$BASE_DIR/traefik"
CERT_DIR="$TRAEFIK_DIR/certs"
TEMPLATE="$TRAEFIK_DIR/templates/wp-template.yaml"
DYNAMIC_CONF="$TRAEFIK_DIR/dynamic_conf.yaml"
NGINX_CONF="$TRAEFIK_DIR/templates/nginx.conf"

export UID=$(id -u)
export GID=$(id -g)

# Get inputs
read -p "Enter project directory name (e.g., my-blog): " SITE_NAME
read -p "Enter domain (e.g., myblog.dev): " DOMAIN

PROJECT_DIR="$BASE_DIR/$SITE_NAME"

echo "--- Creating project directory ---"
mkdir -p "$PROJECT_DIR/src"

echo "--- Generating SSL Certificates ---"
mkcert -cert-file "$CERT_DIR/$SITE_NAME-cert.pem" -key-file "$CERT_DIR/$SITE_NAME-key.pem" "$DOMAIN" "*.$DOMAIN"

echo "--- Updating Traefik Dynamic Config ---"
# Check if entry already exists to avoid duplicates
if ! grep -q "$SITE_NAME-cert.pem" "$DYNAMIC_CONF"; then
cat >> "$DYNAMIC_CONF" <<EOF
    - certFile: /etc/traefik/certs/$SITE_NAME-cert.pem
      keyFile: /etc/traefik/certs/$SITE_NAME-key.pem
EOF
fi

echo "--- Generating docker-compose.yaml ---"
# Use sed to replace placeholders and save to new directory
sed -e "s/\${SITE_NAME}/$SITE_NAME/g" -e "s/\${DOMAIN}/$DOMAIN/g" -e "s/\${UID}/$UID/g" -e "s/\${GID}/$GID/g" "$TEMPLATE" > "$PROJECT_DIR/docker-compose.yaml"

echo "--- Copying over nginx.conf ---"
mkdir -p "$PROJECT_DIR/nginx"
sed -e "s/\${DOMAIN}/$DOMAIN/g" "$NGINX_CONF" > "$PROJECT_DIR/nginx/nginx.conf"

echo "--- Installing Plugins via Composer ---"
# 1. Prepare composer.json
sed -e "s/\${SITE_NAME}/$SITE_NAME/g" "$TRAEFIK_DIR/templates/composer.json" > "$PROJECT_DIR/src/composer.json"

# 2. Check if auth.json exists before proceeding with installation
if [ -f "$TRAEFIK_DIR/templates/auth.json" ]; then
    echo "Found auth.json, proceeding with composer install..."
    cp "$TRAEFIK_DIR/templates/auth.json" "$PROJECT_DIR/src/auth.json"
    
    # Run composer install now that credentials are in place
    cd "$PROJECT_DIR/src" && composer install --no-dev --optimize-autoloader
else
    echo "Notice: auth.json not found in $TRAEFIK_DIR/templates/. Skipping composer install."
fi

echo "--- Setting permissions ---"
mkdir -p "$PROJECT_DIR/src/wp-content"
chmod -R 775 "$PROJECT_DIR/src/wp-content"

echo "--- Starting the container ---"
cd "$PROJECT_DIR" && docker compose up -d

echo "--- Done! ---"
echo "WordPress takes about 20 seconds to start up. You can check the logs with 'docker compose logs -f' in the project directory."
echo "Next steps:"
echo "1. Add '127.0.0.1 $DOMAIN' to your /etc/hosts file."
echo "2. Visit https://$DOMAIN"