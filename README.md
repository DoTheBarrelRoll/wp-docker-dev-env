# Local Dev Environment Setup

This environment automates the creation of high-performance WordPress instances using **Docker**, **Nginx + PHP-FPM**, and **Traefik**. It uses `mkcert` to provide valid local SSL for any `.test` domain.

## ✨ Features

- **⚡ Nginx + PHP-FPM Stack:** High-performance architecture using `wordpress:fpm` and `nginx:alpine` for a smaller footprint and faster static file serving.
- **🔒 Automated Local SSL:** `create-site.sh` generates `mkcert` certificates, stores them in `traefik/certs/`, and registers them in Traefik's `dynamic_conf.yaml`.
- **🌐 Traefik Reverse Proxy:** Centralised routing for every project, each on its own domain, with plain HTTP redirected to HTTPS.
- **📧 Mail Never Leaves the Machine:** Every site gets a Mailpit inbox and an mu-plugin that routes all outgoing mail into it, so a production database imported locally cannot email real people.
- **🐛 Debug-Ready:** `WP_DEBUG` with logging to `src/wp-content/debug.log`, `SCRIPT_DEBUG`, generous PHP limits, and opcache set to notice file changes immediately.
- **💾 Isolated Data Persistence:** Each project uses its own named volume (`${SITE_NAME}_db_data`), so the database survives restarts and stays isolated from other projects.
- **🤖 One-Command Scaffolding:** `create-site.sh` handles directories, SSL, config templating, plugin installation and startup. `delete-site.sh` removes all of it again.
- **📁 Organised Directory Mapping:** WordPress lives in a `./src` subfolder, keeping the project root free for configuration.

## 📂 Contents

- **`create-site.sh`**: Creates a new site.
- **`delete-site.sh`**: Removes a site, its database volume, its certificate and its Traefik entry.
- **`traefik/`**: The shared reverse proxy:
  - `docker-compose.yaml`: The Traefik container.
  - `dynamic_conf.yaml`: Generated list of local certificates. Not in version control.
  - `certs/`: Generated certificates. Not in version control.
  - `templates/`: Everything a new site is built from:
    - `wp-template.yaml`: The per-site Docker Compose stack.
    - `nginx.conf`: The per-site nginx server block.
    - `uploads-proxy.conf`: Optional fallback that redirects missing uploads to production.
    - `php-fpm-dev.ini`, `php-cli-dev.ini`: PHP overrides for the web and CLI containers.
    - `mu-dev-mail.php`: The mu-plugin that routes mail into Mailpit.
    - `composer.json`, `auth.json.example`: WP Migrate DB Pro installation.

## 📋 Prerequisites

- **Docker & Docker Compose v2**
- **mkcert**, installed and initialised. Platform specific instructions are [here](https://github.com/FiloSottile/mkcert#installation).

  ```sh
  mkcert -install
  ```

  This installs the local CA into the system and browser trust stores. Without it the generated certificates are not trusted and `create-site.sh` refuses to run.
- **Composer** on the host, only needed if you install WP Migrate DB Pro (see step 2).
- **sudo**, used to set file ownership to `www-data` and to update `/etc/hosts`.

## 🚀 Installation & Usage

### 1. Start the Traefik gateway

```sh
cd traefik
cp dynamic_conf.yaml.example dynamic_conf.yaml
docker compose up -d
```

The shared `web-proxy` network and `dynamic_conf.yaml` are created automatically by `create-site.sh` if they are missing, so this step is only about getting the proxy itself running.

The Traefik dashboard is on <http://127.0.0.1:8080>. It is bound to loopback because the API runs without authentication.

### 2. Add auth.json for WP Migrate DB Pro (optional)

`create-site.sh` installs WP Migrate DB Pro with Composer when credentials are present:

```sh
cp traefik/templates/auth.json.example traefik/templates/auth.json
```

Fill in the details. Composer API keys can be created [here](https://deliciousbrains.com/my-account/settings/). The file stays in `traefik/templates/`, is git-ignored, and is passed to Composer through the environment, so it is never copied into the webroot.

### 3. Create a new site

```sh
./create-site.sh
```

The script asks for three things:

1. **Project directory name**, for example `my-blog`. Lowercase letters, digits, `-` and `_`.
2. **Domain**, for example `my-blog.test`. Use `.test`, which is reserved for local use. Public TLDs such as `.dev` are in the browser HSTS preload list and behave differently.
3. **Production domain** for the uploads fallback, optional. A bare hostname such as `example.com`; any `https://` prefix is stripped for you.

It then generates the project, issues the certificate, installs plugins, starts the stack, waits for the WordPress install to finish, fixes ownership, and offers to add the `/etc/hosts` entry.

### 4. What you get

| | |
|---|---|
| Site | `https://my-blog.test` |
| Admin | `https://my-blog.test/wp-admin`, user `admin`, password `password` |
| Mail | `https://mail.my-blog.test` |
| Debug log | `my-blog/src/wp-content/debug.log` |

## 🛠️ Daily use

All commands are run from the project directory.

```sh
docker compose up -d                          # start
docker compose down                           # stop
docker compose logs -f                        # all logs
docker compose logs -f wp-setup               # installation progress
docker compose run --rm wp-cli wp plugin list # any WP-CLI command
```

WP-CLI is not a resident container. `docker compose run --rm wp-cli wp <command>` starts it on demand, waits for the database, and removes the container afterwards.

### Removing a site

```sh
./delete-site.sh my-blog
```

This stops the containers, deletes the database volume, removes the certificate and its Traefik entry, then asks separately before deleting the project directory and the `/etc/hosts` line. It lists any git repositories under `src/` with their uncommitted and unpushed counts first, so nothing unsaved disappears by accident.

## ⚙️ Configuration notes

- **PHP version.** Pinned in `traefik/templates/wp-template.yaml` (`wordpress:php8.3-fpm`, `wordpress:cli-php8.3`). Change it there to match the target hosting. WordPress core itself lives in `src/` and is therefore pinned per project by the bind mount, not by the image tag.
- **Database.** WordPress connects as the `wordpress` user, the same as in production. The `root` account still exists for administrative work: `docker compose exec mysql mysql -uroot -prootpassword wordpress`.
- **Site URL.** `WP_HOME` and `WP_SITEURL` are defined in the compose file, so the site stays on its local domain even right after a production database import. `wp search-replace` is still needed for URLs inside post content.
- **PHP limits.** 128M uploads, 512M memory, 300s execution time for web requests, and no time limit for WP-CLI. Edit `php/php-fpm-dev.ini` and `php/php-cli-dev.ini` in the project, or the templates for all future sites.
- **Uploads fallback.** With a production domain configured, a request for an upload that does not exist locally is redirected to production, so a database import does not need the media library. Its rule lives in `nginx/configs/uploads-proxy.conf`.
- **Restart policy.** Containers use `restart: "no"`, so nothing comes back automatically after a reboot. Start the projects you are working on with `docker compose up -d`.

## 🧯 Troubleshooting

- **Browser warns about the certificate.** Run `mkcert -install`, then restart the browser. If the certificate was issued before the CA was installed, delete the site and create it again.
- **Traefik serves its own default certificate.** The site is missing from `traefik/dynamic_conf.yaml`. Traefik watches the file, so adding the entry is enough, no restart needed.
- **404 from Traefik.** The site containers are not running, or the domain is missing from `/etc/hosts`.
- **502 from nginx.** The `wordpress` container is not up yet. Check `docker compose logs wordpress`.
- **Setup container failed.** `docker compose logs wp-setup`. It waits up to two minutes for core files and wp-config.php, then gives up.
