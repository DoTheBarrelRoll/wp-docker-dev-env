#!/bin/bash

# Configuration
# Base dir is the current directory where the script is located, you can change it to your desired path
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAEFIK_DIR="$BASE_DIR/traefik"
CERT_DIR="$TRAEFIK_DIR/certs"
TEMPLATE="$TRAEFIK_DIR/templates/wp-template.yaml"
DYNAMIC_CONF="$TRAEFIK_DIR/dynamic_conf.yaml"
NGINX_CONF="$TRAEFIK_DIR/templates/nginx.conf"
UPLOADS_INCLUDE=""

export UID=$(id -u)
export GID=$(id -g)

# Get inputs
read -p "Enter project directory name (e.g., my-blog): " SITE_NAME
read -p "Enter domain (e.g., myblog.dev): " DOMAIN
read -p "Enter production URL (optional, leave blank to skip): " PROD_URL


PROJECT_DIR="$BASE_DIR/$SITE_NAME"

echo "--- Creating project directory ---"
mkdir -p "$PROJECT_DIR/src"

sudo chown -R $USER:33 "$PROJECT_DIR"
sudo chmod -R 775 "$PROJECT_DIR"

echo "--- Generating nginx.conf ---"
mkdir -p "$PROJECT_DIR/nginx"
mkdir -p "$PROJECT_DIR/nginx/configs"


if [ -n "$PROD_URL" ]; then
    echo "--- Generating uploads-proxy.conf ---"
    # Use | as delimiter instead of / to avoid path issues
    sed -e "s|\${PROD_URL}|$PROD_URL|g" "$TRAEFIK_DIR/templates/uploads-proxy.conf" > "$PROJECT_DIR/nginx/configs/uploads-proxy.conf"
    
    # Define the include directive
    UPLOADS_INCLUDE="include /etc/nginx/custom_includes/uploads-proxy.conf;"
fi


# We inject the include directive (or nothing) into the nginx.conf template
sed -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${UPLOADS_INCLUDE}|$UPLOADS_INCLUDE|g" \
    "$NGINX_CONF" > "$PROJECT_DIR/nginx/nginx.conf"

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

# Give the setup container a moment to breathe and create files
echo "--- Finalizing permissions on generated files ---"
sudo chown -R $USER:33 "$PROJECT_DIR/src"
sudo find "$PROJECT_DIR/src" -type d -exec chmod 2775 {} +
sudo find "$PROJECT_DIR/src" -type f -exec chmod 0664 {} +

echo "--- Done! ---"
echo "WordPress takes about 20 seconds to start up. You can check the logs with 'docker compose logs -f' in the project directory."
echo "Next steps:"
echo "1. Add '127.0.0.1 $DOMAIN' to your /etc/hosts file."
echo "2. Visit https://$DOMAIN"