#!/bin/bash

# Configuration
BASE_DIR="/home/miikka/dev"
TRAEFIK_DIR="$BASE_DIR/traefik"
CERT_DIR="$TRAEFIK_DIR/certs"
TEMPLATE="$TRAEFIK_DIR/templates/wp-template.yaml"
DYNAMIC_CONF="$TRAEFIK_DIR/dynamic_conf.yaml"
NGINX_CONF="$TRAEFIK_DIR/templates/nginx.conf"

export UID=$(id -u)
export GID=$(id -g)

# Get inputs
read -p "Enter project folder name (e.g., my-blog): " SITE_NAME
read -p "Enter domain (e.g., myblog.dev): " DOMAIN

PROJECT_DIR="$BASE_DIR/$SITE_NAME"

echo "--- Creating project directory ---"
mkdir -p "$PROJECT_DIR/wp-content"

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

echo "--- Setting permissions ---"
mkdir -p "$PROJECT_DIR/wp-content"
chmod -R 775 "$PROJECT_DIR/wp-content"

echo "--- Starting the container ---"
cd "$PROJECT_DIR" && docker compose up -d

echo "--- Done! ---"
echo "Next steps:"
echo "1. Add '127.0.0.1 $DOMAIN' to your /etc/hosts file."
echo "2. Visit https://$DOMAIN"