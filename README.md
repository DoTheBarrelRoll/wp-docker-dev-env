# Local Dev Environment Setup

This environment automates the creation of high-performance WordPress instances using **Docker**, **Nginx + PHP-FPM**, and **Traefik**. It uses `mkcert` to provide valid local SSL for any `.test` domain.

## ✨ Features

- **⚡ Nginx + PHP-FPM Stack:** High-performance architecture using `wordpress:fpm` and `nginx:alpine` for a smaller footprint and faster static file serving.
- **🔒 Automated Local SSL:** `create-site.sh` generates `mkcert` certificates, stores them in `traefik/certs/`, and registers them in Traefik's `dynamic_conf.yaml`.
- **🌐 Traefik Reverse Proxy:** Centralised routing for every project, each on its own domain, with plain HTTP redirected to HTTPS.
- **📧 Mail Never Leaves the Machine:** Every site gets a Mailpit inbox and an mu-plugin that routes all outgoing mail into it, so a production database imported locally cannot email real people.
- **🐛 Debug-Ready:** `WP_DEBUG` with logging to `src/wp-content/debug.log`, `SCRIPT_DEBUG`, generous PHP limits, and opcache set to notice file changes immediately.
- **💾 Isolated Data Persistence:** Each project uses its own named volume (`${SITE_NAME}_db_data`), so the database survives restarts and stays isolated from other projects.
- **🏘️ Multisite:** `create-site.sh --multisite` scaffolds a subdomain or subdirectory network instead of a single site, with the router rule, the nginx rewrites and the network install handled for you.
- **🤖 One-Command Scaffolding:** `create-site.sh` handles directories, SSL, config templating, plugin installation and startup. `delete-site.sh` removes all of it again.
- **🎨 Theme Bootstrapping:** `setup-theme.sh` clones a theme from `github.com/redandbluefi`, writes its `.env` and `auth.json` for the local domain, installs Composer and npm dependencies, builds the assets and activates it.
- **📁 Organised Directory Mapping:** WordPress lives in a `./src` subfolder, keeping the project root free for configuration.

## 📂 Contents

- **`create-site.sh`**: Creates a new site.
- **`setup-theme.sh`**: Clones a theme from `github.com/redandbluefi` into a site and gets it ready to run.
- **`delete-site.sh`**: Removes a site, its database volume, its certificate and its Traefik entry.
- **`traefik/`**: The shared reverse proxy:
  - `docker-compose.yaml`: The Traefik container.
  - `dynamic_conf.yaml`: Generated list of local certificates. Not in version control.
  - `certs/`: Generated certificates. Not in version control.
  - `templates/`: Everything a new site is built from:
    - `wp-template.yaml`: The per-site Docker Compose stack.
    - `nginx.conf`: The per-site nginx server block.
    - `uploads-proxy.conf`: Optional fallback that redirects missing uploads to production.
    - `multisite-subdirectory.conf`: Core path rewrites, included only by a subdirectory network.
    - `php-fpm-dev.ini`, `php-cli-dev.ini`: PHP overrides for the web and CLI containers.
    - `mu-dev-mail.php`: The mu-plugin that routes mail into Mailpit.
    - `mu-dev-multisite.php`: The mu-plugin that stores new subsites on https. Networks only.
    - `composer.json`, `auth.json.example`: WP Migrate DB Pro installation.
    - `licenses.env.example`: Where the ACF Pro license key goes.

## 📋 Prerequisites

