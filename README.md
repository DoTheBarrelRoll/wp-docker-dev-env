# Local WordPress Dev Environment

Scaffolds local WordPress sites with Docker: nginx, PHP-FPM and MariaDB behind a
shared Traefik proxy, with a trusted `mkcert` certificate for any `.test` domain.
Single sites and multisite networks.

## Features

- **Nginx + PHP-FPM.** `wordpress:fpm` and `nginx:alpine` instead of the Apache image.
- **Automated local SSL.** `create-site.sh` issues an `mkcert` certificate for the domain and its wildcard, stores it in `traefik/certs/` and registers it in `dynamic_conf.yaml`.
- **Traefik reverse proxy.** One gateway for every project, each on its own domain, with plain HTTP redirected to HTTPS.
- **Mail never leaves the machine.** Every site gets a Mailpit inbox and an mu-plugin that routes all outgoing mail into it, so a production database imported locally cannot email real people.
- **Debug ready.** `WP_DEBUG` logging to `src/wp-content/debug.log`, `SCRIPT_DEBUG`, raised PHP limits, and opcache picking up file changes immediately.
- **Per-site environment variables.** A `.env` in the project directory reaches PHP-FPM and WP-CLI, for themes and plugins that read keys with `getenv()`. It lives outside the webroot and outside version control.
- **Isolated databases.** One named volume per project, `${SITE_NAME}_db_data`, surviving restarts.
- **Multisite.** `--multisite` scaffolds a subdomain or subdirectory network, including the router rule, the nginx rewrites and the network install.
- **Theme bootstrapping.** `setup-theme.sh` clones a theme from `github.com/redandbluefi`, writes its `.env` and `auth.json`, installs dependencies, builds the assets and activates it.

## Contents

- `create-site.sh` — creates a site. `--multisite[=subdomain|subdirectory]` makes it a network.
- `setup-theme.sh` — clones a theme from `github.com/redandbluefi` into a site and gets it ready to run.
- `delete-site.sh` — removes a site, its database volume, its certificate and its Traefik entry.
- `traefik/` — the shared reverse proxy. `dynamic_conf.yaml` and `certs/` are generated and not in version control.
- `traefik/templates/` — everything a new site is built from:
  - `wp-template.yaml` — the per-site Docker Compose stack.
  - `nginx.conf` — the per-site server block.
  - `uploads-proxy.conf` — optional fallback that redirects missing uploads to production.
  - `multisite-subdirectory.conf` — core path rewrites, included only by a subdirectory network.
  - `php-fpm-dev.ini`, `php-cli-dev.ini` — PHP overrides for the web and CLI containers.
  - `mu-dev-mail.php` — routes mail into Mailpit.
  - `mu-dev-multisite.php` — stores new subsites on https. Networks only.
  - `composer.json`, `auth.json.example` — WP Migrate DB Pro installation.
  - `licenses.env.example` — where the ACF Pro license key goes.

## Prerequisites

