# Local Dev Environment Setup

This environment automates the creation of high-performance WordPress instances using **Docker**, **Nginx + PHP-FPM**, and **Traefik**. It uses `mkcert` to provide valid local SSL for any `.test` or custom domain.

## ✨ Features

- **⚡ Nginx + PHP-FPM Stack:** High-performance architecture using `wordpress:fpm` and `nginx:alpine` for a smaller footprint and faster static file serving.
- **🔒 Automated Local SSL:** `create-site.sh` automatically generates `mkcert` certificates, stores them in `traefik/certs/`, and updates Traefik's `dynamic_conf.yaml`.
- **🌐 Traefik Reverse Proxy:** Centralized routing and load balancing through a Traefik container, allowing multiple projects to run on different domains simultaneously.
- **🔄 Automatic HTTPS:** Pre-configured Traefik routers ensure your local sites always load securely.
- **💾 Isolated Data Persistence:** Utilizes unique Docker named volumes (`${SITE_NAME}_db_data`) so your database survives container restarts and remains isolated from other projects.
- **🤖 One-Command Scaffolding:** `create-site.sh` handles directory creation, SSL generation, config templating, and site deployment in one go.
- **📁 Organized Directory Mapping:** Maps all WordPress core files into a local `./src` subfolder for easy IDE access while keeping your root project directory clean.

## 📂 Contents

- **`create-site.sh`**: The automation engine that prompts for site details and scaffolds the environment.
- **`traefik/`**: Configuration and assets for the Traefik reverse proxy setup:
  - `docker-compose.yaml`: Docker Compose configuration for running Traefik.
  - `dynamic_conf.yaml`: Main dynamic configuration for routing and SSL.
  - `certs/`: Directory for SSL certificates used by Traefik.
  - `templates/`: Master `wp-template.yaml` and `nginx.conf` used for new site setup.

## 📋 Prerequisites

- **Docker & Docker Compose**
- **mkcert** (Run `mkcert -install` once after installing)

## 🚀 Installation & Usage

### 1. Initialize the Network

Traefik and your site containers communicate over a shared external network:

```sh
docker network create web-proxy
```

### 2. Start the Traefik Gateway

Navigate to the `traefik/` directory and start the proxy:

```sh
cd traefik
cp dynamic_conf.yaml.example dynamic_conf.yaml
docker compose up -d
```

### 3. Create a New Site

Run the automation script from the root directory:

```sh
./create-site.sh
```

**The script will:**

1.  Ask for your **Project Name** and **Domain**.
2.  Create a project folder with a `src/` subfolder for WordPress files.
3.  Generate `mkcert` SSL certificates and save them to `traefik/certs/`.
4.  Inject the new certificates into `traefik/dynamic_conf.yaml`.
5.  Generate a local `docker-compose.yaml` and `nginx/nginx.conf` using templates.
6.  Start your new WordPress site.

### 4. Final Step: Hosts File

Add your custom domain to your system hosts file:

```
127.0.0.1 mysite.test
```

## 🛠️ Maintenance

- **Stopping a site:** `cd project-folder && docker compose down`
- **Wiping a site's data:** `docker compose down -v` (Deletes the persistent database volume).
- **Logs:** Monitor installation progress via `docker logs -f ${SITE_NAME}-setup`.

**License**: See LICENSE or project root for information.