- **Docker & Docker Compose v2**
- **mkcert**, installed and initialised. Platform specific instructions are [here](https://github.com/FiloSottile/mkcert#installation).

  ```sh
  mkcert -install
  ```

  This installs the local CA into the system and browser trust stores. Without it the generated certificates are not trusted and `create-site.sh` refuses to run.
- **Composer** on the host, needed for WP Migrate DB Pro (step 2) and for theme dependencies.
- **Node and pnpm** on the host, only needed for theme asset builds. The themes currently require Node 22.18 or newer and pnpm 10 or newer.
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

### 3. Add the ACF Pro license (optional)

`setup-theme.sh` needs the ACF Pro license key to install ACF Pro from `connect.advancedcustomfields.com`:

```sh
cp traefik/templates/licenses.env.example traefik/templates/licenses.env
```

Fill in `ACF_PRO_LICENSE`. The file is git-ignored and stays in `traefik/templates/`. The key is written into each theme's own `auth.json` together with the local site URL, which is what ACF's Composer endpoint authenticates against.

### 4. Create a new site

```sh
./create-site.sh
```

The script asks for four things:

1. **Project directory name**, for example `my-blog`. Lowercase letters, digits, `-` and `_`.
2. **Domain**, for example `my-blog.test`. Use `.test`, which is reserved for local use. Public TLDs such as `.dev` are in the browser HSTS preload list and behave differently.
3. **Production domain** for the uploads fallback, optional. A bare hostname such as `example.com`; any `https://` prefix is stripped for you.
4. **Theme repository slug** on `github.com/redandbluefi`, optional. Entering `eternia` clones `git@github.com:redandbluefi/eternia.git` and runs the theme setup below.

It then generates the project, issues the certificate, installs plugins, starts the stack, waits for the WordPress install to finish, sets up the theme, fixes ownership, and offers to add the `/etc/hosts` entry.

Add `--multisite` to get a network instead of a single site. See [Multisite](#-multisite) below.

### 5. What you get

| | |
|---|---|
| Site | `https://my-blog.test` |
| Admin | `https://my-blog.test/wp-admin`, user `admin`, password `password` |
| Mail | `https://mail.my-blog.test` |
| Debug log | `my-blog/src/wp-content/debug.log` |

## 🏘️ Multisite

```sh
./create-site.sh --multisite               # subdomain network
./create-site.sh --multisite=subdirectory  # subdirectory network
```

The prompts and everything else are the same. `wp core multisite-install` runs in place of `wp core install`, and it writes the multisite constants into `src/wp-config.php` itself, so they appear only once the network tables exist. The official image generates `wp-config.php` only when it is missing, so those constants survive restarts and a re-run of `create-site.sh`.

| | Subdomain | Subdirectory |
|---|---|---|
| Subsite address | `https://sub.my-blog.test` | `https://my-blog.test/sub/` |
| Traefik router | `Host()` plus a `HostRegexp()` that matches every subdomain | unchanged |
| nginx | `server_name` widened to `*.my-blog.test` | core path rewrites included |
| `/etc/hosts` | one line per subsite | nothing to add |

TLS needs no work either way. `create-site.sh` issues the certificate for `$DOMAIN` and `*.$DOMAIN`, so subsite hostnames are already covered.

### Adding a subsite

```sh
cd my-blog
docker compose run --rm wp-cli wp site create --slug=sub
```

On a subdomain network the hostname also needs its own line in `/etc/hosts`, because hosts files have no wildcards:

```
127.0.0.1 sub.my-blog.test
```

### Converting an existing site

Re-running `create-site.sh` for a project that already exists, with the flag added, turns it into a network. The database and `src/` are left alone: `wp core multisite-install` finds the single site tables already there and adds the network tables and constants around them.

```sh
./create-site.sh --multisite
```

The opposite is refused. Without the flag, `create-site.sh` stops rather than regenerate a network's compose file as a single site, because that would put `WP_HOME` and `WP_SITEURL` back and pin every subsite to the main domain.

### The site URL trade-off

A single site defines `WP_HOME` and `WP_SITEURL` in its compose file, which keeps it on the local domain even right after a production database import. A network reads every site URL from its own tables, so those two constants would pin every subsite to the main domain, and `create-site.sh` leaves them out. The local URLs have to come from a search and replace after each pull instead:

```sh
docker compose run --rm wp-cli wp search-replace 'example.com' 'my-blog.test' --network
```

Replace the bare domain rather than the full URL, so that subsite hostnames and paths are rewritten too. `DOMAIN_CURRENT_SITE` in `src/wp-config.php` keeps pointing at the local main domain, so the network still boots, but the rows in `wp_blogs` and `wp_site` come from the dump until they are replaced.

Also worth knowing:

- **New subsites are stored on https.** WordPress hardcodes `http` for a new subsite on a subdomain network, because in production a fresh subdomain has no certificate yet. Here it has one, so the `dev-multisite.php` mu-plugin corrects the stored `home` and `siteurl` as the subsite is created.
- **Themes and plugins are network-enabled.** When `setup-theme.sh` finds a network it uses `wp theme enable --network --activate` and `wp plugin activate --network`, so subsites can use them.
- **Check the WP Migrate plan before relying on it for a network pull.** Multisite is not included in every tier, so verify it against the license rather than assuming.
- **The subdirectory rewrites use `if (!-e $request_filename)`.** This is the rewrite set WordPress documents for nginx, and it has to run before nginx picks a location so the stripped URI reaches the PHP handler. `try_files` cannot do that: it would match an existing `.php` file and serve its source. The reasoning is in `multisite-subdirectory.conf`.

## 🎨 Project theme

`create-site.sh` runs this for you when you give it a slug, but it also works on its own, including on sites that already exist:

```sh
./setup-theme.sh my-blog eternia
```

It clones the repository at depth 1 into `src/wp-content/themes/eternia`, then:

1. Copies `.envexample` to `.env` and points `proxyUrl` at the local site URL.
2. Copies `auth.json.example` to `auth.json` with the ACF Pro license key as the username and the local site URL as the password.
3. Runs `composer install`, which installs ACF Pro and the other plugins into `wp-content/plugins/`. Skipped with a warning when no license key is configured, since ACF Pro cannot be downloaded without one.
4. Runs `pnpm install` and `pnpm run build`.
5. Activates ACF Pro, then the theme, then verifies that WordPress still loads and reverts to the previous theme if it does not. ACF Pro has to come first, because the themes call `get_field()` while WordPress loads.

Activation is skipped when the Composer step did not run, or when the theme is a child of a parent that is not installed. The themes call plugin functions such as `get_field()` at load time, so activating one without its plugins takes the whole site down with a fatal error. If that ever happens by hand, recover with:

```sh
docker compose run --rm wp-cli wp --skip-themes theme activate twentytwentyfive
```

Running it again on the same site is safe. An existing checkout is left alone, an existing `.env` keeps its other values and only has `proxyUrl` refreshed, and the dependency steps run again.

Two things are worth knowing:

- **The starter theme does not build on its own.** `eternia` git-ignores `blocks/` and `block-library/`, and the gulp build needs `block-library/` to exist. A project theme has them committed and builds fine. When starting a new project from the starter, create those directories and remove the two lines from the theme's `.gitignore`, as the comment there says.
- **pnpm needs the dependency build scripts approved.** pnpm 10 and newer refuse to run them until they are allowlisted, and fail the whole install when any are pending, which the themes hit through esbuild and the image optimisers. The script detects that, runs `pnpm approve-builds --all` and retries. On the first install pnpm may also migrate the theme's `pnpm-workspace.yaml` to its newer `allowBuilds` format, which shows up as a change in the theme repository.

For day to day work, the watch task lives in the theme:

```sh
cd my-blog/src/wp-content/themes/eternia && pnpm run dev
```

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

- **PHP version.** Pinned in `traefik/templates/wp-template.yaml` (`wordpress:php8.4-fpm`, `wordpress:cli-php8.4`). Change it there to match the target hosting. WordPress core itself lives in `src/` and is therefore pinned per project by the bind mount, not by the image tag.
- **Database.** WordPress connects as the `wordpress` user, the same as in production. The `root` account still exists for administrative work: `docker compose exec mysql mysql -uroot -prootpassword wordpress`.
- **Site URL.** `WP_HOME` and `WP_SITEURL` are defined in the compose file, so the site stays on its local domain even right after a production database import. `wp search-replace` is still needed for URLs inside post content. A network does not get them, see [Multisite](#-multisite).
- **PHP limits.** 128M uploads, 512M memory, 300s execution time for web requests, and no time limit for WP-CLI. Edit `php/php-fpm-dev.ini` and `php/php-cli-dev.ini` in the project, or the templates for all future sites.
- **Uploads fallback.** With a production domain configured, a request for an upload that does not exist locally is redirected to production, so a database import does not need the media library. Its rule lives in `nginx/configs/uploads-proxy.conf`.
- **Restart policy.** Containers use `restart: "no"`, so nothing comes back automatically after a reboot. Start the projects you are working on with `docker compose up -d`.

## 🧯 Troubleshooting

- **Browser warns about the certificate.** Run `mkcert -install`, then restart the browser. If the certificate was issued before the CA was installed, delete the site and create it again.
- **Traefik serves its own default certificate.** The site is missing from `traefik/dynamic_conf.yaml`. Traefik watches the file, so adding the entry is enough, no restart needed.
- **404 from Traefik.** The site containers are not running, or the domain is missing from `/etc/hosts`. On a subdomain network every subsite needs its own `/etc/hosts` line.
- **502 from nginx.** The `wordpress` container is not up yet. Check `docker compose logs wordpress`.
- **A WP Migrate pull fails with "Unable to overwrite destination file" during the Plugins or Themes stage.** The plugin directory it names is not writable by `www-data`. Composer extracts dist archives with the modes stored in the archive, so plugins installed straight from wpackagist land without group write. `setup-theme.sh` fixes this, but a `composer install` run by hand reintroduces it. Repair a site with:

  ```sh
  cd <project>/src/wp-content
  find . -user "$(id -u)" -type d -exec chmod g+rwxs {} +
  find . -user "$(id -u)" -type f -exec chmod g+rw {} +
  ```
- **The asset build failed.** If the theme is the `eternia` starter, this is expected until `blocks/` and `block-library/` exist. Otherwise run `pnpm run build` in the theme directory to see the real error. The site itself keeps working, the theme just has no compiled assets.
- **`composer install` fails with a 401 on connect.advancedcustomfields.com.** The ACF Pro license key in `traefik/templates/licenses.env` is missing or wrong, or the theme's `auth.json` password does not match the site URL the license is registered against.
- **Setup container failed.** `docker compose logs wp-setup`. It waits up to two minutes for core files and wp-config.php, then gives up.