- **Docker and Docker Compose v2.**
- **mkcert**, [installed](https://github.com/FiloSottile/mkcert#installation) and initialised with `mkcert -install`. This puts the local CA into the system and browser trust stores; without it the generated certificates are not trusted and `create-site.sh` refuses to run.
- **Composer**, for WP Migrate DB Pro and theme dependencies.
- **Node and pnpm**, for theme asset builds only. The themes currently need Node 22.18 and pnpm 10 or newer.
- **sudo**, to set ownership to `www-data` and to update `/etc/hosts`.

## Setup

### 1. Start the Traefik gateway

```sh
cd traefik && docker compose up -d
```

The `web-proxy` network and `dynamic_conf.yaml` are created by `create-site.sh`
when missing, so this step is only about getting the proxy itself running. The
dashboard is on <http://127.0.0.1:8080>, bound to loopback because the API runs
without authentication.

### 2. Add auth.json for WP Migrate DB Pro (optional)

```sh
cp traefik/templates/auth.json.example traefik/templates/auth.json
```

`create-site.sh` installs WP Migrate DB Pro with Composer when these credentials
are present. API keys come from
[your Delicious Brains account](https://deliciousbrains.com/my-account/settings/).
The file is git-ignored and is passed to Composer through the environment, so it
is never copied into the webroot.

### 3. Add the ACF Pro license (optional)

```sh
cp traefik/templates/licenses.env.example traefik/templates/licenses.env
```

Fill in `ACF_PRO_LICENSE`. `setup-theme.sh` writes it into each theme's own
`auth.json` together with the local site URL, which is what ACF's Composer
endpoint authenticates against. The file is git-ignored.

## Creating a site

```sh
./create-site.sh
```

The script asks for four things:

1. **Project directory name**, for example `my-blog`. Lowercase letters, digits, `-` and `_`.
2. **Domain**, for example `my-blog.test`. Use `.test`: RFC 6761 reserves it, so it can never be registered by anyone. A public TLD such as `.dev` may already belong to a stranger, and then the `/etc/hosts` entry is the only thing keeping your traffic off their server. Miss that entry and the request fails open, over HTTPS, against their valid certificate.
3. **Production domain** for the uploads fallback, optional. A bare hostname such as `example.com`.
4. **Theme repository slug** on `github.com/redandbluefi`, optional. Entering `eternia` clones `git@github.com:redandbluefi/eternia.git` and runs the theme setup.

It then generates the project, issues the certificate, installs plugins, starts
the stack, waits for the WordPress install, sets up the theme, fixes ownership,
and offers to add the `/etc/hosts` entry.

| | |
|---|---|
| Site | `https://my-blog.test` |
| Admin | `https://my-blog.test/wp-admin`, user `admin`, password `password` |
| Mail | `https://mail.my-blog.test` |
| Debug log | `my-blog/src/wp-content/debug.log` |

Re-running the script on an existing project rewrites its configuration files
and leaves the database and `src/` alone.

## Multisite

```sh
./create-site.sh --multisite               # subdomain network
./create-site.sh --multisite=subdirectory  # subdirectory network
```

The prompts are the same. `wp core multisite-install` runs in place of
`wp core install` and writes the multisite constants into `src/wp-config.php`
itself, so they appear only once the network tables exist. The official image
generates `wp-config.php` only when it is missing, so those constants survive
restarts and a re-run of `create-site.sh`.

| | Subdomain | Subdirectory |
|---|---|---|
| Subsite address | `https://sub.my-blog.test` | `https://my-blog.test/sub/` |
| Traefik router | `Host()` plus a `HostRegexp()` matching every subdomain | unchanged |
| nginx | `server_name` widened to `*.my-blog.test` | core path rewrites included |
| `/etc/hosts` | one line per subsite | nothing to add |

TLS needs no work either way: the certificate covers `$DOMAIN` and `*.$DOMAIN`.

### Adding a subsite

```sh
cd my-blog
docker compose run --rm wp-cli wp site create --slug=sub
```

On a subdomain network the hostname also needs `127.0.0.1 sub.my-blog.test` in
`/etc/hosts`, because hosts files have no wildcards.

### Converting an existing site

Re-running `create-site.sh` with the flag added turns a single site into a
network. The database and `src/` are left alone: `wp core multisite-install`
finds the single site tables already there and adds the network tables and
constants around them. The opposite is refused, because regenerating a network's
compose file as a single site would put `WP_HOME` and `WP_SITEURL` back and pin
every subsite to the main domain.

### The site URL trade-off

A single site pins `WP_HOME` and `WP_SITEURL` in its compose file, which keeps it
on the local domain even right after a production database import. A network
reads every site URL from its own tables, so `create-site.sh` leaves those
constants out and the local URLs have to come from a search and replace instead:

```sh
docker compose run --rm wp-cli wp search-replace 'example.com' 'my-blog.test' --network
```

Replace the bare domain rather than the full URL, so that subsite hostnames and
paths are rewritten too. `DOMAIN_CURRENT_SITE` in `src/wp-config.php` keeps
pointing at the local main domain, so the network still boots, but the rows in
`wp_blogs` and `wp_site` come from the dump until they are replaced.

Also worth knowing:

- **New subsites are stored on https.** WordPress hardcodes `http` for a new subsite on a subdomain network, because in production a fresh subdomain has no certificate yet. Here it has one, so the `dev-multisite.php` mu-plugin corrects the stored `home` and `siteurl` as the subsite is created.
- **Themes and plugins are network-enabled.** On a network `setup-theme.sh` uses `wp theme enable --network --activate` and `wp plugin activate --network`.
- **Check the WP Migrate plan before relying on it for a network pull.** Multisite is not in every tier.
- **The subdirectory rewrites use `if (!-e $request_filename)`.** This is the rewrite set WordPress documents for nginx, and it has to run before nginx picks a location so the stripped URI reaches the PHP handler. `try_files` cannot do that: it would match an existing `.php` file and serve its source. The reasoning is in `multisite-subdirectory.conf`.

## Project theme

`create-site.sh` runs this when given a slug, but it also works on its own,
including on sites that already exist:

```sh
./setup-theme.sh my-blog eternia
```

It clones the repository at depth 1 into `src/wp-content/themes/eternia`, then:

1. Copies `.envexample` to `.env` and points `proxyUrl` at the local site URL.
2. Copies `auth.json.example` to `auth.json` with the ACF Pro license key as the username and the local site URL as the password.
3. Runs `composer install`, which installs ACF Pro and the other plugins into `wp-content/plugins/`. Skipped with a warning when no license key is configured.
4. Runs `pnpm install` and `pnpm run build`.
5. Activates ACF Pro, then the theme, then verifies that WordPress still loads and reverts to the previous theme if it does not.

ACF Pro has to come first, because the themes call `get_field()` while WordPress
loads. For the same reason activation is skipped when the Composer step did not
run, or when the theme is a child of a parent that is not installed. If a fatal
does happen, recover with:

```sh
docker compose run --rm wp-cli wp --skip-themes theme activate twentytwentyfive
```

Running the script again on the same site is safe. An existing checkout is left
alone, an existing `.env` keeps its other values and only has `proxyUrl`
refreshed, and the dependency steps run again.

Two things are worth knowing:

- **The starter theme does not build on its own.** `eternia` git-ignores `blocks/` and `block-library/`, and the gulp build needs `block-library/` to exist. A project theme has them committed and builds fine. When starting a new project from the starter, create those directories and remove the two lines from the theme's `.gitignore`, as the comment there says.
- **pnpm needs the dependency build scripts approved.** pnpm 10 and newer refuse to run them until they are allowlisted, and fail the whole install when any are pending, which the themes hit through esbuild and the image optimisers. The script detects that, runs `pnpm approve-builds --all` and retries. On the first install pnpm may also migrate the theme's `pnpm-workspace.yaml` to its newer `allowBuilds` format, which shows up as a change in the theme repository.

For day to day work, the watch task lives in the theme:

```sh
cd my-blog/src/wp-content/themes/eternia && pnpm run dev
```

## Site environment variables

`create-site.sh` writes a `.env` into the project directory, next to
`docker-compose.yaml`. Everything in it is passed to the `wordpress`, `wp-setup`
and `wp-cli` containers, so a theme or plugin can read it with `getenv()`:

```sh
# my-blog/.env
SOME_API_KEY=xxxx
```

A container keeps the environment it was created with, so after editing the file:

```sh
docker compose up -d --force-recreate wordpress
```

The file sits outside `src/`, so nginx never serves it, and every project
directory is git-ignored. `create-site.sh` creates it once and never rewrites it,
and the compose file wins over it, so a stray `WORDPRESS_DB_HOST` in it cannot
take the database out from under the stack.

This is not the theme's own `.env`, which configures the asset build, see
[Project theme](#project-theme). Some themes also ship a `.env` for PHP and load
it themselves with `vlucas/phpdotenv`; those keep working as they are. A theme
that calls `getenv()` without loading anything needs its values here instead.

## Daily use

All commands are run from the project directory.

```sh
docker compose up -d                          # start
docker compose down                           # stop
docker compose logs -f                        # all logs
docker compose logs -f wp-setup               # installation progress
docker compose run --rm wp-cli wp plugin list # any WP-CLI command
```

WP-CLI is not a resident container. `docker compose run --rm wp-cli wp <command>`
starts it on demand, waits for the database, and removes the container afterwards.

### Removing a site

```sh
./delete-site.sh my-blog
```

This stops the containers, deletes the database volume, removes the certificate
and its Traefik entry, then asks separately before deleting the project directory
and the `/etc/hosts` line. It lists any git repositories under `src/` with their
uncommitted and unpushed counts first, so nothing unsaved disappears by accident.

## Configuration notes

- **PHP version.** Pinned in `traefik/templates/wp-template.yaml` (`wordpress:php8.4-fpm`, `wordpress:cli-php8.4`). Change it there to match the target hosting. WordPress core itself lives in `src/` and is pinned per project by the bind mount, not by the image tag.
- **Database.** MariaDB 11.8, pinned in the same template. It is the engine the WP-CLI image can talk to: against MySQL 8.0 its MariaDB client rejects the server's self-signed certificate and cannot load `caching_sha2_password`, which breaks every `wp db` command. WordPress connects as the `wordpress` user, the same as in production. The `root` account still exists: `docker compose exec mysql mariadb -uroot -prootpassword wordpress`.
- **Site URL.** `WP_HOME` and `WP_SITEURL` are defined in the compose file, so a single site stays on its local domain even right after a production database import. `wp search-replace` is still needed for URLs inside post content. A network does not get them, see [Multisite](#multisite).
- **PHP limits.** 128M uploads, 512M memory and 300s execution time for web requests; 1024M and no time limit for WP-CLI. Edit `php/php-fpm-dev.ini` and `php/php-cli-dev.ini` in the project, or the templates for all future sites.
- **Uploads fallback.** With a production domain configured, a request for an upload that does not exist locally is redirected to production, so a database import does not need the media library. The rule lives in `nginx/configs/uploads-proxy.conf`.
- **Restart policy.** Containers use `restart: "no"`, so nothing comes back after a reboot. Start the projects you are working on with `docker compose up -d`.

## Troubleshooting

- **Browser warns about the certificate.** Run `mkcert -install`, then restart the browser. If the certificate was issued before the CA was installed, delete the site and create it again.
- **Traefik serves its own default certificate.** The site is missing from `traefik/dynamic_conf.yaml`. Traefik watches the file, so adding the entry is enough, no restart needed.
- **404 from Traefik.** The site containers are not running, or the domain is missing from `/etc/hosts`. On a subdomain network every subsite needs its own line.
- **502 from nginx.** The `wordpress` container is not up yet. Check `docker compose logs wordpress`.
- **Setup container failed.** `docker compose logs wp-setup`. It waits up to two minutes for core files and `wp-config.php`, then gives up.
- **`docker compose` complains that the env file is missing.** An older Compose does not understand `required: false` on an `env_file` entry. Create an empty `.env` in the project directory, or upgrade Compose.
- **A WP Migrate pull fails with "Unable to overwrite destination file".** The plugin directory it names is not writable by `www-data`. Composer extracts dist archives with the modes stored in the archive, so plugins installed straight from wpackagist land without group write. `setup-theme.sh` fixes this, but a `composer install` run by hand reintroduces it. Repair with:

  ```sh
  cd <project>/src/wp-content
  find . -user "$(id -u)" -type d -exec chmod g+rwxs {} +
  find . -user "$(id -u)" -type f -exec chmod g+rw {} +
  ```
- **The asset build failed.** Expected for the `eternia` starter until `blocks/` and `block-library/` exist. Otherwise run `pnpm run build` in the theme directory to see the real error. The site keeps working, the theme just has no compiled assets.
- **`composer install` fails with a 401 on connect.advancedcustomfields.com.** The ACF Pro license key in `traefik/templates/licenses.env` is missing or wrong, or the theme's `auth.json` password does not match the site URL the license is registered against.
